//! Fragmentación de texto para el índice RAG.
//!
//! Objetivo ~900–1200 caracteres por fragmento, sin partir bloques salvo que un bloque solo supere
//! el máximo (entonces se divide por frases). Solape de 1 segmento entre fragmentos consecutivos
//! (si es corto) y corte preferente en encabezados de nivel 1–2. Cada fragmento conserva la ruta
//! de encabezados como contexto y el id del primer bloque para navegar.

use folio_core::blocks::{BlockType, TextSegment};

pub const MIN_CHARS: usize = 900;
pub const MAX_CHARS: usize = 1200;
/// Un segmento solo se repite como solape si mide como mucho esto.
pub const MAX_OVERLAP_CHARS: usize = 400;

/// Unidad mínima de texto (un bloque o un párrafo) con su posición en el texto plano de origen.
#[derive(Clone, Debug, PartialEq)]
pub struct Piece {
    pub text: String,
    pub block_id: Option<String>,
    pub heading_path: Vec<String>,
    /// Nivel de encabezado (1–3) si el segmento es un encabezado.
    pub heading_level: Option<usize>,
    /// Offset (en caracteres) dentro del texto plano de origen.
    pub char_start: usize,
}

impl Piece {
    fn len(&self) -> usize {
        self.text.chars().count()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChunkDraft {
    pub page_id: Option<String>,
    /// Ruta de encabezados («Tema 2 › Cinemática»), si hay.
    pub heading: Option<String>,
    pub block_id: Option<String>,
    pub text: String,
    pub char_start: usize,
    pub char_end: usize,
}

/// Piezas a partir de los segmentos de un cuerpo de bloques (offsets en el texto plano unido por `\n`).
pub fn pieces_from_segments(segs: &[TextSegment]) -> Vec<Piece> {
    let mut out = Vec::with_capacity(segs.len());
    let mut offset = 0usize;
    for s in segs {
        let len = s.text.chars().count();
        out.push(Piece {
            text: s.text.clone(),
            block_id: Some(s.block_id.clone()),
            heading_path: s.heading_path.clone(),
            heading_level: if s.kind == BlockType::Unknown { None } else { s.kind.heading_level() },
            char_start: offset,
        });
        offset += len + 1;
    }
    out
}

/// Piezas a partir de texto plano (OCR, PDF, pizarra): párrafos separados por líneas en blanco.
pub fn pieces_from_plain(text: &str) -> Vec<Piece> {
    let mut out = Vec::new();
    let mut para = String::new();
    let mut para_start = 0usize;
    let mut offset = 0usize;
    for line in text.split('\n') {
        let len = line.chars().count();
        if line.trim().is_empty() {
            if !para.trim().is_empty() {
                out.push(plain_piece(&para, para_start));
            }
            para.clear();
        } else {
            if para.is_empty() {
                para_start = offset;
            } else {
                para.push('\n');
            }
            para.push_str(line.trim_end());
        }
        offset += len + 1;
    }
    if !para.trim().is_empty() {
        out.push(plain_piece(&para, para_start));
    }
    out
}

fn plain_piece(text: &str, start: usize) -> Piece {
    Piece { text: text.to_string(), block_id: None, heading_path: Vec::new(), heading_level: None, char_start: start }
}

/// Divide piezas más largas que `MAX_CHARS` por frases (o espacios) en trozos ≤ `MAX_CHARS`.
fn split_long(p: Piece) -> Vec<Piece> {
    if p.len() <= MAX_CHARS {
        return vec![p];
    }
    let chars: Vec<char> = p.text.chars().collect();
    let mut out = Vec::new();
    let mut start = 0usize;
    while start < chars.len() {
        let hard_end = (start + MAX_CHARS).min(chars.len());
        let mut end = hard_end;
        if hard_end < chars.len() {
            // Último fin de frase dentro de la ventana (tras la mitad para no crear trozos mínimos).
            let min_cut = start + MAX_CHARS / 2;
            let sentence = (min_cut..hard_end)
                .rev()
                .find(|&i| matches!(chars[i], '.' | '?' | '!' | ';' | '\n') && chars.get(i + 1).is_some_and(|c| c.is_whitespace()));
            end = match sentence {
                Some(i) => i + 1,
                None => (min_cut..hard_end).rev().find(|&i| chars[i].is_whitespace()).map(|i| i + 1).unwrap_or(hard_end),
            };
        }
        let text: String = chars[start..end].iter().collect::<String>();
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            let lead = text.chars().take_while(|c| c.is_whitespace()).count();
            out.push(Piece {
                text: trimmed.to_string(),
                block_id: p.block_id.clone(),
                heading_path: p.heading_path.clone(),
                heading_level: None,
                char_start: p.char_start + start + lead,
            });
        }
        start = end;
    }
    out
}

/// Agrupa piezas en fragmentos.
pub fn chunk_pieces(pieces: Vec<Piece>, page_id: Option<&str>) -> Vec<ChunkDraft> {
    let pieces: Vec<Piece> = pieces.into_iter().flat_map(split_long).collect();
    let mut chunks = Vec::new();
    let mut cur: Vec<Piece> = Vec::new();
    let mut cur_len = 0usize;

    let flush = |cur: &mut Vec<Piece>, chunks: &mut Vec<ChunkDraft>| {
        if cur.is_empty() {
            return;
        }
        let first = &cur[0];
        let last = &cur[cur.len() - 1];
        let heading = if first.heading_path.is_empty() { None } else { Some(first.heading_path.join(" › ")) };
        chunks.push(ChunkDraft {
            page_id: page_id.map(str::to_string),
            heading,
            block_id: first.block_id.clone(),
            text: cur.iter().map(|p| p.text.as_str()).collect::<Vec<_>>().join("\n"),
            char_start: first.char_start,
            char_end: last.char_start + last.len(),
        });
    };

    for p in pieces {
        let plen = p.len();
        let major_heading = p.heading_level.is_some_and(|l| l <= 2);
        let joined = cur_len + usize::from(!cur.is_empty()) + plen;
        let too_big = (joined > MAX_CHARS && cur_len >= MIN_CHARS / 2) || joined > MAX_CHARS * 3 / 2;
        let heading_break = major_heading && cur_len >= MIN_CHARS / 3;
        if !cur.is_empty() && (too_big || heading_break) {
            // Un encabezado no debe quedar huérfano al final del fragmento: pasa al siguiente.
            let mut carry: Vec<Piece> = Vec::new();
            if cur.len() > 1 && cur.last().is_some_and(|l| l.heading_level.is_some()) {
                carry.push(cur.pop().expect("no vacío"));
            }
            let overlap = if carry.is_empty() && !heading_break && cur.len() > 1 {
                cur.last().filter(|l| l.len() <= MAX_OVERLAP_CHARS).cloned()
            } else {
                None
            };
            flush(&mut cur, &mut chunks);
            cur.clear();
            cur.extend(overlap);
            cur.extend(carry);
            cur_len = joined_len(&cur);
        }
        cur_len += usize::from(!cur.is_empty()) + plen;
        cur.push(p);
    }
    flush(&mut cur, &mut chunks);
    chunks
}

fn joined_len(pieces: &[Piece]) -> usize {
    if pieces.is_empty() {
        0
    } else {
        pieces.iter().map(Piece::len).sum::<usize>() + pieces.len() - 1
    }
}

/// Estimación conservadora de tokens (Qwen: ~3,5–4,5 caracteres por token en español).
pub fn estimate_tokens(text: &str) -> usize {
    (text.chars().count() * 10).div_ceil(35)
}

/// Texto de la pizarra a partir de la escena (elementos `text` de arriba abajo, de izquierda a
/// derecha). Respaldo por si `notes.plain_text` no está relleno.
pub fn board_text_from_scene(scene_json: &str) -> String {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(scene_json) else {
        return String::new();
    };
    let mut items: Vec<(f64, f64, String)> = v
        .get("elements")
        .and_then(|e| e.as_array())
        .map(|els| {
            els.iter()
                .filter(|e| e.get("type").and_then(|t| t.as_str()) == Some("text"))
                .filter_map(|e| {
                    let t = e.get("text")?.as_str()?.trim();
                    if t.is_empty() {
                        return None;
                    }
                    let x = e.get("x").and_then(|x| x.as_f64()).unwrap_or(0.0);
                    let y = e.get("y").and_then(|y| y.as_f64()).unwrap_or(0.0);
                    Some((y, x, t.to_string()))
                })
                .collect()
        })
        .unwrap_or_default();
    items.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.total_cmp(&b.1)));
    items.into_iter().map(|i| i.2).collect::<Vec<_>>().join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use folio_core::blocks::{segments, Block};

    fn para(n: usize, word: &str) -> String {
        let mut s = String::new();
        let mut i = 0;
        while s.chars().count() < n {
            s.push_str(&format!("{word}{i} es una frase de prueba. "));
            i += 1;
        }
        s.trim().to_string()
    }

    #[test]
    fn chunks_respect_size_and_overlap() {
        let mut blocks = vec![Block::new(BlockType::Heading1, "Tema 1")];
        for i in 0..12 {
            blocks.push(Block::new(BlockType::Paragraph, para(300, &format!("p{i}x"))));
        }
        let segs = segments(&blocks);
        let chunks = chunk_pieces(pieces_from_segments(&segs), None);
        assert!(chunks.len() >= 3, "{}", chunks.len());
        for c in &chunks {
            let n = c.text.chars().count();
            assert!(n <= MAX_CHARS * 3 / 2, "fragmento de {n}");
            assert!(c.block_id.is_some());
        }
        // Solape: el último párrafo de un fragmento abre el siguiente.
        for w in chunks.windows(2) {
            let last_line = w[0].text.lines().last().unwrap();
            assert!(w[1].text.starts_with(last_line), "sin solape");
        }
        // Contexto de encabezado y offsets coherentes con el texto plano.
        let plain = folio_core::blocks::to_plain_text(&blocks);
        assert_eq!(chunks[1].heading.as_deref(), Some("Tema 1"));
        for c in &chunks {
            let sub: String = plain.chars().skip(c.char_start).take(c.char_end - c.char_start).collect();
            assert_eq!(sub, c.text);
        }
    }

    #[test]
    fn breaks_at_major_headings_and_never_orphans_heading() {
        let blocks = vec![
            Block::new(BlockType::Heading1, "A"),
            Block::new(BlockType::Paragraph, para(500, "a")),
            Block::new(BlockType::Heading1, "B"),
            Block::new(BlockType::Paragraph, para(500, "b")),
        ];
        let chunks = chunk_pieces(pieces_from_segments(&segments(&blocks)), None);
        assert_eq!(chunks.len(), 2);
        assert!(chunks[0].text.starts_with('A'));
        assert!(chunks[1].text.starts_with('B'));
        assert!(!chunks[0].text.contains("\nB\n"));
    }

    #[test]
    fn splits_giant_paragraphs_by_sentence() {
        let p = para(5000, "largo");
        let chunks = chunk_pieces(pieces_from_plain(&p), Some("pg"));
        assert!(chunks.len() >= 4);
        for c in &chunks {
            assert!(c.text.chars().count() <= MAX_CHARS * 3 / 2);
            assert_eq!(c.page_id.as_deref(), Some("pg"));
            assert!(c.text.ends_with('.'), "corte a mitad de frase: …{}", &c.text[c.text.len() - 10..]);
        }
    }

    #[test]
    fn plain_paragraph_offsets() {
        let text = "Linea uno\nlinea dos\n\n\nOtro párrafo";
        let ps = pieces_from_plain(text);
        assert_eq!(ps.len(), 2);
        assert_eq!(ps[0].text, "Linea uno\nlinea dos");
        let sub: String = text.chars().skip(ps[1].char_start).take(ps[1].len()).collect();
        assert_eq!(sub, "Otro párrafo");
    }

    #[test]
    fn board_scene_text_in_reading_order() {
        let scene = r#"{"version":1,"elements":[
            {"id":"t2","type":"text","x":300,"y":10,"text":"Derecha"},
            {"id":"t1","type":"text","x":10,"y":10,"text":"Izquierda"},
            {"id":"s","type":"stroke","points":[]},
            {"id":"t3","type":"text","x":0,"y":200,"text":"Abajo"}]}"#;
        assert_eq!(board_text_from_scene(scene), "Izquierda\n\nDerecha\n\nAbajo");
        assert_eq!(board_text_from_scene("no json"), "");
    }

    #[test]
    fn token_estimate_is_conservative() {
        assert_eq!(estimate_tokens(""), 0);
        assert_eq!(estimate_tokens(&"a".repeat(35)), 10);
    }
}
