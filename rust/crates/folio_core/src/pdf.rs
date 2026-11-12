//! Capa de texto de PDFs con `pdf-extract` (sobre lopdf). Cada página se procesa aislada con
//! `catch_unwind`: un PDF raro nunca tumba la app; en el peor caso la página queda sin texto y
//! se marca como candidata a OCR (render nativo + Vision / ML Kit).

use anyhow::bail;
use pdf_extract::{Document, PlainTextOutput};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::{Duration, Instant};

/// Caracteres no blancos mínimos para considerar que una página tiene capa de texto útil.
pub const MIN_TEXT_CHARS: usize = 25;

/// Tiempo máximo total de extracción; las páginas restantes quedan para OCR.
pub const EXTRACTION_BUDGET: Duration = Duration::from_secs(90);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PdfText {
    /// Texto limpio por página (vacío si no hay capa de texto o falló la extracción).
    pub pages: Vec<String>,
}

impl PdfText {
    pub fn page_count(&self) -> u32 {
        self.pages.len() as u32
    }
}

/// true si el texto tiene menos de `MIN_TEXT_CHARS` caracteres no blancos.
pub fn needs_ocr(text: &str) -> bool {
    text.chars().filter(|c| !c.is_whitespace()).take(MIN_TEXT_CHARS).count() < MIN_TEXT_CHARS
}

/// Comprueba la cabecera `%PDF-` (en los primeros 1024 bytes, como hacen los lectores).
pub fn looks_like_pdf(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(1024)];
    head.windows(5).any(|w| w == b"%PDF-")
}

/// Limpia la salida de pdf-extract: sin caracteres de control, sin espacios finales,
/// como mucho una línea en blanco seguida.
pub fn clean_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut blank_run = 0;
    for line in raw.replace("\r\n", "\n").replace('\r', "\n").split('\n') {
        let line: String = line
            .chars()
            .map(|c| if c == '\t' || c == '\u{a0}' { ' ' } else { c })
            .filter(|c| !c.is_control() && *c != '\u{fffd}')
            .collect();
        let line = line.trim_end();
        if line.trim().is_empty() {
            blank_run += 1;
            if blank_run > 1 || out.is_empty() {
                continue;
            }
            out.push('\n');
            continue;
        }
        blank_run = 0;
        out.push_str(line);
        out.push('\n');
    }
    out.trim().to_string()
}

/// Recuento aproximado de páginas cuando lopdf no puede cargar el documento:
/// cuenta objetos `/Type /Page` (no `/Pages`).
fn heuristic_page_count(bytes: &[u8]) -> u32 {
    let mut count = 0;
    let mut i = 0;
    while let Some(pos) = find(&bytes[i..], b"/Type") {
        let mut j = i + pos + 5;
        while j < bytes.len() && (bytes[j] as char).is_ascii_whitespace() {
            j += 1;
        }
        if bytes[j..].starts_with(b"/Page") {
            let after = bytes.get(j + 5).copied().unwrap_or(b' ');
            if !after.is_ascii_alphanumeric() {
                count += 1;
            }
        }
        i = j.max(i + pos + 1);
    }
    count
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn extract_page(doc: &Document, page_num: u32) -> Option<String> {
    let res = catch_unwind(AssertUnwindSafe(|| {
        let mut s = String::new();
        {
            let mut out = PlainTextOutput::new(&mut s);
            pdf_extract::output_doc_page(doc, &mut out, page_num).ok()?;
        }
        Some(s)
    }));
    match res {
        Ok(Some(s)) => Some(clean_text(&s)),
        Ok(None) => None,
        Err(_) => {
            log::warn!("pdf-extract falló (panic) en la página {page_num}");
            None
        }
    }
}

/// Extrae el texto de cada página. Errores legibles si el PDF está protegido o es ilegible.
pub fn extract(bytes: &[u8]) -> anyhow::Result<PdfText> {
    extract_with_budget(bytes, EXTRACTION_BUDGET)
}

pub fn extract_with_budget(bytes: &[u8], budget: Duration) -> anyhow::Result<PdfText> {
    if !looks_like_pdf(bytes) {
        bail!("El fichero no es un PDF válido");
    }
    let started = Instant::now();
    let loaded = catch_unwind(AssertUnwindSafe(|| Document::load_mem(bytes)));
    let mut doc = match loaded {
        Ok(Ok(doc)) => doc,
        other => {
            if let Ok(Err(e)) = &other {
                log::warn!("lopdf no pudo cargar el PDF: {e}");
            }
            let n = heuristic_page_count(bytes);
            if n == 0 {
                bail!("No se pudo leer el PDF (archivo dañado o no compatible)");
            }
            // Sin capa de texto accesible: todas las páginas quedan para OCR.
            return Ok(PdfText { pages: vec![String::new(); n as usize] });
        }
    };
    if doc.is_encrypted() {
        let ok = catch_unwind(AssertUnwindSafe(|| doc.decrypt("").is_ok())).unwrap_or(false);
        if !ok {
            bail!("El PDF está protegido con contraseña");
        }
    }
    let page_numbers: Vec<u32> =
        catch_unwind(AssertUnwindSafe(|| doc.get_pages().keys().copied().collect()))
            .unwrap_or_default();
    if page_numbers.is_empty() {
        let n = heuristic_page_count(bytes);
        if n == 0 {
            bail!("El PDF no contiene páginas");
        }
        return Ok(PdfText { pages: vec![String::new(); n as usize] });
    }
    let mut pages = Vec::with_capacity(page_numbers.len());
    for num in page_numbers {
        if started.elapsed() > budget {
            pages.push(String::new());
            continue;
        }
        pages.push(extract_page(&doc, num).unwrap_or_default());
    }
    Ok(PdfText { pages })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use pdf_extract::content::{Content, Operation};
    use pdf_extract::{dictionary, Object, Stream};

    /// PDF de prueba: una página por elemento; `None` = página sin texto.
    pub(crate) fn make_pdf(pages: &[Option<&str>]) -> Vec<u8> {
        let mut doc = Document::with_version("1.5");
        let pages_id = doc.new_object_id();
        let font_id = doc.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
            "Encoding" => "WinAnsiEncoding",
        });
        let resources_id = doc.add_object(dictionary! {
            "Font" => dictionary! { "F1" => font_id },
        });
        let mut kids = Vec::new();
        for text in pages {
            let mut ops = Vec::new();
            if let Some(t) = text {
                ops.push(Operation::new("BT", vec![]));
                ops.push(Operation::new("Tf", vec!["F1".into(), 12.into()]));
                ops.push(Operation::new("Td", vec![72.into(), 720.into()]));
                ops.push(Operation::new("Tj", vec![Object::string_literal(*t)]));
                ops.push(Operation::new("ET", vec![]));
            }
            let content = Content { operations: ops };
            let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
            let page_id = doc.add_object(dictionary! {
                "Type" => "Page",
                "Parent" => pages_id,
                "Contents" => content_id,
            });
            kids.push(page_id.into());
        }
        let count = kids.len() as i64;
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => kids,
                "Count" => count,
                "Resources" => resources_id,
                "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
            }),
        );
        let catalog_id = doc.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        doc.trailer.set("Root", catalog_id);
        let mut buf = Vec::new();
        doc.save_to(&mut buf).unwrap();
        buf
    }

    #[test]
    fn extracts_text_per_page_and_flags_empty_pages() {
        let pdf = make_pdf(&[
            Some("La energia cinetica depende de la masa y de la velocidad"),
            None,
            Some("Corto"),
        ]);
        let t = extract(&pdf).unwrap();
        assert_eq!(t.page_count(), 3);
        assert!(t.pages[0].contains("energia cinetica"), "{:?}", t.pages[0]);
        assert!(!needs_ocr(&t.pages[0]));
        assert!(t.pages[1].is_empty());
        assert!(needs_ocr(&t.pages[1]));
        assert!(needs_ocr(&t.pages[2]));
    }

    #[test]
    fn rejects_non_pdf_and_survives_garbage() {
        assert!(extract(b"hola").is_err());
        // Cabecera válida y basura: no debe hacer panic.
        let mut junk = b"%PDF-1.4\n".to_vec();
        junk.extend(std::iter::repeat_n(b'x', 2000));
        assert!(extract(&junk).is_err());
        // Basura con objetos de página reconocibles → recuento heurístico, sin texto.
        let mut broken = b"%PDF-1.4\n1 0 obj << /Type /Page >> endobj 2 0 obj << /Type/Page >> endobj 3 0 obj << /Type /Pages >> endobj".to_vec();
        broken.extend_from_slice(b"\n%%EOF");
        let t = extract(&broken).unwrap();
        assert_eq!(t.page_count(), 2);
        assert!(t.pages.iter().all(|p| p.is_empty()));
    }

    #[test]
    fn cleans_text() {
        assert_eq!(clean_text("\n\n  a  \r\n\n\n\nb\t\x07c  \n"), "a\n\nb c");
        assert!(needs_ocr("  a b c "));
        assert!(!needs_ocr(&"x".repeat(25)));
    }
}
