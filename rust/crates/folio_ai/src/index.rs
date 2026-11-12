//! Índice RAG: fragmentación incremental de notas (reutilizando fragmentos por hash),
//! embeddings pendientes y recuperación híbrida BM25 + coseno con RRF, siempre dentro del ámbito.

use crate::chunker::{self, ChunkDraft};
use crate::engine::dot;
use crate::types::IndexStatus;
use folio_core::scope::{fts_match_any, note_ids_in_scope, ScopeSpec};
use folio_core::util::now_ms;
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

pub const STOPWORDS: &[&str] = &[
    "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "al", "a", "en", "y", "o", "u", "que", "qué",
    "es", "son", "se", "su", "sus", "por", "para", "con", "sin", "como", "cómo", "cuál", "cuáles", "cual", "lo", "le",
    "les", "me", "mi", "mis", "tu", "tus", "sobre", "entre", "más", "muy", "ya", "hay", "ser", "está", "están", "esta",
    "este", "esto", "eso", "esa", "ese", "cuando", "cuándo", "donde", "dónde", "quién", "quien", "porque", "pero", "si",
    "sí", "no", "the", "an", "of", "to", "in", "and", "or", "is", "are", "was", "were", "be", "what", "which", "who",
    "how", "why", "when", "where", "for", "on", "with", "by", "at", "from", "it", "its", "this", "that", "these", "those",
    "do", "does", "did", "can", "about", "as", "me", "my", "explica", "explícame", "dime", "explain", "tell",
];

fn chunk_hash(d: &ChunkDraft) -> String {
    let mut h = Sha256::new();
    h.update(d.page_id.as_deref().unwrap_or("").as_bytes());
    h.update([0]);
    h.update(d.heading.as_deref().unwrap_or("").as_bytes());
    h.update([0]);
    h.update(d.text.as_bytes());
    hex::encode(h.finalize())
}

/// Fragmentos que debería tener la nota ahora mismo.
fn drafts_for_note(conn: &Connection, note_id: &str) -> rusqlite::Result<Option<Vec<ChunkDraft>>> {
    let row: Option<(String, String, String)> = conn
        .query_row("SELECT kind, body, plain_text FROM notes WHERE id = ?1", params![note_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .optional()?;
    let Some((kind, body, plain)) = row else { return Ok(None) };
    let mut drafts = Vec::new();
    if kind == "board" {
        let text = if plain.trim().is_empty() {
            let scene: Option<String> =
                conn.query_row("SELECT scene FROM boards WHERE note_id = ?1", params![note_id], |r| r.get(0)).optional()?;
            scene.map(|s| chunker::board_text_from_scene(&s)).unwrap_or_default()
        } else {
            plain
        };
        drafts.extend(chunker::chunk_pieces(chunker::pieces_from_plain(&text), None));
    } else {
        let pieces = match folio_core::blocks::parse(&body) {
            Ok(blocks) => chunker::pieces_from_segments(&folio_core::blocks::segments(&blocks)),
            Err(_) => chunker::pieces_from_plain(&plain),
        };
        drafts.extend(chunker::chunk_pieces(pieces, None));
    }
    // Páginas de adjuntos cuyo texto NO está copiado en el cuerpo.
    let mut s = conn.prepare_cached(
        "SELECT p.id, p.text FROM attachment_pages p JOIN attachments a ON a.id = p.attachment_id
         WHERE a.note_id = ?1 AND p.materialized = 0 AND length(trim(p.text)) > 0
         ORDER BY a.created_at, a.id, p.page_index",
    )?;
    let pages: Vec<(String, String)> = s.query_map(params![note_id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    for (page_id, text) in pages {
        drafts.extend(chunker::chunk_pieces(chunker::pieces_from_plain(&text), Some(&page_id)));
    }
    Ok(Some(drafts))
}

/// Reindexa una nota en una transacción: reutiliza los fragmentos sin cambios (conservan su
/// embedding), inserta los nuevos, borra los obsoletos y marca `dirty = 0`.
/// Devuelve (reutilizados, insertados, borrados).
pub fn index_note(conn: &Connection, note_id: &str) -> anyhow::Result<(usize, usize, usize)> {
    conn.execute_batch("BEGIN IMMEDIATE")?;
    let r = index_note_tx(conn, note_id);
    match &r {
        Ok(_) => conn.execute_batch("COMMIT")?,
        Err(_) => {
            let _ = conn.execute_batch("ROLLBACK");
        }
    }
    r
}

fn index_note_tx(conn: &Connection, note_id: &str) -> anyhow::Result<(usize, usize, usize)> {
    let Some(drafts) = drafts_for_note(conn, note_id)? else {
        conn.execute("DELETE FROM index_state WHERE note_id = ?1", params![note_id])?;
        return Ok((0, 0, 0));
    };
    let mut existing: HashMap<String, Vec<i64>> = HashMap::new();
    {
        let mut s = conn.prepare_cached("SELECT id, hash FROM chunks WHERE note_id = ?1 ORDER BY id DESC")?;
        for row in s.query_map(params![note_id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (id, hash) = row?;
            existing.entry(hash).or_default().push(id);
        }
    }
    let (mut reused, mut inserted) = (0, 0);
    let mut content = Sha256::new();
    for (ord, d) in drafts.iter().enumerate() {
        let hash = chunk_hash(d);
        content.update(hash.as_bytes());
        if let Some(id) = existing.get_mut(&hash).and_then(|v| v.pop()) {
            conn.execute(
                "UPDATE chunks SET ord = ?2, block_id = ?3, char_start = ?4, char_end = ?5 WHERE id = ?1",
                params![id, ord as i64, d.block_id, d.char_start as i64, d.char_end as i64],
            )?;
            reused += 1;
        } else {
            conn.execute(
                "INSERT INTO chunks(note_id,page_id,ord,heading,block_id,text,char_start,char_end,hash,token_estimate)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                params![
                    note_id,
                    d.page_id,
                    ord as i64,
                    d.heading,
                    d.block_id,
                    d.text,
                    d.char_start as i64,
                    d.char_end as i64,
                    hash,
                    chunker::estimate_tokens(&d.text) as i64
                ],
            )?;
            inserted += 1;
        }
    }
    let mut deleted = 0;
    for id in existing.into_values().flatten() {
        conn.execute("DELETE FROM chunks WHERE id = ?1", params![id])?;
        deleted += 1;
    }
    conn.execute(
        "INSERT INTO index_state(note_id, content_hash, dirty, chunked_at, error) VALUES (?1, ?2, 0, ?3, NULL)
         ON CONFLICT(note_id) DO UPDATE SET content_hash = excluded.content_hash, dirty = 0,
           chunked_at = excluded.chunked_at, error = NULL",
        params![note_id, hex::encode(content.finalize()), now_ms()],
    )?;
    Ok((reused, inserted, deleted))
}

/// Crea filas de estado para notas que aún no la tienen (p. ej. bases de datos antiguas).
pub fn ensure_index_rows(conn: &Connection) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO index_state(note_id, dirty) SELECT id, 1 FROM notes
         WHERE id NOT IN (SELECT note_id FROM index_state)",
        [],
    )
}

pub fn dirty_notes(conn: &Connection, limit: usize) -> rusqlite::Result<Vec<String>> {
    let mut s = conn.prepare_cached("SELECT note_id FROM index_state WHERE dirty = 1 LIMIT ?1")?;
    let v = s.query_map(params![limit as i64], |r| r.get(0))?.collect();
    v
}

/// Fragmentos de notas no borradas sin embedding del modelo indicado: (id, texto a embeber).
pub fn chunks_pending_embedding(conn: &Connection, model_id: &str, limit: usize) -> rusqlite::Result<Vec<(i64, String)>> {
    let mut s = conn.prepare_cached(
        "SELECT c.id, n.title, c.heading, c.text FROM chunks c JOIN notes n ON n.id = c.note_id
         LEFT JOIN chunk_embeddings e ON e.chunk_id = c.id AND e.model_id = ?1
         WHERE e.chunk_id IS NULL AND n.deleted_at IS NULL ORDER BY c.id LIMIT ?2",
    )?;
    let v = s
        .query_map(params![model_id, limit as i64], |r| {
            let title: String = r.get(1)?;
            let heading: Option<String> = r.get(2)?;
            let text: String = r.get(3)?;
            Ok((r.get(0)?, embed_text(&title, heading.as_deref(), &text)))
        })?
        .collect();
    v
}

/// Texto que se embebe: título y encabezados dan contexto al fragmento.
pub fn embed_text(title: &str, heading: Option<&str>, text: &str) -> String {
    let mut s = String::new();
    if !title.trim().is_empty() {
        s.push_str(title.trim());
        s.push('\n');
    }
    if let Some(h) = heading.filter(|h| !h.trim().is_empty()) {
        s.push_str(h);
        s.push('\n');
    }
    s.push_str(text);
    s
}

pub fn store_embedding(conn: &Connection, chunk_id: i64, model_id: &str, vec: &[f32]) -> rusqlite::Result<()> {
    let mut blob = Vec::with_capacity(vec.len() * 4);
    for v in vec {
        blob.extend_from_slice(&v.to_le_bytes());
    }
    // El fragmento puede haberse borrado mientras se calculaba: INSERT … SELECT lo ignora.
    conn.execute(
        "INSERT OR REPLACE INTO chunk_embeddings(chunk_id, model_id, dim, vec)
         SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM chunks WHERE id = ?1)",
        params![chunk_id, model_id, vec.len() as i64, blob],
    )?;
    Ok(())
}

fn blob_to_vec(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect()
}

pub fn status(conn: &Connection, model_id: Option<&str>, running: bool, last_error: Option<String>) -> rusqlite::Result<IndexStatus> {
    let one = |sql: &str| -> rusqlite::Result<u32> { conn.query_row(sql, [], |r| r.get(0)) };
    let embedded = match model_id {
        Some(m) => conn.query_row(
            "SELECT count(*) FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id JOIN notes n ON n.id = c.note_id
             WHERE e.model_id = ?1 AND n.deleted_at IS NULL",
            params![m],
            |r| r.get(0),
        )?,
        None => 0,
    };
    Ok(IndexStatus {
        total_notes: one("SELECT count(*) FROM notes WHERE deleted_at IS NULL")?,
        pending_notes: one(
            "SELECT count(*) FROM notes n LEFT JOIN index_state s ON s.note_id = n.id
             WHERE n.deleted_at IS NULL AND (s.note_id IS NULL OR s.dirty = 1)",
        )?,
        chunk_count: one("SELECT count(*) FROM chunks c JOIN notes n ON n.id = c.note_id WHERE n.deleted_at IS NULL")?,
        embedded_chunk_count: embedded,
        embedding_model_id: model_id.map(str::to_string),
        running,
        last_error,
    })
}

// ─────────────────────────── Recuperación ───────────────────────────

/// Fragmento recuperado con los datos necesarios para citarlo.
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub chunk_id: i64,
    pub note_id: String,
    pub note_title: String,
    pub folder_id: Option<String>,
    pub page_id: Option<String>,
    pub attachment_name: Option<String>,
    pub page_index: Option<u32>,
    pub heading: Option<String>,
    pub block_id: Option<String>,
    pub text: String,
    pub tokens: usize,
    pub score: f64,
}

const HIT_SELECT: &str = "SELECT c.id, c.note_id, n.title, n.plain_text, n.folder_id, c.page_id, a.file_name, p.page_index,
        c.heading, c.block_id, c.text, c.token_estimate
     FROM chunks c JOIN notes n ON n.id = c.note_id
     LEFT JOIN attachment_pages p ON p.id = c.page_id
     LEFT JOIN attachments a ON a.id = p.attachment_id";

fn hit_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Hit> {
    let title: String = r.get(2)?;
    let plain: String = r.get(3)?;
    Ok(Hit {
        chunk_id: r.get(0)?,
        note_id: r.get(1)?,
        note_title: {
            let t = folio_core::blocks::display_title(&title, &plain);
            if t.is_empty() { "Sin título".to_string() } else { t }
        },
        folder_id: r.get(4)?,
        page_id: r.get(5)?,
        attachment_name: r.get(6)?,
        page_index: r.get(7)?,
        heading: r.get(8)?,
        block_id: r.get(9)?,
        text: r.get(10)?,
        tokens: r.get::<_, i64>(11)? as usize,
        score: 0.0,
    })
}

/// Carga el ámbito en una tabla temporal de la conexión. Devuelve el nº de notas (no borradas).
pub fn load_scope(conn: &Connection, scope: &ScopeSpec) -> anyhow::Result<usize> {
    conn.execute_batch(
        "CREATE TEMP TABLE IF NOT EXISTS scope_notes(id TEXT PRIMARY KEY); DELETE FROM temp.scope_notes;",
    )?;
    let ids = note_ids_in_scope(conn, scope)?;
    let mut ins = conn.prepare_cached("INSERT OR IGNORE INTO temp.scope_notes(id) VALUES (?1)")?;
    for id in &ids {
        ins.execute(params![id])?;
    }
    Ok(ids.len())
}

/// Recuperación híbrida dentro del ámbito cargado con `load_scope`. `query_vec` es el embedding
/// normalizado de la consulta (si hay modelo de embeddings).
pub fn retrieve(
    conn: &Connection,
    query: &str,
    query_vec: Option<(&str, &[f32])>,
    top_k: usize,
) -> anyhow::Result<Vec<Hit>> {
    const PER_LIST: usize = 50;
    const RRF_K: f64 = 60.0;
    let mut scores: HashMap<i64, f64> = HashMap::new();

    if let Some(expr) = fts_match_any(query, STOPWORDS) {
        let mut s = conn.prepare_cached(
            "SELECT c.id FROM chunks_fts f JOIN chunks c ON c.id = f.rowid
             JOIN temp.scope_notes sn ON sn.id = c.note_id
             WHERE chunks_fts MATCH ?1 ORDER BY bm25(chunks_fts) LIMIT ?2",
        )?;
        let ids: Vec<i64> = s.query_map(params![expr, PER_LIST as i64], |r| r.get(0))?.collect::<Result<_, _>>()?;
        for (rank, id) in ids.into_iter().enumerate() {
            *scores.entry(id).or_default() += 1.0 / (RRF_K + rank as f64 + 1.0);
        }
    }

    if let Some((model_id, qv)) = query_vec {
        let mut s = conn.prepare_cached(
            "SELECT e.chunk_id, e.vec FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id
             JOIN temp.scope_notes sn ON sn.id = c.note_id WHERE e.model_id = ?1 AND e.dim = ?2",
        )?;
        let mut sims: Vec<(i64, f32)> = s
            .query_map(params![model_id, qv.len() as i64], |r| {
                let blob: Vec<u8> = r.get(1)?;
                Ok((r.get::<_, i64>(0)?, dot(qv, &blob_to_vec(&blob))))
            })?
            .collect::<Result<_, _>>()?;
        sims.sort_by(|a, b| b.1.total_cmp(&a.1));
        for (rank, (id, sim)) in sims.into_iter().take(PER_LIST).enumerate() {
            // Similitudes muy bajas no aportan evidencia.
            if sim < 0.2 {
                break;
            }
            *scores.entry(id).or_default() += 1.0 / (RRF_K + rank as f64 + 1.0);
        }
    }

    let mut ranked: Vec<(i64, f64)> = scores.into_iter().collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    ranked.truncate(top_k);
    let mut s = conn.prepare_cached(&format!("{HIT_SELECT} WHERE c.id = ?1 AND n.deleted_at IS NULL"))?;
    let mut out = Vec::with_capacity(ranked.len());
    for (id, score) in ranked {
        if let Some(mut h) = s.query_row(params![id], hit_from_row).optional()? {
            h.score = score;
            out.push(h);
        }
    }
    Ok(out)
}

/// Todos los fragmentos del ámbito cargado, en orden de lectura (para resúmenes y estudio).
pub fn all_chunks_in_scope(conn: &Connection) -> anyhow::Result<Vec<Hit>> {
    let mut s = conn.prepare_cached(&format!(
        "{HIT_SELECT} JOIN temp.scope_notes sn ON sn.id = c.note_id WHERE n.deleted_at IS NULL
         ORDER BY n.created_at, n.id, c.ord"
    ))?;
    let v = s.query_map([], hit_from_row)?.collect::<Result<Vec<_>, _>>()?;
    Ok(v)
}
