//! Búsqueda textual incremental (FTS5): prefijos, sin diacríticos, limitada a un ámbito.
//!
//! Dos fases para que sea rápida con miles de notas:
//! 1. Candidatos: MATCH + filtros de ámbito + `bm25(search_fts, 10.0, 1.0)` (el título pesa
//!    más) ordenados, con LIMIT. Solo se calcula la puntuación.
//! 2. Para los `limit` mejores: `highlight()` del título (¿coincide en el título?) y
//!    `snippet()` del cuerpo (~14 tokens, marcas U+E000/U+E001 y «…»).

use crate::blocks;
use crate::model::{MatchField, NoteKind, SearchHit, SearchResults, SearchScope};
use crate::scope::{fts_match_all, folder_location, folder_subtree};
use crate::Core;
use rusqlite::{params, params_from_iter, OptionalExtension};
use std::collections::HashMap;
use std::time::Instant;

pub const MARK_START: char = '\u{E000}';
pub const MARK_END: char = '\u{E001}';
pub const DEFAULT_LIMIT: u32 = 50;
pub const MAX_LIMIT: u32 = 200;
/// Tokens aproximados por fragmento.
pub const SNIPPET_TOKENS: u32 = 14;

struct Candidate {
    rowid: i64,
    note_id: String,
    page_id: Option<String>,
    kind: String,
    title: String,
    plain_head: String,
    folder_id: Option<String>,
    updated_at: i64,
    score: f64,
    attachment_id: Option<String>,
    attachment_name: Option<String>,
    page_index: Option<u32>,
}

fn one_line(s: &str) -> String {
    s.split(['\n', '\r', '\t']).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ")
}

impl Core {
    /// Búsqueda incremental en títulos, contenido y texto de adjuntos (OCR / PDF) dentro del
    /// ámbito. Consulta sin términos → resultados vacíos. Notas en la papelera excluidas.
    pub fn search(&self, query: &str, scope: &SearchScope, limit: u32) -> anyhow::Result<SearchResults> {
        let started = Instant::now();
        let limit = match limit {
            0 => DEFAULT_LIMIT,
            n => n.min(MAX_LIMIT),
        };
        let empty = |started: Instant| SearchResults {
            query: query.to_string(),
            hits: Vec::new(),
            elapsed_ms: started.elapsed().as_millis() as u32,
        };
        let Some(expr) = fts_match_all(query) else { return Ok(empty(started)) };

        let conn = self.db.read();
        let mut args: Vec<rusqlite::types::Value> = vec![expr.clone().into()];
        let scope_sql = match scope {
            SearchScope::Library => String::new(),
            SearchScope::Note(id) => {
                args.push(id.clone().into());
                "AND d.note_id = ?2".to_string()
            }
            SearchScope::Folder(id) => {
                let ids = folder_subtree(&conn, id)?;
                if ids.is_empty() {
                    return Ok(empty(started));
                }
                let placeholders: Vec<String> =
                    (0..ids.len()).map(|i| format!("?{}", i + 2)).collect();
                args.extend(ids.into_iter().map(Into::into));
                format!("AND n.folder_id IN ({})", placeholders.join(","))
            }
        };
        args.push((limit as i64).into());
        let limit_param = args.len();
        let sql = format!(
            "SELECT search_fts.rowid, d.note_id, d.page_id, n.kind, n.title, substr(n.plain_text, 1, 400),
                    n.folder_id, n.updated_at, bm25(search_fts, 10.0, 1.0) AS rank,
                    p.attachment_id, a.file_name, p.page_index
             FROM search_fts
             JOIN search_docs d ON d.id = search_fts.rowid
             JOIN notes n ON n.id = d.note_id
             LEFT JOIN attachment_pages p ON p.id = d.page_id
             LEFT JOIN attachments a ON a.id = p.attachment_id
             WHERE search_fts MATCH ?1 AND n.deleted_at IS NULL {scope_sql}
             ORDER BY rank, n.updated_at DESC
             LIMIT ?{limit_param}"
        );
        let candidates: Vec<Candidate> = conn
            .prepare_cached(&sql)?
            .query_map(params_from_iter(args.iter()), |r| {
                Ok(Candidate {
                    rowid: r.get(0)?,
                    note_id: r.get(1)?,
                    page_id: r.get(2)?,
                    kind: r.get(3)?,
                    title: r.get(4)?,
                    plain_head: r.get(5)?,
                    folder_id: r.get(6)?,
                    updated_at: r.get(7)?,
                    score: r.get(8)?,
                    attachment_id: r.get(9)?,
                    attachment_name: r.get(10)?,
                    page_index: r.get(11)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;

        let mut detail = conn.prepare_cached(
            "SELECT highlight(search_fts, 0, char(57344), char(57345)),
                    snippet(search_fts, 1, char(57344), char(57345), '…', ?3)
             FROM search_fts WHERE search_fts MATCH ?1 AND rowid = ?2",
        )?;
        let mut locations: HashMap<Option<String>, Vec<String>> = HashMap::new();
        let mut hits = Vec::with_capacity(candidates.len());
        for c in candidates {
            let (title_hl, snippet): (String, String) = detail
                .query_row(params![expr, c.rowid, SNIPPET_TOKENS], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()?
                .unwrap_or_default();
            let matched_in = if c.page_id.is_some() {
                MatchField::Attachment
            } else if title_hl.contains(MARK_START) {
                MatchField::Title
            } else {
                MatchField::Body
            };
            let location = match locations.get(&c.folder_id) {
                Some(l) => l.clone(),
                None => {
                    let l = folder_location(&conn, c.folder_id.as_deref())?;
                    locations.insert(c.folder_id.clone(), l.clone());
                    l
                }
            };
            hits.push(SearchHit {
                note_id: c.note_id,
                note_kind: NoteKind::from_db(&c.kind),
                title: blocks::display_title(&c.title, &c.plain_head),
                snippet: one_line(&snippet),
                matched_in,
                location,
                page_id: c.page_id,
                attachment_id: c.attachment_id,
                attachment_name: c.attachment_name,
                page_index: c.page_index,
                updated_at: c.updated_at,
                score: -c.score,
            });
        }
        Ok(SearchResults {
            query: query.to_string(),
            hits,
            elapsed_ms: started.elapsed().as_millis() as u32,
        })
    }
}
