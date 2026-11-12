//! Prompts ChatML (construidos a mano, sin depender de la plantilla del GGUF), gramáticas GBNF
//! para salidas JSON y validación/normalización del contenido generado.

use crate::index::Hit;
use crate::text::{finalize_answer, strip_think, validate_citations};
use crate::types::*;
use serde_json::{json, Value};
use std::collections::BTreeSet;

const ASK_SYSTEM: &str = "Eres Folio, un asistente de estudio. Respondes ÚNICAMENTE con la información de las FUENTES numeradas que te da el usuario.\nReglas:\n1. Cita cada afirmación con el número de su fuente entre corchetes, por ejemplo [1] o [2][3].\n2. No uses conocimientos externos ni inventes datos.\n3. Si las fuentes no contienen la información necesaria, responde exactamente NO_CONSTA y nada más.\n4. Responde en el idioma de la pregunta, de forma clara y concisa.";

const STUDY_SYSTEM: &str = "Eres Folio, un asistente de estudio. Trabajas ÚNICAMENTE con las FUENTES numeradas que te da el usuario.\nReglas:\n1. Cita con el número de la fuente entre corchetes, por ejemplo [1] o [2][3].\n2. No inventes datos ni uses conocimientos externos.\n3. Escribe en el idioma de las fuentes.";

/// Prefijo del turno del asistente con el bloque de razonamiento vacío (modo sin razonamiento).
const ASSISTANT_OPEN: &str = "<|im_start|>assistant\n<think>\n\n</think>\n\n";

fn clean(s: &str) -> String {
    // Los marcadores ChatML dentro del contenido del usuario se neutralizan.
    s.replace("<|im_start|>", "").replace("<|im_end|>", "")
}

pub fn chatml(system: &str, turns: &[(&str, String)]) -> String {
    let mut p = format!("<|im_start|>system\n{system}<|im_end|>\n");
    for (role, text) in turns {
        p.push_str(&format!("<|im_start|>{role}\n{}<|im_end|>\n", clean(text)));
    }
    p.push_str(ASSISTANT_OPEN);
    p
}

/// Bloque de una fuente numerada: cabecera con título/ubicación/página y el texto.
pub fn source_block(n: u32, h: &Hit, location: &[String]) -> String {
    let mut head = format!("[{n}] «{}»", h.note_title);
    if !location.is_empty() {
        head.push_str(&format!(" — {}", location.join(" › ")));
    }
    if let Some(name) = &h.attachment_name {
        head.push_str(&format!(" · {name}"));
        if let Some(p) = h.page_index {
            head.push_str(&format!(", página {}", p + 1));
        }
    }
    if let Some(hd) = h.heading.as_deref().filter(|s| !s.is_empty()) {
        head.push_str(&format!(" · {hd}"));
    }
    format!("{head}\n{}", h.text.trim())
}

/// Últimos turnos de la conversación (acotados) para dar continuidad.
pub fn history_turns(history: &[ChatMessage]) -> Vec<(&'static str, String)> {
    let ok: Vec<&ChatMessage> = history.iter().filter(|m| m.status == "done" && !m.content.trim().is_empty()).collect();
    ok.iter()
        .skip(ok.len().saturating_sub(4))
        .map(|m| {
            let role = if m.role == ChatRole::User { "user" } else { "assistant" };
            (role, crate::text::snippet(&m.content, 500))
        })
        .collect()
}

pub fn ask_prompt(sources: &[String], history: &[(&'static str, String)], question: &str) -> String {
    let mut turns: Vec<(&str, String)> = history.iter().map(|(r, t)| (*r, t.clone())).collect();
    turns.push((
        "user",
        format!(
            "FUENTES:\n{}\n\nPREGUNTA: {}\n\nResponde solo con lo que dicen las fuentes y termina cada frase con el número de la fuente que la respalda entre corchetes, así: «La Tierra gira alrededor del Sol [1].» Si las fuentes no lo dicen, responde NO_CONSTA.",
            sources.join("\n\n"),
            question.trim()
        ),
    ));
    chatml(ASK_SYSTEM, &turns)
}

pub fn map_prompt(sources: &str) -> String {
    chatml(
        STUDY_SYSTEM,
        &[("user", format!("FUENTES:\n{sources}\n\nResume los puntos clave de este grupo de fuentes en viñetas breves. Conserva en cada viñeta la cita [n] de la fuente de la que procede."))],
    )
}

pub fn writing_message(kind: StudyKind) -> &'static str {
    match kind {
        StudyKind::Summary => "Escribiendo el resumen…",
        StudyKind::Outline => "Elaborando el esquema…",
        StudyKind::KeyConcepts => "Extrayendo los conceptos clave…",
        StudyKind::Flashcards => "Creando las flashcards…",
        StudyKind::Quiz => "Preparando el cuestionario…",
    }
}

pub fn max_tokens(kind: StudyKind, detail: DetailLevel, count: usize) -> u32 {
    match kind {
        StudyKind::Summary if detail == DetailLevel::Brief => 400,
        StudyKind::Summary => 1100,
        StudyKind::Outline => 900,
        StudyKind::KeyConcepts => 900,
        StudyKind::Flashcards => (count as u32 * 90 + 150).min(3000),
        StudyKind::Quiz => (count as u32 * 170 + 150).min(3600),
    }
}

pub fn study_prompt(kind: StudyKind, options: &StudyOptions, count: usize, material: &str) -> String {
    let task = match kind {
        StudyKind::Summary if options.detail == DetailLevel::Brief => {
            "Escribe un resumen BREVE (un párrafo corto o 4–6 viñetas) con las ideas principales, en Markdown, citando las fuentes.".to_string()
        }
        StudyKind::Summary => "Escribe un resumen DETALLADO y bien organizado en Markdown, con encabezados (##) por tema y viñetas, que cubra todos los contenidos importantes y cite las fuentes.".to_string(),
        StudyKind::Outline => "Elabora un ESQUEMA jerárquico en Markdown (encabezados ## y viñetas anidadas) con la estructura de los contenidos, citando las fuentes.".to_string(),
        StudyKind::KeyConcepts => "Enumera los CONCEPTOS CLAVE en una lista Markdown con el formato «- **Concepto**: definición breve [n]».".to_string(),
        StudyKind::Flashcards => format!(
            "Crea exactamente {count} flashcards de estudio en JSON: {{\"cards\":[{{\"front\":\"pregunta\",\"back\":\"respuesta breve con cita [n]\",\"citations\":[n]}}]}}. Cada pregunta debe poder responderse solo con las fuentes; no repitas preguntas."
        ),
        StudyKind::Quiz => {
            let mix = match options.quiz_mix {
                QuizMix::MultipleChoice => "todas de opción múltiple (kind \"mcq\") con 4 opciones y una sola correcta",
                QuizMix::OpenEnded => "todas de respuesta abierta (kind \"open\") con una respuesta de referencia",
                QuizMix::Mixed => "mezclando opción múltiple (kind \"mcq\", 4 opciones, una correcta) y respuesta abierta (kind \"open\", con respuesta de referencia)",
            };
            format!(
                "Crea un cuestionario de exactamente {count} preguntas en JSON, {mix}. En \"explanation\" justifica la respuesta correcta citando la fuente [n]. \"answer_index\" es el índice (0–3) de la opción correcta; varía su posición."
            )
        }
    };
    chatml(
        STUDY_SYSTEM,
        &[("user", format!("FUENTES:\n{material}\n\n{task}\nRecuerda indicar la fuente de cada dato con su número entre corchetes, por ejemplo [1]."))],
    )
}

// ─────────────────────────── Gramáticas ───────────────────────────

const GBNF_COMMON: &str = r#"
string ::= "\"" ( [^"\\\n\r] | "\\" ( ["\\/nt] ) )* "\""
intarr ::= "[" ws ( int ( ws "," ws int )* )? ws "]"
int ::= [0-9] [0-9]? [0-9]?
ws ::= [ \n]?
"#;

pub const GRADE_GRAMMAR: &str = r#"root ::= "{" ws "\"score\"" ws ":" ws score ws "," ws "\"correct\"" ws ":" ws ( "true" | "false" ) ws "," ws "\"feedback\"" ws ":" ws string ws "}"
score ::= "1" | "1.0" | "0" ( "." [0-9] [0-9]? )?
string ::= "\"" ( [^"\\\n\r] | "\\" ( ["\\/nt] ) )* "\""
ws ::= [ \n]?
"#;

pub fn grammar(kind: StudyKind, mix: QuizMix) -> Option<String> {
    match kind {
        StudyKind::Flashcards => Some(format!(
            r#"root ::= "{{" ws "\"cards\"" ws ":" ws "[" ws card ( ws "," ws card )* ws "]" ws "}}"
card ::= "{{" ws "\"front\"" ws ":" ws string ws "," ws "\"back\"" ws ":" ws string ws "," ws "\"citations\"" ws ":" ws intarr ws "}}"{GBNF_COMMON}"#
        )),
        StudyKind::Quiz => {
            let q = match mix {
                QuizMix::MultipleChoice => "mcq",
                QuizMix::OpenEnded => "open",
                QuizMix::Mixed => "mcq | open",
            };
            Some(format!(
                r#"root ::= "{{" ws "\"questions\"" ws ":" ws "[" ws question ( ws "," ws question )* ws "]" ws "}}"
question ::= {q}
mcq ::= "{{" ws "\"kind\"" ws ":" ws "\"mcq\"" ws "," ws "\"question\"" ws ":" ws string ws "," ws "\"options\"" ws ":" ws "[" ws string ws "," ws string ws "," ws string ws "," ws string ws "]" ws "," ws "\"answer_index\"" ws ":" ws [0-3] ws "," ws "\"explanation\"" ws ":" ws string ws "," ws "\"citations\"" ws ":" ws intarr ws "}}"
open ::= "{{" ws "\"kind\"" ws ":" ws "\"open\"" ws "," ws "\"question\"" ws ":" ws string ws "," ws "\"reference_answer\"" ws ":" ws string ws "," ws "\"explanation\"" ws ":" ws string ws "," ws "\"citations\"" ws ":" ws intarr ws "}}"{GBNF_COMMON}"#
            ))
        }
        _ => None,
    }
}

// ─────────────────────────── Post-procesado ───────────────────────────

/// Interpreta JSON generado; si quedó truncado (límite de tokens), recorta hasta el último objeto
/// completo y cierra la lista.
pub fn parse_json_lenient(raw: &str) -> anyhow::Result<Value> {
    let s = strip_think(raw);
    let start = s.find('{').ok_or_else(|| anyhow::anyhow!("El modelo no devolvió un resultado válido. Inténtalo de nuevo."))?;
    let s = &s[start..];
    if let Ok(v) = serde_json::from_str::<Value>(s) {
        return Ok(v);
    }
    if let Some(end) = s.rfind('}') {
        if let Ok(v) = serde_json::from_str::<Value>(&s[..=end]) {
            return Ok(v);
        }
    }
    let ends: Vec<usize> = s.match_indices('}').map(|(i, _)| i).collect();
    for &i in ends.iter().rev() {
        let candidate = format!("{}]}}", &s[..=i]);
        if let Ok(v) = serde_json::from_str::<Value>(&candidate) {
            return Ok(v);
        }
    }
    anyhow::bail!("El modelo no devolvió un resultado válido. Inténtalo de nuevo.")
}

fn text_field(v: &Value, key: &str) -> String {
    v.get(key).and_then(|x| x.as_str()).unwrap_or("").trim().to_string()
}

/// Valida las citas de un texto y de la lista declarada; devuelve (texto limpio, citas usadas).
fn clean_cited(text: &str, declared: Option<&Value>, allowed: &BTreeSet<u32>) -> (String, Vec<u32>) {
    let (t, mut used) = validate_citations(text, &|n| allowed.contains(&n));
    if let Some(arr) = declared.and_then(|d| d.as_array()) {
        for n in arr.iter().filter_map(|x| x.as_u64()).map(|x| x as u32) {
            if allowed.contains(&n) && !used.contains(&n) {
                used.push(n);
            }
        }
    }
    (crate::text::tidy(&t), used)
}

/// Construye el contenido (docs/CONTRATOS.md §3) a partir de la salida cruda.
/// Devuelve (contenido sin `citations`, números de cita usados, texto para el evento Done).
pub fn build_content(
    kind: StudyKind,
    options: &StudyOptions,
    count: usize,
    raw: &str,
    allowed: &BTreeSet<u32>,
) -> anyhow::Result<(Value, BTreeSet<u32>, String)> {
    let mut all: BTreeSet<u32> = BTreeSet::new();
    match kind {
        StudyKind::Summary | StudyKind::Outline | StudyKind::KeyConcepts => {
            let fin = finalize_answer(raw, &|n| allowed.contains(&n));
            anyhow::ensure!(!fin.insufficient, "Las fuentes seleccionadas no contienen información suficiente.");
            all.extend(fin.used.iter().copied());
            let content = json!({"format": "markdown", "text": fin.text, "detail": options.detail.as_str()});
            Ok((content, all, fin.text))
        }
        StudyKind::Flashcards => {
            let v = parse_json_lenient(raw)?;
            let mut cards = Vec::new();
            for c in v.get("cards").and_then(|c| c.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
                let front = crate::text::tidy(&validate_citations(&text_field(c, "front"), &|_| false).0);
                let (back, used) = clean_cited(&text_field(c, "back"), c.get("citations"), allowed);
                if front.is_empty() || back.is_empty() || cards.iter().any(|x: &Value| x["front"] == front.as_str()) {
                    continue;
                }
                all.extend(used.iter().copied());
                cards.push(json!({"id": format!("c{}", cards.len() + 1), "front": front, "back": back, "citations": used}));
                if cards.len() >= count {
                    break;
                }
            }
            anyhow::ensure!(!cards.is_empty(), "No se pudieron crear flashcards con estas fuentes. Inténtalo de nuevo.");
            let n = cards.len();
            Ok((json!({"cards": cards}), all, format!("{n} flashcards")))
        }
        StudyKind::Quiz => {
            let v = parse_json_lenient(raw)?;
            let mut qs: Vec<Value> = Vec::new();
            for q in v.get("questions").and_then(|c| c.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
                let question = crate::text::tidy(&validate_citations(&text_field(q, "question"), &|_| false).0);
                if question.is_empty() {
                    continue;
                }
                let (explanation, used) = clean_cited(&text_field(q, "explanation"), q.get("citations"), allowed);
                let id = format!("q{}", qs.len() + 1);
                let item = match q.get("kind").and_then(|k| k.as_str()) {
                    Some("mcq") => {
                        let options: Vec<String> = q
                            .get("options")
                            .and_then(|o| o.as_array())
                            .map(|o| o.iter().filter_map(|x| x.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
                            .unwrap_or_default();
                        let idx = q.get("answer_index").and_then(|i| i.as_u64()).unwrap_or(u64::MAX) as usize;
                        if options.len() < 2 || idx >= options.len() {
                            continue;
                        }
                        json!({"id": id, "kind": "mcq", "question": question, "options": options, "answer_index": idx, "explanation": explanation, "citations": used})
                    }
                    Some("open") => {
                        let reference = crate::text::tidy(&validate_citations(&text_field(q, "reference_answer"), &|n| allowed.contains(&n)).0);
                        if reference.is_empty() {
                            continue;
                        }
                        json!({"id": id, "kind": "open", "question": question, "reference_answer": reference, "explanation": explanation, "citations": used})
                    }
                    _ => continue,
                };
                all.extend(used.iter().copied());
                qs.push(item);
                if qs.len() >= count {
                    break;
                }
            }
            anyhow::ensure!(!qs.is_empty(), "No se pudo crear el cuestionario con estas fuentes. Inténtalo de nuevo.");
            let n = qs.len();
            Ok((json!({"questions": qs}), all, format!("{n} preguntas")))
        }
    }
}

pub fn grade_prompt(question: &Value, response: &str) -> String {
    let system = "Eres un profesor que corrige respuestas abiertas de forma justa y breve. Compara la respuesta del estudiante con la respuesta de referencia. Devuelve JSON: {\"score\": número entre 0 y 1, \"correct\": true si score >= 0.6, \"feedback\": explicación breve en el idioma de la pregunta, indicando qué falta o qué es incorrecto}.";
    let user = format!(
        "PREGUNTA: {}\nRESPUESTA DE REFERENCIA: {}\nEXPLICACIÓN: {}\n\nRESPUESTA DEL ESTUDIANTE: {}",
        text_field(question, "question"),
        text_field(question, "reference_answer"),
        text_field(question, "explanation"),
        response.trim()
    );
    chatml(system, &[("user", user)])
}

pub fn parse_grade(raw: &str) -> anyhow::Result<Value> {
    let v = parse_json_lenient(raw)?;
    let score = v.get("score").and_then(|s| s.as_f64()).unwrap_or(0.0).clamp(0.0, 1.0);
    let feedback = text_field(&v, "feedback");
    Ok(json!({"score": score, "correct": score >= 0.6, "feedback": feedback}))
}
