//! Mantenimiento de arranque: purga de la papelera (> 30 días), recolección de adjuntos
//! huérfanos, limpieza de temporales y reparación del índice de búsqueda.

use crate::blocks;
use crate::boards::{scene_attachment_ids, validate_scene};
use crate::fsutil::remove_dir_quiet;
use crate::model::{NoteKind, StartupReport};
use crate::search_index;
use crate::util::now_ms;
use crate::Core;
use rusqlite::params;
use std::collections::{HashMap, HashSet};
use std::time::{Duration, SystemTime};

/// Antigüedad a partir de la cual se borran los ficheros de `<cache>/tmp`.
pub const TMP_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);

struct NoteAtts {
    kind: NoteKind,
    content: String,
    attachments: Vec<String>,
    /// page_id → attachment_id
    pages: HashMap<String, String>,
}

impl Core {
    /// Ejecuta todo el mantenimiento de arranque. Cada paso es independiente: un fallo se
    /// registra y no impide los demás.
    pub fn startup_maintenance(&self) -> StartupReport {
        let mut report = StartupReport::default();
        match self.purge_expired_trash(now_ms()) {
            Ok(n) => report.purged_trash_items = n,
            Err(e) => log::error!("purga de la papelera: {e:#}"),
        }
        match self.collect_orphan_attachments() {
            Ok(n) => report.orphan_attachments_removed = n,
            Err(e) => log::error!("adjuntos huérfanos: {e:#}"),
        }
        match self.remove_orphan_attachment_dirs() {
            Ok(n) => report.orphan_dirs_removed = n,
            Err(e) => log::error!("directorios huérfanos: {e:#}"),
        }
        self.clean_tmp_dir(TMP_MAX_AGE);
        if let Err(e) = self.repair_search_index_if_needed() {
            log::error!("índice de búsqueda: {e:#}");
        }
        report
    }

    /// Borra adjuntos que ya no referencia su nota: en notas de texto, ni un bloque
    /// `image`/`pdf` ni el `source_page_id` de un bloque de texto; en pizarras, ningún elemento
    /// `image`. Si el contenido no se puede interpretar, no se borra nada de esa nota.
    pub fn collect_orphan_attachments(&self) -> anyhow::Result<u32> {
        let mut notes: HashMap<String, NoteAtts> = HashMap::new();
        {
            let conn = self.db.read();
            let mut s = conn.prepare(
                "SELECT a.id, n.id, n.kind, CASE n.kind WHEN 'board' THEN COALESCE(b.scene, '') ELSE n.body END
                 FROM attachments a JOIN notes n ON n.id = a.note_id
                 LEFT JOIN boards b ON b.note_id = n.id",
            )?;
            let rows = s.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?))
            })?;
            for row in rows {
                let (att, note, kind, content) = row?;
                notes
                    .entry(note)
                    .or_insert_with(|| NoteAtts {
                        kind: NoteKind::from_db(&kind),
                        content,
                        attachments: Vec::new(),
                        pages: HashMap::new(),
                    })
                    .attachments
                    .push(att);
            }
            let mut p = conn.prepare(
                "SELECT p.id, p.attachment_id, a.note_id FROM attachment_pages p
                 JOIN attachments a ON a.id = p.attachment_id",
            )?;
            let rows = p.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
            })?;
            for row in rows {
                let (page, att, note) = row?;
                if let Some(n) = notes.get_mut(&note) {
                    n.pages.insert(page, att);
                }
            }
        }
        let mut orphans: Vec<(String, String)> = Vec::new();
        for (note_id, n) in &notes {
            let referenced: HashSet<String> = match n.kind {
                NoteKind::Text => match blocks::parse(&n.content) {
                    Ok(bs) => {
                        let mut set: HashSet<String> = blocks::referenced_attachments(&bs).into_iter().collect();
                        for b in &bs {
                            if let Some(att) = b.source_page_id.as_ref().and_then(|p| n.pages.get(p)) {
                                set.insert(att.clone());
                            }
                        }
                        set
                    }
                    Err(e) => {
                        log::warn!("nota {note_id}: cuerpo no interpretable, se conservan sus adjuntos: {e}");
                        continue;
                    }
                },
                NoteKind::Board => match validate_scene(&n.content) {
                    Ok(scene) => scene_attachment_ids(&scene).into_iter().collect(),
                    Err(e) => {
                        log::warn!("pizarra {note_id}: escena no interpretable, se conservan sus adjuntos: {e}");
                        continue;
                    }
                },
            };
            for a in &n.attachments {
                if !referenced.contains(a) {
                    orphans.push((a.clone(), note_id.clone()));
                }
            }
        }
        if orphans.is_empty() {
            return Ok(0);
        }
        {
            let mut conn = self.db.write();
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            {
                let mut del = tx.prepare("DELETE FROM attachments WHERE id = ?1")?;
                for (a, _) in &orphans {
                    del.execute(params![a])?;
                }
            }
            let affected: HashSet<&String> = orphans.iter().map(|(_, n)| n).collect();
            let affected: Vec<&String> = affected.into_iter().collect();
            search_index::mark_dirty(&tx, &affected)?;
            tx.commit()?;
        }
        for (a, _) in &orphans {
            remove_dir_quiet(&self.paths.files_dir().join(a));
        }
        self.db.signal().bump();
        log::info!("{} adjuntos huérfanos eliminados", orphans.len());
        Ok(orphans.len() as u32)
    }

    /// Borra directorios de `files/` sin fila en `attachments` (copias interrumpidas).
    pub fn remove_orphan_attachment_dirs(&self) -> anyhow::Result<u32> {
        let files = self.paths.files_dir();
        let Ok(entries) = std::fs::read_dir(&files) else { return Ok(0) };
        let known: HashSet<String> = {
            let conn = self.db.read();
            let mut s = conn.prepare("SELECT id FROM attachments")?;
            let v = s.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            v
        };
        let mut removed = 0;
        for e in entries.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let name = e.file_name().to_string_lossy().into_owned();
            // Solo directorios con forma de UUID: nunca se toca nada ajeno.
            if ft.is_dir() && uuid::Uuid::parse_str(&name).is_ok() && !known.contains(&name) {
                remove_dir_quiet(&e.path());
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Borra ficheros temporales antiguos de `<cache>/tmp`.
    pub fn clean_tmp_dir(&self, max_age: Duration) {
        let Ok(entries) = std::fs::read_dir(self.paths.tmp_dir()) else { return };
        let now = SystemTime::now();
        for e in entries.flatten() {
            let Ok(meta) = e.metadata() else { continue };
            let old = meta
                .modified()
                .ok()
                .and_then(|m| now.duration_since(m).ok())
                .is_some_and(|age| age > max_age);
            if !old {
                continue;
            }
            let res = if meta.is_dir() {
                std::fs::remove_dir_all(e.path())
            } else {
                std::fs::remove_file(e.path())
            };
            if let Err(err) = res {
                log::warn!("no se pudo borrar {}: {err}", e.path().display());
            }
        }
    }

    /// Reconstruye el índice de búsqueda si falta (p. ej. tras una restauración de copia).
    pub fn repair_search_index_if_needed(&self) -> anyhow::Result<bool> {
        let needs: bool = self.db.read().query_row(
            "SELECT EXISTS (SELECT 1 FROM notes n WHERE n.deleted_at IS NULL AND NOT EXISTS
                (SELECT 1 FROM search_docs d WHERE d.note_id = n.id AND d.page_id IS NULL))",
            [],
            |r| r.get(0),
        )?;
        if needs {
            self.rebuild_search_index()?;
        }
        Ok(needs)
    }

    /// Reconstruye por completo el índice de búsqueda. Devuelve el número de documentos.
    pub fn rebuild_search_index(&self) -> anyhow::Result<u32> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let n = search_index::rebuild_all(&tx)?;
        tx.commit()?;
        Ok(n)
    }
}
