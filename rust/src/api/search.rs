use crate::api::types::*;
use crate::convert::vec;
use crate::state;

/// Búsqueda textual incremental (FTS5, prefijos, sin diacríticos) en títulos, contenido y texto
/// de adjuntos (OCR / PDF), limitada al ámbito. Consulta vacía → resultados vacíos.
pub fn search(query: String, scope: SearchScope, limit: u32) -> anyhow::Result<SearchResults> { Ok(state::get()?.core.search(&query, &scope.into(), limit)?.into()) }

/// Coincidencias de `query` en `text` sin distinguir mayúsculas ni diacríticos.
/// Offsets en unidades UTF-16 (para resaltar en Dart). Usado por «Buscar en esta nota».
#[flutter_rust_bridge::frb(sync)]
pub fn find_in_text(text: String, query: String) -> Vec<TextMatch> { vec(folio_core::text_find::find_in_text(&text, &query)) }
