//! Papelera: listado, restauración, borrado definitivo, vaciado y purga automática (> 30 días).
//!
//! Modelo: `deleted_at` marca un lote. `trash_folder` asigna el mismo `deleted_at` a la carpeta,
//! a su subárbol y a sus notas activas; lo que ya estaba en la papelera conserva su fecha.
//! Invariante: lo que cuelga de una carpeta borrada también está borrado.

use crate::blocks;
use crate::folders::{ancestors, folder_deleted_state, subtree_all};
use crate::fsutil::remove_dir_quiet;
use crate::model::{NoteKind, TrashItem, TrashKind, DAY_MS, TRASH_RETENTION_DAYS};
use crate::notes::note_meta;
use crate::scope::folder_location;
use crate::search_index;
use crate::util::now_ms;
use crate::Core;
use anyhow::bail;
use rusqlite::{params, Connection};

fn days_left(deleted_at: i64, now: i64) -> u32 {
    let expires = deleted_at + TRASH_RETENTION_DAYS * DAY_MS;
    let remaining = expires - now;
    if remaining <= 0 {
        0
    } else {
        ((remaining + DAY_MS - 1) / DAY_MS).min(TRASH_RETENTION_DAYS) as u32
    }
}

/// Carpetas del lote de `folder_id`: la propia y descendientes con el mismo `deleted_at`.
fn folder_batch(conn: &Connection, folder_id: &str, deleted_at: i64) -> rusqlite::Result<Vec<String>> {
    let mut s = conn.prepare_cached(
        "WITH RECURSIVE sub(id, depth) AS (
             SELECT ?1, 0
             UNION
             SELECT c.id, sub.depth + 1 FROM folders c JOIN sub ON c.parent_id = sub.id
             WHERE c.deleted_at = ?2 AND sub.depth < 256
         )
         SELECT DISTINCT id FROM sub",
    )?;
    let v = s.query_map(params![folder_id, deleted_at], |r| r.get(0))?.collect();
    v
}

fn notes_in_folders_with(conn: &Connection, folders: &[String], deleted_at: i64) -> rusqlite::Result<Vec<String>> {
    let mut s = conn.prepare_cached("SELECT id FROM notes WHERE folder_id = ?1 AND deleted_at = ?2")?;
    let mut out = Vec::new();
    for f in folders {
        for id in s.query_map(params![f, deleted_at], |r| r.get::<_, String>(0))? {
            out.push(id?);
        }
    }
    Ok(out)
}

/// Restaura (solo la carpeta, no su contenido) los ancestros borrados de una carpeta.
fn restore_ancestor_folders(conn: &Connection, folder_id: &str) -> rusqlite::Result<()> {
    let mut upd = conn.prepare_cached("UPDATE folders SET deleted_at = NULL WHERE id = ?1")?;
    for (id, deleted) in ancestors(conn, folder_id)? {
        if deleted.is_some() {
            upd.execute(params![id])?;
        }
    }
    Ok(())
}

/// Borra definitivamente notas (CASCADE: adjuntos, páginas, pizarra, búsqueda, chunks,
/// index_state). Devuelve los ids de adjuntos cuyos ficheros hay que borrar tras el commit.
fn purge_notes(conn: &Connection, note_ids: &[String]) -> rusqlite::Result<Vec<String>> {
    let mut atts = Vec::new();
    let mut sel = conn.prepare_cached("SELECT id FROM attachments WHERE note_id = ?1")?;
    let mut del = conn.prepare_cached("DELETE FROM notes WHERE id = ?1")?;
    for n in note_ids {
        for a in sel.query_map(params![n], |r| r.get::<_, String>(0))? {
            atts.push(a?);
        }
        del.execute(params![n])?;
    }
    Ok(atts)
}

/// Borra definitivamente una carpeta de la papelera y su subárbol. Las notas borradas del
/// subárbol se eliminan; si (por inconsistencia) hubiera notas activas, pasan a la bandeja.
fn purge_folder(conn: &Connection, folder_id: &str) -> rusqlite::Result<Vec<String>> {
    let subtree = subtree_all(conn, folder_id)?;
    let mut deleted_notes = Vec::new();
    {
        let mut s = conn.prepare_cached("SELECT id, deleted_at FROM notes WHERE folder_id = ?1")?;
        let mut rescue = conn.prepare_cached("UPDATE notes SET folder_id = NULL WHERE id = ?1")?;
        for f in &subtree {
            let rows: Vec<(String, Option<i64>)> = s
                .query_map(params![f], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
            for (id, del) in rows {
                if del.is_some() {
                    deleted_notes.push(id);
                } else {
                    log::warn!("nota activa {id} dentro de una carpeta en la papelera: pasa a «Notas»");
                    rescue.execute(params![id])?;
                }
            }
        }
    }
    let atts = purge_notes(conn, &deleted_notes)?;
    conn.prepare_cached("DELETE FROM folders WHERE id = ?1")?.execute(params![folder_id])?;
    Ok(atts)
}

struct TopLevel {
    folders: Vec<(String, i64)>,
    notes: Vec<(String, i64)>,
}

/// Elementos de primer nivel de la papelera: carpetas borradas cuyo padre no lo está y notas
/// borradas cuya carpeta no está borrada.
fn top_level(conn: &Connection) -> rusqlite::Result<TopLevel> {
    let folders = conn
        .prepare_cached(
            "SELECT f.id, f.deleted_at FROM folders f
             WHERE f.deleted_at IS NOT NULL AND NOT EXISTS
               (SELECT 1 FROM folders p WHERE p.id = f.parent_id AND p.deleted_at IS NOT NULL)",
        )?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let notes = conn
        .prepare_cached(
            "SELECT n.id, n.deleted_at FROM notes n
             WHERE n.deleted_at IS NOT NULL AND NOT EXISTS
               (SELECT 1 FROM folders p WHERE p.id = n.folder_id AND p.deleted_at IS NOT NULL)",
        )?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(TopLevel { folders, notes })
}

impl Core {
    fn remove_attachment_dirs(&self, ids: &[String]) {
        for id in ids {
            remove_dir_quiet(&self.paths.files_dir().join(id));
        }
    }

    /// Carpetas borradas de nivel superior + notas borradas cuya carpeta no está en la papelera,
    /// de la más reciente a la más antigua.
    pub fn list_trash(&self) -> anyhow::Result<Vec<TrashItem>> {
        let conn = self.db.read();
        let now = now_ms();
        let top = top_level(&conn)?;
        let mut items = Vec::with_capacity(top.folders.len() + top.notes.len());
        for (id, deleted_at) in top.folders {
            let (name, parent): (String, Option<String>) = conn.query_row(
                "SELECT name, parent_id FROM folders WHERE id = ?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            let batch = folder_batch(&conn, &id, deleted_at)?;
            let contained = notes_in_folders_with(&conn, &batch, deleted_at)?.len() as u32;
            items.push(TrashItem {
                kind: TrashKind::Folder,
                id,
                title: name,
                note_kind: None,
                original_location: folder_location(&conn, parent.as_deref())?,
                contained_notes: contained,
                deleted_at,
                days_left: days_left(deleted_at, now),
            });
        }
        for (id, deleted_at) in top.notes {
            let (title, plain, kind, folder): (String, String, String, Option<String>) = conn.query_row(
                "SELECT title, substr(plain_text, 1, 400), kind, folder_id FROM notes WHERE id = ?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )?;
            items.push(TrashItem {
                kind: TrashKind::Note,
                id,
                title: blocks::display_title(&title, &plain),
                note_kind: Some(NoteKind::from_db(&kind)),
                original_location: folder_location(&conn, folder.as_deref())?,
                contained_notes: 0,
                deleted_at,
                days_left: days_left(deleted_at, now),
            });
        }
        items.sort_by(|a, b| b.deleted_at.cmp(&a.deleted_at).then_with(|| a.id.cmp(&b.id)));
        Ok(items)
    }

    /// Restaurar nota: también restaura sus carpetas ancestro borradas (solo las carpetas).
    /// Restaurar carpeta: restaura su lote (subárbol y notas con el mismo `deleted_at`) y sus
    /// ancestros borrados. Lo borrado en otro momento sigue en la papelera.
    pub fn restore_from_trash(&self, kind: TrashKind, id: &str) -> anyhow::Result<()> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let restored_notes: Vec<String> = match kind {
            TrashKind::Note => {
                let meta = note_meta(&tx, id)?;
                if meta.deleted_at.is_none() {
                    return Ok(());
                }
                if let Some(f) = &meta.folder_id {
                    if folder_deleted_state(&tx, f)?.flatten().is_some() {
                        tx.execute("UPDATE folders SET deleted_at = NULL WHERE id = ?1", params![f])?;
                    }
                    restore_ancestor_folders(&tx, f)?;
                }
                tx.execute("UPDATE notes SET deleted_at = NULL WHERE id = ?1", params![id])?;
                vec![id.to_string()]
            }
            TrashKind::Folder => {
                let deleted_at = match folder_deleted_state(&tx, id)? {
                    None => bail!("La carpeta no existe"),
                    Some(None) => return Ok(()),
                    Some(Some(t)) => t,
                };
                restore_ancestor_folders(&tx, id)?;
                let batch = folder_batch(&tx, id, deleted_at)?;
                let notes = notes_in_folders_with(&tx, &batch, deleted_at)?;
                {
                    let mut f = tx.prepare_cached("UPDATE folders SET deleted_at = NULL WHERE id = ?1")?;
                    for fid in &batch {
                        f.execute(params![fid])?;
                    }
                    let mut n = tx.prepare_cached("UPDATE notes SET deleted_at = NULL WHERE id = ?1")?;
                    for nid in &notes {
                        n.execute(params![nid])?;
                    }
                }
                notes
            }
        };
        for n in &restored_notes {
            search_index::sync_all_note_docs(&tx, n)?;
        }
        search_index::mark_dirty(&tx, &restored_notes)?;
        tx.commit()?;
        drop(conn);
        self.db.signal().bump();
        Ok(())
    }

    /// Borra definitivamente un elemento de la papelera (incluye ficheros, índices y chunks).
    pub fn delete_permanently(&self, kind: TrashKind, id: &str) -> anyhow::Result<()> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let atts = match kind {
            TrashKind::Note => {
                let meta = note_meta(&tx, id)?;
                if meta.deleted_at.is_none() {
                    bail!("La nota no está en la papelera");
                }
                purge_notes(&tx, &[id.to_string()])?
            }
            TrashKind::Folder => {
                match folder_deleted_state(&tx, id)? {
                    None => bail!("La carpeta no existe"),
                    Some(None) => bail!("La carpeta no está en la papelera"),
                    Some(Some(_)) => {}
                }
                purge_folder(&tx, id)?
            }
        };
        tx.commit()?;
        drop(conn);
        self.remove_attachment_dirs(&atts);
        self.db.signal().bump();
        Ok(())
    }

    /// Vacía la papelera. Devuelve el número de elementos (como se listan) eliminados.
    pub fn empty_trash(&self) -> anyhow::Result<u32> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let top = top_level(&tx)?;
        let count = (top.folders.len() + top.notes.len()) as u32;
        let mut atts = Vec::new();
        for (f, _) in &top.folders {
            atts.extend(purge_folder(&tx, f)?);
        }
        let notes: Vec<String> = top.notes.into_iter().map(|(n, _)| n).collect();
        atts.extend(purge_notes(&tx, &notes)?);
        // Restos inconsistentes (no deberían existir).
        let leftovers: Vec<String> = tx
            .prepare("SELECT id FROM notes WHERE deleted_at IS NOT NULL")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        atts.extend(purge_notes(&tx, &leftovers)?);
        tx.commit()?;
        drop(conn);
        self.remove_attachment_dirs(&atts);
        if count > 0 {
            self.db.signal().bump();
        }
        Ok(count)
    }

    /// Purga lo que lleva en la papelera más de 30 días respecto a `now`. Cuenta elementos como
    /// se muestran (una carpeta con su contenido = 1). Devuelve el número de elementos purgados.
    pub fn purge_expired_trash(&self, now: i64) -> anyhow::Result<u32> {
        let cutoff = now - TRASH_RETENTION_DAYS * DAY_MS;
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // Carpetas caducadas más altas de su cadena (su padre no está caducado).
        let folders: Vec<String> = tx
            .prepare(
                "SELECT f.id FROM folders f
                 WHERE f.deleted_at IS NOT NULL AND f.deleted_at < ?1 AND NOT EXISTS
                   (SELECT 1 FROM folders p WHERE p.id = f.parent_id
                      AND p.deleted_at IS NOT NULL AND p.deleted_at < ?1)",
            )?
            .query_map(params![cutoff], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        let mut atts = Vec::new();
        for f in &folders {
            atts.extend(purge_folder(&tx, f)?);
        }
        let notes: Vec<String> = tx
            .prepare("SELECT id FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?1")?
            .query_map(params![cutoff], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        atts.extend(purge_notes(&tx, &notes)?);
        tx.commit()?;
        drop(conn);
        self.remove_attachment_dirs(&atts);
        let count = (folders.len() + notes.len()) as u32;
        if count > 0 {
            log::info!("papelera: {count} elementos purgados por antigüedad");
            self.db.signal().bump();
        }
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_left_rounds_up_and_clamps() {
        let now = 1_000 * DAY_MS;
        assert_eq!(days_left(now, now), 30);
        assert_eq!(days_left(now - 1, now), 30);
        assert_eq!(days_left(now - DAY_MS, now), 29);
        assert_eq!(days_left(now - 29 * DAY_MS - 1, now), 1);
        assert_eq!(days_left(now - 30 * DAY_MS, now), 0);
        assert_eq!(days_left(now - 40 * DAY_MS, now), 0);
    }
}
