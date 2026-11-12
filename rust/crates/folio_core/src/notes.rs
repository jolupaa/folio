//! Notas de texto y pizarras (tabla `notes`): crear, leer, guardar, listar, fijar, mover y
//! mover a la papelera. Mantiene el índice de búsqueda y marca las notas para la IA.

use crate::attachments::attachments_of;
use crate::blocks;
use crate::folders::ensure_folder_usable;
use crate::fsutil::path_string;
use crate::model::{Note, NoteKind, NoteListScope, NoteSummary, SaveResult, EMPTY_SCENE};
use crate::search_index;
use crate::util::{new_id, now_ms, single_line, truncate_chars};
use crate::Core;
use anyhow::{anyhow, bail};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashSet;

/// Longitud máxima de un título explícito.
pub const MAX_TITLE_CHARS: usize = 300;
/// Longitud aproximada de la vista previa en listados.
pub const PREVIEW_CHARS: usize = 140;

/// Datos mínimos de una nota para validar operaciones.
#[derive(Debug, Clone)]
pub(crate) struct NoteMeta {
    pub kind: NoteKind,
    pub folder_id: Option<String>,
    pub deleted_at: Option<i64>,
    pub revision: i64,
    pub updated_at: i64,
}

pub(crate) fn note_meta(conn: &Connection, id: &str) -> anyhow::Result<NoteMeta> {
    conn.prepare_cached("SELECT kind, folder_id, deleted_at, revision, updated_at FROM notes WHERE id = ?1")?
        .query_row(params![id], |r| {
            Ok(NoteMeta {
                kind: NoteKind::from_db(&r.get::<_, String>(0)?),
                folder_id: r.get(1)?,
                deleted_at: r.get(2)?,
                revision: r.get(3)?,
                updated_at: r.get(4)?,
            })
        })
        .optional()?
        .ok_or_else(|| anyhow!("La nota no existe"))
}

/// Nota existente y fuera de la papelera.
pub(crate) fn active_note_meta(conn: &Connection, id: &str) -> anyhow::Result<NoteMeta> {
    let m = note_meta(conn, id)?;
    if m.deleted_at.is_some() {
        bail!("La nota está en la papelera");
    }
    Ok(m)
}

pub(crate) fn load_note(core: &Core, conn: &Connection, id: &str) -> anyhow::Result<Note> {
    let mut note = conn
        .prepare_cached(
            "SELECT id, folder_id, kind, title, body, pinned, created_at, updated_at, revision, deleted_at
             FROM notes WHERE id = ?1",
        )?
        .query_row(params![id], |r| {
            let kind = NoteKind::from_db(&r.get::<_, String>(2)?);
            Ok(Note {
                id: r.get(0)?,
                folder_id: r.get(1)?,
                kind,
                title: r.get(3)?,
                body_json: if kind == NoteKind::Board { "[]".to_string() } else { r.get(4)? },
                pinned: r.get::<_, i64>(5)? != 0,
                created_at: r.get(6)?,
                updated_at: r.get(7)?,
                revision: r.get(8)?,
                attachments: Vec::new(),
                deleted_at: r.get(9)?,
            })
        })
        .optional()?
        .ok_or_else(|| anyhow!("La nota no existe"))?;
    note.attachments = attachments_of(conn, &core.paths.files_dir(), id)?;
    Ok(note)
}

/// Vista previa: texto plano sin la línea que ya se muestra como título, en una línea,
/// recortado a ~140 caracteres (por palabra, con «…»).
pub fn preview_text(explicit_title: &str, shown_title: &str, plain: &str) -> String {
    let mut lines = plain.lines().map(str::trim).filter(|l| !l.is_empty()).peekable();
    if let Some(first) = lines.peek() {
        let first_clean = first.trim_start_matches(['•', '☐', '☑']).trim();
        let derived = explicit_title.trim().is_empty();
        if derived || first_clean == shown_title {
            lines.next();
        }
    }
    let mut out = String::new();
    for l in lines {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(l);
        if out.chars().count() > PREVIEW_CHARS + 40 {
            break;
        }
    }
    let collapsed: String = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= PREVIEW_CHARS {
        return collapsed;
    }
    let cut = truncate_chars(&collapsed, PREVIEW_CHARS);
    let cut = match cut.rfind(' ') {
        Some(i) if cut[..i].chars().count() >= PREVIEW_CHARS * 2 / 3 => &cut[..i],
        _ => cut,
    };
    format!("{}…", cut.trim_end_matches([' ', ',', ';', ':', '.']))
}

/// Comprueba que los adjuntos referenciados no pertenecen a OTRA nota. Los que no existen se
/// permiten (la UI muestra el bloque como «adjunto no disponible»).
pub(crate) fn ensure_attachments_owned<S: AsRef<str>>(
    conn: &Connection,
    note_id: &str,
    attachment_ids: &[S],
) -> anyhow::Result<()> {
    let mut s = conn.prepare_cached("SELECT note_id FROM attachments WHERE id = ?1")?;
    for a in attachment_ids {
        let owner: Option<String> = s.query_row(params![a.as_ref()], |r| r.get(0)).optional()?;
        if let Some(owner) = owner {
            if owner != note_id {
                bail!("El contenido referencia un adjunto de otra nota");
            }
        }
    }
    Ok(())
}

/// Recalcula `attachment_pages.materialized` de las páginas de la nota según los
/// `source_page_id` presentes en el cuerpo. Devuelve las páginas que cambiaron.
pub(crate) fn sync_materialized(
    conn: &Connection,
    note_id: &str,
    referenced_pages: &HashSet<String>,
) -> rusqlite::Result<Vec<String>> {
    let pages: Vec<(String, bool)> = {
        let mut s = conn.prepare_cached(
            "SELECT p.id, p.materialized FROM attachment_pages p
             JOIN attachments a ON a.id = p.attachment_id WHERE a.note_id = ?1",
        )?;
        let v = s
            .query_map(params![note_id], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)))?
            .collect::<rusqlite::Result<_>>()?;
        v
    };
    let mut changed = Vec::new();
    let mut upd = conn.prepare_cached("UPDATE attachment_pages SET materialized = ?2 WHERE id = ?1")?;
    for (id, mat) in pages {
        let should = referenced_pages.contains(&id);
        if should != mat {
            upd.execute(params![id, should as i64])?;
            changed.push(id);
        }
    }
    Ok(changed)
}

impl Core {
    /// Crea una nota de texto (cuerpo "[]") o una pizarra (fila en `boards` con escena vacía).
    pub fn create_note(&self, folder_id: Option<&str>, kind: NoteKind, title: &str) -> anyhow::Result<Note> {
        let title = single_line(title, MAX_TITLE_CHARS);
        let id = new_id();
        let now = now_ms();
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_folder_usable(&tx, folder_id)?;
        tx.execute(
            "INSERT INTO notes(id, folder_id, kind, title, body, plain_text, pinned, created_at, updated_at, revision)
             VALUES (?1, ?2, ?3, ?4, '[]', '', 0, ?5, ?5, 0)",
            params![id, folder_id, kind.as_str(), title, now],
        )?;
        if kind == NoteKind::Board {
            tx.execute(
                "INSERT INTO boards(note_id, scene, updated_at) VALUES (?1, ?2, ?3)",
                params![id, EMPTY_SCENE, now],
            )?;
        }
        search_index::sync_note_doc(&tx, &id)?;
        search_index::mark_dirty(&tx, &[&id])?;
        tx.commit()?;
        let note = load_note(self, &conn, &id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(note)
    }

    /// Nota con sus adjuntos (también si está en la papelera).
    pub fn get_note(&self, id: &str) -> anyhow::Result<Note> {
        load_note(self, &self.db.read(), id)
    }

    /// Guardado de una nota de texto: valida bloques, deriva texto plano, revisión +1,
    /// `conflict` si `base_revision` no coincide (se guarda igualmente), actualiza búsqueda,
    /// recalcula páginas materializadas y marca la nota para la IA. Sin cambios → no escribe.
    pub fn save_note(&self, id: &str, title: &str, body_json: &str, base_revision: i64) -> anyhow::Result<SaveResult> {
        let blocks = blocks::parse(body_json)?;
        let body = if body_json.trim().is_empty() { "[]" } else { body_json };
        let title = single_line(title, MAX_TITLE_CHARS);
        let plain = blocks::to_plain_text(&blocks);
        let referenced_pages: HashSet<String> =
            blocks.iter().filter_map(|b| b.source_page_id.clone()).collect();

        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let meta = note_meta(&tx, id)?;
        if meta.kind != NoteKind::Text {
            bail!("Esta nota es una pizarra: se guarda con save_board");
        }
        let conflict = base_revision != meta.revision;
        let (cur_title, cur_body): (String, String) =
            tx.query_row("SELECT title, body FROM notes WHERE id = ?1", params![id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?;
        if cur_title == title && cur_body == body {
            return Ok(SaveResult { revision: meta.revision, updated_at: meta.updated_at, conflict });
        }
        ensure_attachments_owned(&tx, id, &blocks::referenced_attachments(&blocks))?;
        let now = now_ms().max(meta.updated_at);
        let revision = meta.revision + 1;
        tx.execute(
            "UPDATE notes SET title = ?2, body = ?3, plain_text = ?4, updated_at = ?5, revision = ?6
             WHERE id = ?1",
            params![id, title, body, plain, now, revision],
        )?;
        let changed_pages = sync_materialized(&tx, id, &referenced_pages)?;
        search_index::sync_note_doc(&tx, id)?;
        for p in &changed_pages {
            search_index::sync_page_doc(&tx, p)?;
        }
        search_index::mark_dirty(&tx, &[id])?;
        tx.commit()?;
        drop(conn);
        self.db.signal().bump();
        Ok(SaveResult { revision, updated_at: now, conflict })
    }

    /// Fijadas primero; después por `updated_at` descendente.
    pub fn list_notes(&self, scope: NoteListScope, folder_id: Option<&str>) -> anyhow::Result<Vec<NoteSummary>> {
        let filter = match scope {
            NoteListScope::Inbox => "n.folder_id IS NULL",
            NoteListScope::Folder => {
                if folder_id.is_none() {
                    bail!("Falta la carpeta que listar");
                }
                "n.folder_id = ?1"
            }
            NoteListScope::All => "1",
            NoteListScope::Pinned => "n.pinned = 1",
        };
        let sql = format!(
            "SELECT n.id, n.folder_id, n.kind, n.title, substr(n.plain_text, 1, 2000), n.pinned,
                    n.created_at, n.updated_at,
                    (SELECT count(*) FROM attachments a WHERE a.note_id = n.id),
                    (SELECT a.rel_path FROM attachments a
                      WHERE a.note_id = n.id AND a.kind = 'image'
                      ORDER BY a.created_at, a.rowid LIMIT 1)
             FROM notes n
             WHERE n.deleted_at IS NULL AND {filter}
             ORDER BY n.pinned DESC, n.updated_at DESC, n.id"
        );
        let files = self.paths.files_dir();
        let conn = self.db.read();
        let mut stmt = conn.prepare_cached(&sql)?;
        let map = |r: &rusqlite::Row<'_>| -> rusqlite::Result<NoteSummary> {
            let title: String = r.get(3)?;
            let plain: String = r.get(4)?;
            let shown = blocks::display_title(&title, &plain);
            let preview = preview_text(&title, &shown, &plain);
            let thumb: Option<String> = r.get(9)?;
            Ok(NoteSummary {
                id: r.get(0)?,
                folder_id: r.get(1)?,
                kind: NoteKind::from_db(&r.get::<_, String>(2)?),
                title: shown,
                preview,
                pinned: r.get::<_, i64>(5)? != 0,
                attachment_count: r.get(8)?,
                thumbnail_path: thumb.map(|rel| path_string(&files.join(rel))),
                created_at: r.get(6)?,
                updated_at: r.get(7)?,
            })
        };
        let rows = if scope == NoteListScope::Folder {
            stmt.query_map(params![folder_id], map)?.collect::<rusqlite::Result<Vec<_>>>()?
        } else {
            stmt.query_map([], map)?.collect::<rusqlite::Result<Vec<_>>>()?
        };
        Ok(rows)
    }

    pub fn set_note_pinned(&self, id: &str, pinned: bool) -> anyhow::Result<()> {
        let conn = self.db.write();
        active_note_meta(&conn, id)?;
        conn.execute("UPDATE notes SET pinned = ?2 WHERE id = ?1", params![id, pinned as i64])?;
        Ok(())
    }

    /// Mueve la nota a otra carpeta (None = bandeja «Notas»). Cambia el ámbito: marca para IA.
    pub fn move_note(&self, id: &str, folder_id: Option<&str>) -> anyhow::Result<()> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let meta = active_note_meta(&tx, id)?;
        if meta.folder_id.as_deref() == folder_id {
            return Ok(());
        }
        ensure_folder_usable(&tx, folder_id)?;
        tx.execute("UPDATE notes SET folder_id = ?2 WHERE id = ?1", params![id, folder_id])?;
        search_index::mark_dirty(&tx, &[id])?;
        tx.commit()?;
        drop(conn);
        self.db.signal().bump();
        Ok(())
    }

    /// Mueve la nota a la papelera (idempotente). Sale del índice de búsqueda.
    pub fn trash_note(&self, id: &str) -> anyhow::Result<()> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let meta = note_meta(&tx, id)?;
        if meta.deleted_at.is_some() {
            return Ok(());
        }
        tx.execute("UPDATE notes SET deleted_at = ?2 WHERE id = ?1", params![id, now_ms()])?;
        search_index::remove_note_docs(&tx, id)?;
        search_index::mark_dirty(&tx, &[id])?;
        tx.commit()?;
        drop(conn);
        self.db.signal().bump();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_skips_title_line() {
        assert_eq!(preview_text("", "Tema 1", "Tema 1\nLa velocidad\nes"), "La velocidad es");
        assert_eq!(preview_text("Física", "Física", "Primera línea\nSegunda"), "Primera línea Segunda");
        assert_eq!(preview_text("Física", "Física", "Física\nSegunda"), "Segunda");
        assert_eq!(preview_text("", "Idea", "• Idea\n• Otra"), "• Otra");
        let long = "palabra ".repeat(60);
        let p = preview_text("T", "T", &long);
        assert!(p.ends_with('…'));
        assert!(p.chars().count() <= PREVIEW_CHARS + 1);
        assert_eq!(preview_text("", "", ""), "");
    }
}
