//! Búsqueda dentro de un texto sin distinguir mayúsculas ni diacríticos, con offsets UTF-16
//! (compatibles con `String` de Dart) referidos al texto ORIGINAL.

use crate::model::TextMatch;
use unicode_normalization::char::{decompose_canonical, is_combining_mark};

/// Texto plegado (NFD sin marcas combinantes, en minúsculas) y, por cada carácter plegado,
/// el rango UTF-16 [inicio, fin) del carácter original del que procede.
fn fold_with_map(text: &str) -> (Vec<char>, Vec<(u32, u32)>) {
    let mut chars = Vec::with_capacity(text.len());
    let mut spans = Vec::with_capacity(text.len());
    let mut pos: u32 = 0;
    for c in text.chars() {
        let len = c.len_utf16() as u32;
        let span = (pos, pos + len);
        let before = chars.len();
        decompose_canonical(c, |d| {
            if is_combining_mark(d) {
                return;
            }
            for l in d.to_lowercase() {
                if !is_combining_mark(l) {
                    chars.push(l);
                    spans.push(span);
                }
            }
        });
        if chars.len() == before {
            // Marca combinante suelta (p. ej. «e» + U+0301): se adjunta al carácter anterior
            // para que el resaltado cubra la letra completa.
            if let Some(last) = spans.last_mut() {
                last.1 = pos + len;
            }
        }
        pos += len;
    }
    (chars, spans)
}

/// Clave plegada (sin mayúsculas ni diacríticos), útil para ordenar y comparar nombres.
pub fn fold(s: &str) -> String {
    fold_with_map(s).0.into_iter().collect()
}

/// Todas las coincidencias no solapadas de `query` en `text`, sin distinguir mayúsculas ni
/// diacríticos. Offsets en unidades UTF-16 del texto original. Consulta vacía → sin resultados.
pub fn find_in_text(text: &str, query: &str) -> Vec<TextMatch> {
    if query.trim().is_empty() || text.is_empty() {
        return Vec::new();
    }
    let (needle, _) = fold_with_map(query);
    if needle.is_empty() || needle.iter().all(|c| c.is_whitespace()) {
        return Vec::new();
    }
    let (hay, spans) = fold_with_map(text);
    let m = needle.len();
    let mut out = Vec::new();
    if hay.len() < m {
        return out;
    }
    let first = needle[0];
    let mut i = 0;
    let mut last_end: u32 = 0;
    while i + m <= hay.len() {
        if hay[i] == first && hay[i..i + m] == needle[..] {
            let start = spans[i].0;
            let end = spans[i + m - 1].1;
            // Varios caracteres plegados pueden proceder del mismo original: evita solapes.
            if start >= last_end {
                out.push(TextMatch { start, end });
                last_end = end;
            }
            i += m;
        } else {
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slices(text: &str, ms: &[TextMatch]) -> Vec<String> {
        let units: Vec<u16> = text.encode_utf16().collect();
        ms.iter()
            .map(|m| String::from_utf16(&units[m.start as usize..m.end as usize]).unwrap())
            .collect()
    }

    #[test]
    fn ignores_case_and_diacritics() {
        let t = "La Energía cinética y la ENERGIA potencial";
        let ms = find_in_text(t, "energia");
        assert_eq!(slices(t, &ms), vec!["Energía", "ENERGIA"]);
        let ms = find_in_text(t, "CINÉTICA");
        assert_eq!(slices(t, &ms), vec!["cinética"]);
        assert!(find_in_text(t, "   ").is_empty());
        assert!(find_in_text(t, "").is_empty());
        assert!(find_in_text("", "a").is_empty());
    }

    #[test]
    fn offsets_are_utf16_with_emoji_and_decomposed_input() {
        // 😀 ocupa 2 unidades UTF-16; «é» descompuesta (e + U+0301) ocupa 2 unidades.
        let t = "😀 Café y cafe\u{301} 👩‍🔬 Ñandú";
        let ms = find_in_text(t, "cafe");
        assert_eq!(ms.len(), 2);
        assert_eq!(ms[0], TextMatch { start: 3, end: 7 });
        assert_eq!(slices(t, &ms), vec!["Café", "cafe\u{301}"]);
        let ms = find_in_text(t, "nandu");
        assert_eq!(slices(t, &ms), vec!["Ñandú"]);
        let units: Vec<u16> = t.encode_utf16().collect();
        assert_eq!(ms[0].end as usize, units.len());
        // Coincidencia con emoji en la propia consulta.
        let ms = find_in_text(t, "😀 caf");
        assert_eq!(ms, vec![TextMatch { start: 0, end: 6 }]);
    }

    #[test]
    fn non_overlapping_matches() {
        let ms = find_in_text("aaaa", "aa");
        assert_eq!(ms, vec![TextMatch { start: 0, end: 2 }, TextMatch { start: 2, end: 4 }]);
        let ms = find_in_text("ana ana", "ana");
        assert_eq!(ms.len(), 2);
    }

    #[test]
    fn fold_key() {
        assert_eq!(fold("Álgebra"), "algebra");
        assert_eq!(fold("ÑU"), "nu");
    }
}
