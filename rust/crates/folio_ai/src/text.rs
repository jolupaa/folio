//! Post-procesado de la salida del modelo: eliminación de `<think>…</think>`, detección de
//! `NO_CONSTA`, validación/normalización de referencias `[n]` y filtro incremental para streaming.

use std::collections::{BTreeSet, HashMap};

/// Marca que el modelo debe responder cuando las fuentes no bastan.
pub const NO_CONSTA: &str = "NO_CONSTA";
/// Mensaje visible cuando no hay evidencia suficiente.
pub const INSUFFICIENT_MESSAGE: &str = "Las fuentes seleccionadas no contienen información suficiente para responder.";

const THINK_OPEN: &str = "<think>";
const THINK_CLOSE: &str = "</think>";

/// Quita los bloques de razonamiento. Un `<think>` sin cerrar elimina todo lo que sigue; un
/// `</think>` suelto elimina lo anterior.
pub fn strip_think(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    if let Some(close) = rest.find(THINK_CLOSE) {
        if rest[..close].find(THINK_OPEN).is_none() {
            rest = &rest[close + THINK_CLOSE.len()..];
        }
    }
    loop {
        match rest.find(THINK_OPEN) {
            Some(open) => {
                out.push_str(&rest[..open]);
                match rest[open..].find(THINK_CLOSE) {
                    Some(close) => rest = &rest[open + close + THINK_CLOSE.len()..],
                    None => break,
                }
            }
            None => {
                out.push_str(rest);
                break;
            }
        }
    }
    out.trim().to_string()
}

/// true si la respuesta (ya sin razonamiento) indica falta de información.
pub fn is_no_consta(answer: &str) -> bool {
    let t = answer.trim_start().trim_start_matches(['*', '_', '`', '"', '«']);
    t.starts_with(NO_CONSTA) || t.to_uppercase().starts_with("NO CONSTA")
}

/// Contenido de un corchete si parece una referencia: «1», «1, 2», «1-3», «1 y 2», «1; 4».
fn parse_citation_group(inner: &str) -> Option<Vec<u32>> {
    let t = inner.trim();
    if t.is_empty() || !t.starts_with(|c: char| c.is_ascii_digit()) {
        return None;
    }
    let mut out = Vec::new();
    let normalized = t.replace(" y ", ",").replace(" and ", ",").replace(';', ",");
    for part in normalized.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((a, b)) = part.split_once(['-', '–']) {
            let a: u32 = a.trim().parse().ok()?;
            let b: u32 = b.trim().parse().ok()?;
            if b < a || b - a > 20 {
                return None;
            }
            out.extend(a..=b);
        } else {
            out.push(part.parse().ok()?);
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Valida las referencias: conserva solo números aceptados por `allowed`, normaliza grupos
/// («[1, 2]» → «[1][2]») y elimina los corchetes sin números válidos. Devuelve el texto y los
/// números usados en orden de primera aparición (sin repetir).
pub fn validate_citations(text: &str, allowed: &dyn Fn(u32) -> bool) -> (String, Vec<u32>) {
    let mut out = String::with_capacity(text.len());
    let mut used: Vec<u32> = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let close = after.find(']').filter(|&c| c <= 40 && !after[..c].contains('\n'));
        match close.and_then(|c| parse_citation_group(&after[..c]).map(|nums| (c, nums))) {
            Some((c, nums)) => {
                let mut kept = Vec::new();
                for n in nums {
                    if allowed(n) && !kept.contains(&n) {
                        kept.push(n);
                    }
                }
                if kept.is_empty() {
                    // Quita también el espacio previo si lo siguiente es puntuación o fin.
                    let next = after[c + 1..].chars().next();
                    if out.ends_with(' ') && next.is_none_or(|ch| ch.is_whitespace() || ".,;:!?)".contains(ch)) {
                        out.pop();
                    }
                } else {
                    for n in kept {
                        out.push_str(&format!("[{n}]"));
                        if !used.contains(&n) {
                            used.push(n);
                        }
                    }
                }
                rest = &after[c + 1..];
            }
            None => {
                out.push('[');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    (out, used)
}

/// Sustituye `[n]` (ya normalizados) por `[map[n]]`; elimina los que no estén en el mapa.
pub fn renumber_citations(text: &str, map: &HashMap<u32, u32>) -> String {
    let (validated, _) = validate_citations(text, &|n| map.contains_key(&n));
    let mut out = String::with_capacity(validated.len());
    let mut rest = validated.as_str();
    while let Some(open) = rest.find('[') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find(']').and_then(|c| after[..c].parse::<u32>().ok().map(|n| (c, n))) {
            Some((c, n)) if map.contains_key(&n) => {
                out.push_str(&format!("[{}]", map[&n]));
                rest = &after[c + 1..];
            }
            _ => {
                out.push('[');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Resultado final de una respuesta generada.
#[derive(Debug, Clone, PartialEq)]
pub struct FinalAnswer {
    pub text: String,
    pub used: Vec<u32>,
    pub insufficient: bool,
}

/// Limpia la salida cruda: razonamiento, `NO_CONSTA` y referencias.
pub fn finalize_answer(raw: &str, allowed: &dyn Fn(u32) -> bool) -> FinalAnswer {
    let clean = strip_think(raw);
    if is_no_consta(&clean) || clean.is_empty() {
        return FinalAnswer { text: INSUFFICIENT_MESSAGE.into(), used: Vec::new(), insufficient: true };
    }
    // `NO_CONSTA` en mitad del texto: se elimina la marca y se conserva el resto.
    let clean = clean.replace(NO_CONSTA, "");
    let (text, used) = validate_citations(clean.trim(), allowed);
    let text = tidy(&text);
    if text.is_empty() {
        return FinalAnswer { text: INSUFFICIENT_MESSAGE.into(), used: Vec::new(), insufficient: true };
    }
    FinalAnswer { text, used, insufficient: false }
}

/// Espacios dobles y espacios antes de puntuación tras eliminar referencias.
pub fn tidy(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for line in s.split('\n') {
        let mut l = String::with_capacity(line.len());
        let mut prev_space = false;
        for ch in line.chars() {
            if ch == ' ' {
                if prev_space {
                    continue;
                }
                prev_space = true;
            } else {
                if prev_space && ".,;:!?".contains(ch) && !l.trim().is_empty() {
                    l.pop();
                }
                prev_space = false;
            }
            l.push(ch);
        }
        out.push_str(l.trim_end());
        out.push('\n');
    }
    out.trim().to_string()
}

/// Filtro incremental de la salida en streaming: oculta el razonamiento, retiene el inicio
/// mientras pueda ser `NO_CONSTA` y valida cada referencia `[n]` antes de emitirla.
pub struct StreamFilter {
    allowed: BTreeSet<u32>,
    pending: String,
    in_think: bool,
    started: bool,
    head: String,
    decided: bool,
    suppressed: bool,
    bracket: Option<String>,
}

impl StreamFilter {
    pub fn new(allowed: impl IntoIterator<Item = u32>) -> StreamFilter {
        StreamFilter {
            allowed: allowed.into_iter().collect(),
            pending: String::new(),
            in_think: false,
            started: false,
            head: String::new(),
            decided: false,
            suppressed: false,
            bracket: None,
        }
    }

    /// Añade un delta del modelo y devuelve el texto que ya se puede mostrar.
    pub fn push(&mut self, delta: &str) -> String {
        self.pending.push_str(delta);
        let visible = self.drain_think(false);
        self.visible(&visible)
    }

    /// Fin de la generación: vacía lo retenido.
    pub fn finish(&mut self) -> String {
        let visible = self.drain_think(true);
        let mut out = self.visible(&visible);
        if !self.decided {
            self.decided = true;
            let head = std::mem::take(&mut self.head);
            if is_no_consta(&head) {
                self.suppressed = true;
            } else {
                out.push_str(&self.citations(&head));
            }
        }
        if let Some(b) = self.bracket.take() {
            if !self.suppressed {
                out.push_str(&b);
            }
        }
        out
    }

    /// true si la salida empezó por `NO_CONSTA` (se suprime en el stream).
    pub fn insufficient(&self) -> bool {
        self.suppressed
    }

    fn drain_think(&mut self, eof: bool) -> String {
        let mut out = String::new();
        loop {
            if self.in_think {
                match self.pending.find(THINK_CLOSE) {
                    Some(i) => {
                        self.pending.drain(..i + THINK_CLOSE.len());
                        self.in_think = false;
                    }
                    None => {
                        // Conserva un posible `</think>` partido.
                        let keep = partial_suffix(&self.pending, THINK_CLOSE);
                        let cut = self.pending.len() - keep;
                        self.pending.drain(..cut);
                        if eof {
                            self.pending.clear();
                        }
                        return out;
                    }
                }
            } else {
                let open = self.pending.find(THINK_OPEN);
                let close = self.pending.find(THINK_CLOSE);
                match (open, close) {
                    (_, Some(c)) if open.is_none_or(|o| c < o) => {
                        // `</think>` suelto: lo anterior era razonamiento sin etiqueta de apertura.
                        if !self.started {
                            out.clear();
                        } else {
                            out.push_str(&self.pending[..c]);
                        }
                        self.pending.drain(..c + THINK_CLOSE.len());
                    }
                    (Some(o), _) => {
                        out.push_str(&self.pending[..o]);
                        self.pending.drain(..o + THINK_OPEN.len());
                        self.in_think = true;
                    }
                    _ => {
                        let keep = if eof {
                            0
                        } else {
                            partial_suffix(&self.pending, THINK_OPEN).max(partial_suffix(&self.pending, THINK_CLOSE))
                        };
                        let cut = self.pending.len() - keep;
                        out.push_str(&self.pending[..cut]);
                        self.pending.drain(..cut);
                        return out;
                    }
                }
            }
        }
    }

    fn visible(&mut self, s: &str) -> String {
        if self.suppressed {
            return String::new();
        }
        let mut s = s;
        if !self.started {
            s = s.trim_start();
            if s.is_empty() {
                return String::new();
            }
            self.started = true;
        }
        if !self.decided {
            self.head.push_str(s);
            let t = self.head.trim_start_matches(['*', '_', '`', '"', '«']);
            if is_no_consta(t) {
                self.decided = true;
                self.suppressed = true;
                return String::new();
            }
            let prefix_of_marker = NO_CONSTA.starts_with(t) || "NO CONSTA".starts_with(&t.to_uppercase());
            if prefix_of_marker {
                return String::new();
            }
            self.decided = true;
            let head = std::mem::take(&mut self.head);
            return self.citations(&head);
        }
        self.citations(s)
    }

    fn citations(&mut self, s: &str) -> String {
        let mut out = String::new();
        for ch in s.chars() {
            if let Some(b) = self.bracket.as_mut() {
                b.push(ch);
                if ch == ']' {
                    let b = self.bracket.take().expect("corchete abierto");
                    let allowed = &self.allowed;
                    let (v, _) = validate_citations(&b, &|n| allowed.contains(&n));
                    out.push_str(&v);
                } else if ch == '\n' || b.chars().count() > 40 {
                    out.push_str(&self.bracket.take().expect("corchete abierto"));
                }
            } else if ch == '[' {
                self.bracket = Some("[".into());
            } else {
                out.push(ch);
            }
        }
        out
    }
}

/// Longitud (bytes) del sufijo de `s` que es prefijo propio de `tag`.
fn partial_suffix(s: &str, tag: &str) -> usize {
    (1..tag.len()).rev().find(|&k| s.len() >= k && s.is_char_boundary(s.len() - k) && tag.starts_with(&s[s.len() - k..])).unwrap_or(0)
}

/// Palabras de contenido (≥ 4 letras, en minúsculas y sin tildes) para comparar textos.
fn content_words(s: &str) -> std::collections::HashSet<String> {
    s.split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.chars().count() >= 4)
        .map(|w| {
            w.to_lowercase()
                .chars()
                .map(|c| match c {
                    'á' => 'a',
                    'é' => 'e',
                    'í' => 'i',
                    'ó' => 'o',
                    'ú' | 'ü' => 'u',
                    other => other,
                })
                .collect()
        })
        .collect()
}

/// Atribución de respaldo cuando el modelo responde sin referencias: devuelve los números de las
/// fuentes (máx. 2) cuyo texto cubre al menos la mitad de las palabras de contenido de la respuesta.
pub fn infer_citations(answer: &str, sources: &[(u32, &str)]) -> Vec<u32> {
    let words = content_words(answer);
    if words.len() < 3 {
        return Vec::new();
    }
    let mut scored: Vec<(u32, f64)> = sources
        .iter()
        .map(|(n, text)| {
            let sw = content_words(text);
            (*n, words.iter().filter(|w| sw.contains(*w)).count() as f64 / words.len() as f64)
        })
        .filter(|(_, score)| *score >= 0.5)
        .collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    let mut out: Vec<u32> = scored.into_iter().take(2).map(|(n, _)| n).collect();
    out.sort_unstable();
    out
}

/// Recorta a `max` caracteres en límite de palabra, añadiendo «…».
pub fn snippet(text: &str, max: usize) -> String {
    let t = text.trim();
    if t.chars().count() <= max {
        return t.to_string();
    }
    let cut: String = t.chars().take(max - 1).collect();
    let cut = match cut.rfind(char::is_whitespace) {
        Some(i) if i > cut.len() / 2 => cut[..i].to_string(),
        _ => cut,
    };
    format!("{}…", cut.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn allow(set: &'static [u32]) -> impl Fn(u32) -> bool {
        move |n| set.contains(&n)
    }

    #[test]
    fn strips_think_blocks() {
        assert_eq!(strip_think("<think>\n\n</think>\n\nHola"), "Hola");
        assert_eq!(strip_think("A <think>x</think>B<think>y</think> C"), "A B C");
        assert_eq!(strip_think("Respuesta<think>sin cerrar"), "Respuesta");
        assert_eq!(strip_think("razono…</think>Final"), "Final");
        assert_eq!(strip_think("Sin etiquetas"), "Sin etiquetas");
    }

    #[test]
    fn validates_and_normalizes_citations() {
        let (t, used) = validate_citations("La velocidad [1]. Inventado [99]. Grupo [2, 3] y rango [1-2].", &allow(&[1, 2, 3]));
        assert_eq!(t, "La velocidad [1]. Inventado. Grupo [2][3] y rango [1][2].");
        assert_eq!(used, vec![1, 2, 3]);
        let (t, used) = validate_citations("Texto [nota] y [a] y [5 y 1]", &allow(&[1]));
        assert_eq!(t, "Texto [nota] y [a] y [1]");
        assert_eq!(used, vec![1]);
        let (t, _) = validate_citations("Fin [7]", &allow(&[]));
        assert_eq!(t, "Fin");
        let (t, _) = validate_citations("abre [ sin cerrar", &allow(&[1]));
        assert_eq!(t, "abre [ sin cerrar");
    }

    #[test]
    fn renumbers_compactly() {
        let map: HashMap<u32, u32> = [(7, 1), (3, 2)].into_iter().collect();
        assert_eq!(renumber_citations("a [7] b [3][7] c [9]", &map), "a [1] b [2][1] c");
    }

    #[test]
    fn finalize_detects_no_consta() {
        let f = finalize_answer("<think>\n\n</think>\n\nNO_CONSTA", &allow(&[1]));
        assert!(f.insufficient);
        assert_eq!(f.text, INSUFFICIENT_MESSAGE);
        let f = finalize_answer("**NO_CONSTA**.", &allow(&[1]));
        assert!(f.insufficient);
        let f = finalize_answer("La energía se conserva [1] [4].", &allow(&[1]));
        assert!(!f.insufficient);
        assert_eq!(f.text, "La energía se conserva [1].");
        assert_eq!(f.used, vec![1]);
    }

    #[test]
    fn stream_filter_hides_think_and_bad_citations() {
        let mut f = StreamFilter::new([1, 2]);
        let raw = "<think>\nrazono\n</think>\n\nLa velocidad [1] es [9] útil [2, 3].";
        let mut shown = String::new();
        let chars: Vec<char> = raw.chars().collect();
        for piece in chars.chunks(2) {
            shown.push_str(&f.push(&piece.iter().collect::<String>()));
        }
        shown.push_str(&f.finish());
        // El stream no reordena espacios; el texto final pasa por `tidy`.
        assert_eq!(tidy(&shown), "La velocidad [1] es útil [2].");
        assert!(!f.insufficient());
    }

    #[test]
    fn stream_filter_suppresses_no_consta() {
        let mut f = StreamFilter::new([1]);
        let mut shown = String::new();
        for p in ["<think>\n\n</think>\n\n", "NO", "_CON", "STA"] {
            shown.push_str(&f.push(p));
        }
        shown.push_str(&f.finish());
        assert_eq!(shown, "");
        assert!(f.insufficient());
        // Un texto que empieza por «NO» pero no es la marca se libera.
        let mut f = StreamFilter::new([1]);
        let mut shown = f.push("NO");
        shown.push_str(&f.push("rmalmente sí [1]"));
        shown.push_str(&f.finish());
        assert_eq!(shown, "NOrmalmente sí [1]");
    }

    #[test]
    fn infers_citations_by_overlap() {
        let sources = [
            (1, "La cinemática estudia el movimiento de los cuerpos."),
            (2, "Segunda ley: la fuerza neta es igual a la masa por la aceleración. La fuerza se mide en newtons."),
        ];
        let a = "La segunda ley establece que la fuerza neta es igual a la masa por la aceleración y se mide en newtons.";
        assert_eq!(infer_citations(a, &sources), vec![2]);
        assert!(infer_citations("La fotosíntesis ocurre en los cloroplastos de las plantas verdes.", &sources).is_empty());
        assert!(infer_citations("Sí.", &sources).is_empty());
    }

    #[test]
    fn snippet_cuts_on_words() {
        assert_eq!(snippet("corto", 300), "corto");
        let s = snippet(&"palabra ".repeat(100), 30);
        assert!(s.chars().count() <= 30 && s.ends_with('…'));
    }
}
