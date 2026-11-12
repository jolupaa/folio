//! Cuerpo de las notas de texto: lista JSON de bloques (contrato en docs/CONTRATOS.md §1).
//!
//! Rust valida el JSON pero guarda la cadena original tal cual (la UI puede añadir campos
//! opcionales sin que Rust los pierda). Aquí se deriva el texto plano para búsqueda e IA.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BlockType {
    Heading1,
    Heading2,
    Heading3,
    Paragraph,
    Bullet,
    Numbered,
    Todo,
    Quote,
    Divider,
    Image,
    Pdf,
    BoardLink,
    /// Tipos futuros desconocidos: se conservan y se ignoran al derivar texto.
    #[serde(other)]
    Unknown,
}

impl BlockType {
    pub fn is_heading(self) -> bool {
        matches!(self, BlockType::Heading1 | BlockType::Heading2 | BlockType::Heading3)
    }
    pub fn heading_level(self) -> Option<usize> {
        match self {
            BlockType::Heading1 => Some(1),
            BlockType::Heading2 => Some(2),
            BlockType::Heading3 => Some(3),
            _ => None,
        }
    }
    pub fn has_text(self) -> bool {
        matches!(
            self,
            BlockType::Heading1
                | BlockType::Heading2
                | BlockType::Heading3
                | BlockType::Paragraph
                | BlockType::Bullet
                | BlockType::Numbered
                | BlockType::Todo
                | BlockType::Quote
        )
    }
}

fn is_false(b: &bool) -> bool {
    !*b
}
fn is_zero(n: &u8) -> bool {
    *n == 0
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Block {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: BlockType,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub checked: bool,
    /// Sangría de listas 0..=3.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub indent: u8,
    /// Para `image` / `pdf`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment_id: Option<String>,
    /// Para `board_link`: id de la pizarra enlazada.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note_id: Option<String>,
    /// Texto procedente de OCR: página de adjunto de origen (vínculo texto ↔ imagen).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_page_id: Option<String>,
}

impl Block {
    pub fn new(kind: BlockType, text: impl Into<String>) -> Block {
        Block {
            id: crate::util::new_id(),
            kind,
            text: text.into(),
            checked: false,
            indent: 0,
            attachment_id: None,
            note_id: None,
            source_page_id: None,
        }
    }
}

/// Parsea y valida el cuerpo. Acepta "" como lista vacía.
pub fn parse(body_json: &str) -> anyhow::Result<Vec<Block>> {
    if body_json.trim().is_empty() {
        return Ok(Vec::new());
    }
    let blocks: Vec<Block> = serde_json::from_str(body_json)
        .map_err(|e| anyhow::anyhow!("Cuerpo de nota no válido: {e}"))?;
    let mut seen = std::collections::HashSet::new();
    for b in &blocks {
        if b.id.is_empty() {
            anyhow::bail!("Bloque sin id");
        }
        if !seen.insert(b.id.as_str()) {
            anyhow::bail!("Id de bloque duplicado: {}", b.id);
        }
        if matches!(b.kind, BlockType::Image | BlockType::Pdf) && b.attachment_id.is_none() {
            anyhow::bail!("Bloque {} sin attachment_id", b.id);
        }
    }
    Ok(blocks)
}

pub fn to_json(blocks: &[Block]) -> String {
    serde_json::to_string(blocks).expect("serializar bloques")
}

/// Segmento de texto derivado de un bloque, con su contexto de encabezados.
#[derive(Clone, Debug, PartialEq)]
pub struct TextSegment {
    pub block_id: String,
    pub kind: BlockType,
    /// Texto tal como aparece en el texto plano (con prefijo de lista si procede).
    pub text: String,
    /// Encabezados vigentes (de mayor a menor nivel) en el punto del bloque.
    pub heading_path: Vec<String>,
    pub source_page_id: Option<String>,
}

/// Segmentos de texto en orden de documento. Omite bloques sin texto y adjuntos.
pub fn segments(blocks: &[Block]) -> Vec<TextSegment> {
    let mut out = Vec::new();
    let mut headings: [Option<String>; 3] = [None, None, None];
    // Contador de listas numeradas por nivel de sangría.
    let mut counters = [0u32; 4];
    for b in blocks {
        if b.kind != BlockType::Numbered {
            counters = [0; 4];
        }
        if !b.kind.has_text() {
            continue;
        }
        let text = b.text.trim_end();
        if let Some(level) = b.kind.heading_level() {
            headings[level - 1] = if text.trim().is_empty() { None } else { Some(text.trim().to_string()) };
            for h in headings.iter_mut().skip(level) {
                *h = None;
            }
        }
        if text.trim().is_empty() {
            continue;
        }
        let indent = (b.indent.min(3)) as usize;
        let pad = "  ".repeat(indent);
        let rendered = match b.kind {
            BlockType::Bullet => format!("{pad}• {text}"),
            BlockType::Numbered => {
                counters[indent] += 1;
                for c in counters.iter_mut().skip(indent + 1) {
                    *c = 0;
                }
                format!("{pad}{}. {text}", counters[indent])
            }
            BlockType::Todo => format!("{pad}{} {text}", if b.checked { "☑" } else { "☐" }),
            _ => text.to_string(),
        };
        let heading_path = if b.kind.is_heading() {
            headings.iter().take(b.kind.heading_level().unwrap() - 1).flatten().cloned().collect()
        } else {
            headings.iter().flatten().cloned().collect()
        };
        out.push(TextSegment {
            block_id: b.id.clone(),
            kind: b.kind,
            text: rendered,
            heading_path,
            source_page_id: b.source_page_id.clone(),
        });
    }
    out
}

/// Texto plano completo (un segmento por línea).
pub fn to_plain_text(blocks: &[Block]) -> String {
    segments(blocks).into_iter().map(|s| s.text).collect::<Vec<_>>().join("\n")
}

/// Ids de adjuntos referenciados por el cuerpo.
pub fn referenced_attachments(blocks: &[Block]) -> Vec<String> {
    blocks.iter().filter_map(|b| b.attachment_id.clone()).collect()
}

/// Título visible: el explícito o la primera línea no vacía del texto (máx. 80 caracteres).
pub fn display_title(title: &str, plain_text: &str) -> String {
    let t = title.trim();
    if !t.is_empty() {
        return t.to_string();
    }
    plain_text
        .lines()
        .map(|l| l.trim().trim_start_matches(['•', '☐', '☑']).trim())
        .find(|l| !l.is_empty())
        .map(|l| l.chars().take(80).collect())
        .unwrap_or_default()
}

/// Bloques para texto reconocido por OCR: párrafos separados por líneas en blanco;
/// las líneas que empiezan por viñeta se convierten en `bullet`.
pub fn blocks_from_ocr_text(text: &str, source_page_id: Option<&str>) -> Vec<Block> {
    let mut out = Vec::new();
    let mut para: Vec<&str> = Vec::new();
    let flush = |para: &mut Vec<&str>, out: &mut Vec<Block>| {
        if !para.is_empty() {
            let mut b = Block::new(BlockType::Paragraph, para.join("\n"));
            b.source_page_id = source_page_id.map(str::to_string);
            out.push(b);
            para.clear();
        }
    };
    for line in text.lines() {
        let l = line.trim();
        if l.is_empty() {
            flush(&mut para, &mut out);
            continue;
        }
        let bullet = l
            .strip_prefix("• ")
            .or_else(|| l.strip_prefix("- "))
            .or_else(|| l.strip_prefix("* "))
            .or_else(|| l.strip_prefix("· "));
        if let Some(rest) = bullet {
            flush(&mut para, &mut out);
            let mut b = Block::new(BlockType::Bullet, rest.trim());
            b.source_page_id = source_page_id.map(str::to_string);
            out.push(b);
        } else {
            para.push(l);
        }
    }
    flush(&mut para, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(kind: BlockType, text: &str) -> Block {
        Block::new(kind, text)
    }

    #[test]
    fn parses_contract_example_and_unknown_types() {
        let json = r#"[
          {"id":"1","type":"heading1","text":"Tema 1"},
          {"id":"2","type":"paragraph","text":"Hola"},
          {"id":"3","type":"todo","text":"Repasar","checked":true},
          {"id":"4","type":"image","attachment_id":"att"},
          {"id":"5","type":"callout_future","text":"x","color":"red"}
        ]"#;
        let blocks = parse(json).unwrap();
        assert_eq!(blocks.len(), 5);
        assert_eq!(blocks[4].kind, BlockType::Unknown);
        assert_eq!(referenced_attachments(&blocks), vec!["att".to_string()]);
    }

    #[test]
    fn rejects_duplicate_ids_and_missing_attachment() {
        assert!(parse(r#"[{"id":"1","type":"paragraph"},{"id":"1","type":"paragraph"}]"#).is_err());
        assert!(parse(r#"[{"id":"1","type":"image"}]"#).is_err());
        assert!(parse("").unwrap().is_empty());
    }

    #[test]
    fn plain_text_numbering_and_headings() {
        let blocks = vec![
            b(BlockType::Heading1, "Física"),
            b(BlockType::Heading2, "Cinemática"),
            b(BlockType::Numbered, "Posición"),
            b(BlockType::Numbered, "Velocidad"),
            b(BlockType::Paragraph, "Texto"),
            b(BlockType::Numbered, "Reinicia"),
            Block { checked: true, ..b(BlockType::Todo, "Hecho") },
        ];
        let segs = segments(&blocks);
        assert_eq!(segs[2].text, "1. Posición");
        assert_eq!(segs[3].text, "2. Velocidad");
        assert_eq!(segs[5].text, "1. Reinicia");
        assert_eq!(segs[6].text, "☑ Hecho");
        assert_eq!(segs[4].heading_path, vec!["Física".to_string(), "Cinemática".to_string()]);
        assert_eq!(segs[1].heading_path, vec!["Física".to_string()]);
        assert!(to_plain_text(&blocks).starts_with("Física\nCinemática\n1. Posición"));
    }

    #[test]
    fn display_title_falls_back_to_first_line() {
        assert_eq!(display_title("  ", "\n• Primera idea\nOtra"), "Primera idea");
        assert_eq!(display_title("Título", "x"), "Título");
        assert_eq!(display_title("", ""), "");
    }

    #[test]
    fn ocr_text_to_blocks() {
        let blocks = blocks_from_ocr_text("Linea uno\nlinea dos\n\n- punto\nFinal", Some("p1"));
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0].text, "Linea uno\nlinea dos");
        assert_eq!(blocks[1].kind, BlockType::Bullet);
        assert_eq!(blocks[2].source_page_id.as_deref(), Some("p1"));
    }
}
