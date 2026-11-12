//! Motor simulado y determinista (sin modelos): para tests rápidos del flujo completo.
//!
//! - Generador: por defecto responde según el prompt (JSON válido si hay gramática; `NO_CONSTA`
//!   si las fuentes contienen la marca `[[sin-datos]]`; si no, una respuesta que cita [1] y un
//!   número inexistente [99] para probar la validación). Se puede sustituir con `with_responder`.
//!   Emite el texto en trozos de 3 caracteres, con retardo opcional por trozo, y respeta la
//!   cancelación.
//! - Embeddings: bolsa de palabras con hashing en 256 dimensiones, normalizada L2 (palabras
//!   compartidas ⇒ coseno alto). Ignora el prefijo de instrucción de las consultas.

use super::{l2_normalize, CancelToken, Embedder, Engine, GenOutput, GenParams, GenStats, Generator, LoadOptions, StopReason};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub type Responder = Arc<dyn Fn(&str, &GenParams) -> String + Send + Sync>;

#[derive(Clone, Default)]
pub struct MockStats {
    pub generations: Arc<AtomicUsize>,
    pub embeddings: Arc<AtomicUsize>,
    pub generator_loads: Arc<AtomicUsize>,
    pub embedder_loads: Arc<AtomicUsize>,
    /// Último prompt recibido por el generador.
    pub last_prompt: Arc<parking_lot::Mutex<String>>,
    pub prompts: Arc<parking_lot::Mutex<Vec<String>>>,
}

#[derive(Clone)]
pub struct MockEngine {
    pub stats: MockStats,
    responder: Option<Responder>,
    delay_per_piece: Duration,
    n_ctx: u32,
}

impl Default for MockEngine {
    fn default() -> Self {
        MockEngine::new()
    }
}

impl MockEngine {
    pub fn new() -> MockEngine {
        MockEngine { stats: MockStats::default(), responder: None, delay_per_piece: Duration::ZERO, n_ctx: 8192 }
    }
    pub fn with_responder(mut self, r: impl Fn(&str, &GenParams) -> String + Send + Sync + 'static) -> MockEngine {
        self.responder = Some(Arc::new(r));
        self
    }
    pub fn with_delay(mut self, d: Duration) -> MockEngine {
        self.delay_per_piece = d;
        self
    }
    pub fn with_n_ctx(mut self, n: u32) -> MockEngine {
        self.n_ctx = n;
        self
    }
}

impl Engine for MockEngine {
    fn name(&self) -> &'static str {
        "mock"
    }
    fn load_generator(&self, path: &Path, opts: &LoadOptions) -> anyhow::Result<Box<dyn Generator>> {
        anyhow::ensure!(path.exists(), "No se encuentra el modelo {}", path.display());
        self.stats.generator_loads.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(MockGenerator { engine: self.clone(), n_ctx: opts.n_ctx.min(self.n_ctx) }))
    }
    fn load_embedder(&self, path: &Path, _opts: &LoadOptions) -> anyhow::Result<Box<dyn Embedder>> {
        anyhow::ensure!(path.exists(), "No se encuentra el modelo {}", path.display());
        self.stats.embedder_loads.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(MockEmbedder { stats: self.stats.clone() }))
    }
}

struct MockGenerator {
    engine: MockEngine,
    n_ctx: u32,
}

/// Estimación determinista: 1 token cada 4 caracteres.
pub fn mock_count_tokens(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

impl Generator for MockGenerator {
    fn n_ctx(&self) -> u32 {
        self.n_ctx
    }
    fn count_tokens(&self, text: &str) -> usize {
        mock_count_tokens(text)
    }
    fn generate(
        &mut self,
        prompt: &str,
        params: &GenParams,
        cancel: &CancelToken,
        on_text: &mut dyn FnMut(&str),
    ) -> anyhow::Result<GenOutput> {
        let stats = &self.engine.stats;
        stats.generations.fetch_add(1, Ordering::SeqCst);
        *stats.last_prompt.lock() = prompt.to_string();
        stats.prompts.lock().push(prompt.to_string());
        let prompt_tokens = mock_count_tokens(prompt);
        anyhow::ensure!(
            prompt_tokens < self.n_ctx as usize,
            "El prompt ({prompt_tokens} tokens) no cabe en el contexto ({})",
            self.n_ctx
        );
        let full = match &self.engine.responder {
            Some(r) => r(prompt, params),
            None => default_response(prompt, params),
        };
        let started = Instant::now();
        let chars: Vec<char> = full.chars().collect();
        let mut out = String::new();
        let max_chars = params.max_tokens as usize * 4;
        let mut stop = StopReason::Eos;
        for piece in chars.chunks(3) {
            if cancel.is_cancelled() {
                stop = StopReason::Cancelled;
                break;
            }
            if out.chars().count() >= max_chars {
                stop = StopReason::MaxTokens;
                break;
            }
            if !self.engine.delay_per_piece.is_zero() {
                std::thread::sleep(self.engine.delay_per_piece);
            }
            let s: String = piece.iter().collect();
            on_text(&s);
            out.push_str(&s);
        }
        Ok(GenOutput {
            stats: GenStats {
                prompt_tokens,
                generated_tokens: mock_count_tokens(&out),
                prefill: Duration::ZERO,
                decode: started.elapsed(),
            },
            text: out,
            stop,
        })
    }
}

/// Respuesta por defecto según el tipo de tarea (detectado por la gramática o el prompt).
pub fn default_response(prompt: &str, params: &GenParams) -> String {
    if let Some(g) = &params.grammar {
        if g.contains("\\\"cards\\\"") {
            return r#"{"cards":[{"front":"¿Qué es la velocidad?","back":"La variación de la posición con el tiempo [1].","citations":[1]},{"front":"¿Unidad de la aceleración?","back":"Metros por segundo al cuadrado [2] [99].","citations":[2,99]}]}"#.into();
        }
        if g.contains("\\\"questions\\\"") {
            return r#"{"questions":[{"kind":"mcq","question":"¿Qué mide la velocidad?","options":["La masa","El cambio de posición","La temperatura","La carga"],"answer_index":1,"explanation":"Es el cambio de posición por unidad de tiempo [1].","citations":[1]},{"kind":"open","question":"Explica qué es la aceleración.","reference_answer":"El cambio de velocidad por unidad de tiempo.","explanation":"Ver [2].","citations":[2,42]}]}"#.into();
        }
        if g.contains("\\\"score\\\"") {
            return r#"{"score":0.75,"correct":true,"feedback":"Correcto en lo esencial; falta mencionar las unidades."}"#.into();
        }
        return "{}".into();
    }
    if prompt.contains("[[sin-datos]]") {
        return "NO_CONSTA".into();
    }
    if prompt.contains("Resume los puntos clave de este grupo") || prompt.contains("Extrae los puntos clave") {
        return "<think>\n\n</think>\n\n- Punto clave del grupo [1].\n- Otro punto [2].".into();
    }
    "<think>\nrazonamiento oculto\n</think>\n\nSegún tus notas, la velocidad es el cambio de posición [1]. Dato inventado [99].".into()
}

struct MockEmbedder {
    stats: MockStats,
}

pub const MOCK_DIM: usize = 256;

impl Embedder for MockEmbedder {
    fn dim(&self) -> usize {
        MOCK_DIM
    }
    fn embed(&mut self, text: &str) -> anyhow::Result<Vec<f32>> {
        self.stats.embeddings.fetch_add(1, Ordering::SeqCst);
        Ok(mock_embedding(text))
    }
}

/// Bolsa de palabras (minúsculas, ≥ 3 letras) con hashing FNV-1a en `MOCK_DIM` dimensiones.
pub fn mock_embedding(text: &str) -> Vec<f32> {
    let body = match text.rfind("Query:") {
        Some(i) => &text[i + "Query:".len()..],
        None => text,
    };
    let mut v = vec![0f32; MOCK_DIM];
    for w in body.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() >= 3) {
        let w = w.to_lowercase();
        let mut h: u64 = 0xcbf29ce484222325;
        for b in w.as_bytes() {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        v[(h % MOCK_DIM as u64) as usize] += 1.0;
    }
    l2_normalize(&mut v);
    v
}
