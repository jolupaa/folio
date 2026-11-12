//! Motores de inferencia: traits `Generator` / `Embedder`, implementación llama.cpp y motor
//! simulado determinista para tests.

pub mod mock;

#[cfg(feature = "llama")]
pub mod llama;

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Señal de cancelación compartida (comprobada entre lotes de prefill y en cada token).
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> CancelToken {
        CancelToken::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// Parámetros de muestreo de una generación.
#[derive(Clone, Debug, PartialEq)]
pub struct GenParams {
    pub max_tokens: u32,
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: i32,
    pub min_p: f32,
    /// Penalización de presencia (tokens ya vistos en la ventana), 0 = desactivada.
    pub presence_penalty: f32,
    /// Ventana de tokens recientes para la penalización.
    pub penalty_last_n: i32,
    /// Gramática GBNF (regla raíz `root`) para forzar salidas JSON válidas.
    pub grammar: Option<String>,
    pub seed: u32,
}

impl GenParams {
    /// Modo sin razonamiento recomendado por Qwen3.5 para tareas generales
    /// (temperature 0.7, top_p 0.8, top_k 20, min_p 0, presence_penalty 1.5).
    /// La penalización se limita a una ventana corta para no castigar las referencias [n].
    pub fn prose(max_tokens: u32) -> GenParams {
        GenParams {
            max_tokens,
            temperature: 0.7,
            top_p: 0.8,
            top_k: 20,
            min_p: 0.0,
            presence_penalty: 1.5,
            penalty_last_n: 64,
            grammar: None,
            seed: 0x5EED_F011,
        }
    }

    /// Salidas JSON con gramática: temperatura baja y sin penalización (los tokens estructurales
    /// `"`, `,`, `{` se repiten por diseño).
    pub fn json(max_tokens: u32, grammar: String) -> GenParams {
        GenParams {
            max_tokens,
            temperature: 0.2,
            top_p: 0.9,
            top_k: 20,
            min_p: 0.0,
            presence_penalty: 0.0,
            penalty_last_n: 0,
            grammar: Some(grammar),
            seed: 0x5EED_F011,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    /// Fin de turno (EOS / `<|im_end|>`).
    Eos,
    MaxTokens,
    Cancelled,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct GenStats {
    pub prompt_tokens: usize,
    pub generated_tokens: usize,
    pub prefill: Duration,
    pub decode: Duration,
}

impl GenStats {
    pub fn prefill_tps(&self) -> f64 {
        rate(self.prompt_tokens, self.prefill)
    }
    pub fn decode_tps(&self) -> f64 {
        rate(self.generated_tokens, self.decode)
    }
}

fn rate(n: usize, d: Duration) -> f64 {
    if d.is_zero() {
        0.0
    } else {
        n as f64 / d.as_secs_f64()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GenOutput {
    pub text: String,
    pub stop: StopReason,
    pub stats: GenStats,
}

/// Opciones de carga de un modelo.
#[derive(Clone, Debug, PartialEq)]
pub struct LoadOptions {
    pub n_ctx: u32,
    /// Hilos de decodificación (token a token).
    pub n_threads: i32,
    /// Hilos de prefill (lotes).
    pub n_threads_batch: i32,
    /// Tamaño de lote de prefill (256–512).
    pub n_batch: u32,
    /// 999 = todas las capas en GPU (Metal en iOS); 0 = CPU.
    pub n_gpu_layers: u32,
}

/// Modelo de lenguaje cargado. Una generación a la vez (`&mut self`).
pub trait Generator: Send {
    fn n_ctx(&self) -> u32;
    /// Nº exacto de tokens del texto (con tokens especiales ChatML interpretados).
    fn count_tokens(&self, text: &str) -> usize;
    /// Genera a partir de un prompt ya formateado (ChatML). `on_text` recibe deltas de texto UTF-8
    /// válidos. Devuelve el texto completo crudo (sin filtrar) y el motivo de parada.
    fn generate(
        &mut self,
        prompt: &str,
        params: &GenParams,
        cancel: &CancelToken,
        on_text: &mut dyn FnMut(&str),
    ) -> anyhow::Result<GenOutput>;
}

/// Modelo de embeddings cargado.
pub trait Embedder: Send {
    fn dim(&self) -> usize;
    /// Vector normalizado L2 del texto (el llamador añade el prefijo de instrucción a las consultas).
    fn embed(&mut self, text: &str) -> anyhow::Result<Vec<f32>>;
}

/// Fábrica de modelos.
pub trait Engine: Send + Sync {
    fn name(&self) -> &'static str;
    fn load_generator(&self, path: &Path, opts: &LoadOptions) -> anyhow::Result<Box<dyn Generator>>;
    fn load_embedder(&self, path: &Path, opts: &LoadOptions) -> anyhow::Result<Box<dyn Embedder>>;
}

/// Motor por defecto: llama.cpp si está compilado; si no, uno que informa de que no hay motor.
pub fn default_engine() -> Arc<dyn Engine> {
    #[cfg(feature = "llama")]
    {
        Arc::new(llama::LlamaEngine)
    }
    #[cfg(not(feature = "llama"))]
    {
        Arc::new(UnavailableEngine)
    }
}

/// Motor usado cuando la crate se compila sin llama.cpp.
pub struct UnavailableEngine;

impl Engine for UnavailableEngine {
    fn name(&self) -> &'static str {
        "none"
    }
    fn load_generator(&self, _: &Path, _: &LoadOptions) -> anyhow::Result<Box<dyn Generator>> {
        anyhow::bail!("Esta compilación no incluye el motor de IA local")
    }
    fn load_embedder(&self, _: &Path, _: &LoadOptions) -> anyhow::Result<Box<dyn Embedder>> {
        anyhow::bail!("Esta compilación no incluye el motor de IA local")
    }
}

/// Normaliza en el sitio (L2). Vectores nulos quedan a cero.
pub fn l2_normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| (*x as f64) * (*x as f64)).sum::<f64>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x = (*x as f64 / norm) as f32;
        }
    }
}

/// Producto escalar (= coseno para vectores normalizados).
pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// Divide el mayor prefijo UTF-8 válido de `buf`, dejando en él los bytes de un carácter incompleto.
pub fn take_valid_utf8(buf: &mut Vec<u8>) -> String {
    match std::str::from_utf8(buf) {
        Ok(s) => {
            let s = s.to_string();
            buf.clear();
            s
        }
        Err(e) => {
            let valid = e.valid_up_to();
            // Secuencia inválida (no solo incompleta): se sustituye para no bloquear la salida.
            if e.error_len().is_some() {
                let s = String::from_utf8_lossy(buf).into_owned();
                buf.clear();
                return s;
            }
            let s = String::from_utf8(buf[..valid].to_vec()).expect("prefijo válido");
            buf.drain(..valid);
            s
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_split_across_tokens() {
        let bytes = "acción ñ".as_bytes();
        let mut buf = bytes[..4].to_vec(); // "acc" + primer byte de "i"? no: 'a','c','c','i' → válido
        assert_eq!(take_valid_utf8(&mut buf), "acci");
        // 'ó' son 2 bytes: partimos entre ellos.
        let o = "ó".as_bytes();
        let mut buf = vec![o[0]];
        assert_eq!(take_valid_utf8(&mut buf), "");
        assert_eq!(buf.len(), 1);
        buf.push(o[1]);
        assert_eq!(take_valid_utf8(&mut buf), "ó");
        assert!(buf.is_empty());
    }

    #[test]
    fn normalize_and_dot() {
        let mut v = vec![3.0, 4.0];
        l2_normalize(&mut v);
        assert!((dot(&v, &v) - 1.0).abs() < 1e-6);
        let mut z = vec![0.0, 0.0];
        l2_normalize(&mut z);
        assert_eq!(z, vec![0.0, 0.0]);
    }

    #[test]
    fn cancel_token_is_shared() {
        let a = CancelToken::new();
        let b = a.clone();
        assert!(!b.is_cancelled());
        a.cancel();
        assert!(b.is_cancelled());
    }
}
