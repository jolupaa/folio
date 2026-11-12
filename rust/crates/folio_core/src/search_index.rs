//! Mantenimiento del índice de búsqueda (`search_docs` + `search_fts`) y de las marcas de
//! reindexado para la IA (`index_state.dirty`).
//!
//! Política (consistente en todo el crate):
//! - Un documento por nota NO borrada: título = `display_title`, cuerpo = `plain_text`.
//! - Un documento por página de adjunto NO materializada con texto no vacío, de una nota no
//!   borrada: título = nombre del adjunto, cuerpo = texto de la página.
//! - Las notas en la papelera NO tienen documentos (se eliminan al borrar y se recrean al restaurar).
//! - El trigger `search_docs_ad` borra la fila FTS al borrar un documento (incluido por CASCADE).
//!
//! Estas funciones se llaman dentro de la transacción de la mutación. Tras el commit, el llamador
//! debe invocar `db.signal().bump()` si marcó notas como sucias.

use crate::blocks;
use rusqlite::{params, Connection, OptionalExtension};

/// Inserta o actualiza el documento (note_id, page_id).
fn upsert_doc(
    conn: &Connection,
    note_id: &str,
    page_id: Option<&str>,
    title: &str,
    body: &str,
) -> rusqlite::Result<()> {
    let existing: Option<i64> = conn
        .prepare_cached("SELECT id FROM search_docs WHERE note_id = ?1 AND page_id IS ?2")?
        .query_row(params![note_id, page_id], |r| r.get(0))
        .optional()?;
    match existing {
        Some(id) => {
            let n = conn
                .prepare_cached("UPDATE search_fts SET title = ?2, body = ?3 WHERE rowid = ?1")?
                .execute(params![id, title, body])?;
            if n == 0 {
                // Fila FTS ausente (índice inconsistente): se recrea.
                conn.prepare_cached("INSERT INTO search_fts(rowid, title, body) VALUES (?1, ?2, ?3)")?
                    .execute(params![id, title, body])?;
            }
        }
        None => {
            conn.prepare_cached("INSERT INTO search_docs(note_id, page_id) VALUES (?1, ?2)")?
                .execute(params![note_id, page_id])?;
            let id = conn.last_insert_rowid();
            conn.prepare_cached("INSERT INTO search_fts(rowid, title, body) VALUES (?1, ?2, ?3)")?
                .execute(params![id, title, body])?;
        }
    }
    Ok(())
}

fn remove_doc(conn: &Connection, note_id: &str, page_id: Option<&str>) -> rusqlite::Result<()> {
    conn.prepare_cached("DELETE FROM search_docs WHERE note_id = ?1 AND page_id IS ?2")?
        .execute(params![note_id, page_id])?;
    Ok(())
}

/// Elimina todos los documentos de una nota (al moverla a la papelera).
pub(crate) fn remove_note_docs(conn: &Connection, note_id: &str) -> rusqlite::Result<()> {
    conn.prepare_cached("DELETE FROM search_docs WHERE note_id = ?1")?.execute(params![note_id])?;
    Ok(())
}

/// Sincroniza el documento de nota (título + texto plano) con el estado actual de la fila.
pub(crate) fn sync_note_doc(conn: &Connection, note_id: &str) -> rusqlite::Result<()> {
    let row: Option<(String, String, Option<i64>)> = conn
        .prepare_cached("SELECT title, plain_text, deleted_at FROM notes WHERE id = ?1")?
        .query_row(params![note_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()?;
    match row {
        Some((title, plain, None)) => {
            let shown = blocks::display_title(&title, &plain);
            upsert_doc(conn, note_id, None, &shown, &plain)
        }
        Some((_, _, Some(_))) => remove_note_docs(conn, note_id),
        None => Ok(()),
    }
}

/// Sincroniza el documento de una página de adjunto.
pub(crate) fn sync_page_doc(conn: &Connection, page_id: &str) -> rusqlite::Result<()> {
    let row: Option<(String, String, String, bool, Option<i64>)> = conn
        .prepare_cached(
            "SELECT a.note_id, a.file_name, p.text, p.materialized, n.deleted_at
             FROM attachment_pages p
             JOIN attachments a ON a.id = p.attachment_id
             JOIN notes n ON n.id = a.note_id
             WHERE p.id = ?1",
        )?
        .query_row(params![page_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get::<_, i64>(3)? != 0, r.get(4)?))
        })
        .optional()?;
    let Some((note_id, file_name, text, materialized, deleted_at)) = row else {
        return Ok(());
    };
    if deleted_at.is_some() || materialized || text.trim().is_empty() {
        remove_doc(conn, &note_id, Some(page_id))
    } else {
        upsert_doc(conn, &note_id, Some(page_id), &file_name, &text)
    }
}

/// Ids de todas las páginas de los adjuntos de una nota.
pub(crate) fn note_page_ids(conn: &Connection, note_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut s = conn.prepare_cached(
        "SELECT p.id FROM attachment_pages p JOIN attachments a ON a.id = p.attachment_id
         WHERE a.note_id = ?1 ORDER BY a.created_at, p.page_index",
    )?;
    let v = s.query_map(params![note_id], |r| r.get(0))?.collect();
    v
}

/// Reconstruye todos los documentos de una nota (nota + páginas). Usado al restaurar.
pub(crate) fn sync_all_note_docs(conn: &Connection, note_id: &str) -> rusqlite::Result<()> {
    sync_note_doc(conn, note_id)?;
    for page_id in note_page_ids(conn, note_id)? {
        sync_page_doc(conn, &page_id)?;
    }
    Ok(())
}

/// Marca notas para que el indexador de IA las procese (upsert `index_state.dirty = 1`).
pub(crate) fn mark_dirty<S: AsRef<str>>(conn: &Connection, note_ids: &[S]) -> rusqlite::Result<()> {
    let mut s = conn.prepare_cached(
        "INSERT INTO index_state(note_id, dirty) VALUES (?1, 1)
         ON CONFLICT(note_id) DO UPDATE SET dirty = 1",
    )?;
    for id in note_ids {
        s.execute(params![id.as_ref()])?;
    }
    Ok(())
}

/// Reconstruye por completo el índice de búsqueda (reparación). Devuelve nº de documentos.
pub(crate) fn rebuild_all(conn: &Connection) -> rusqlite::Result<u32> {
    conn.execute("DELETE FROM search_docs", [])?;
    conn.execute("DELETE FROM search_fts", [])?;
    let ids: Vec<String> = {
        let mut s = conn.prepare("SELECT id FROM notes WHERE deleted_at IS NULL")?;
        let v = s.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        v
    };
    for id in &ids {
        sync_all_note_docs(conn, id)?;
    }
    conn.query_row("SELECT count(*) FROM search_docs", [], |r| r.get(0))
}
