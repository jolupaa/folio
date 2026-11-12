//! Catálogo de modelos descargables.
//!
//! Tamaños y SHA-256 verificados contra la API de Hugging Face
//! (`/api/models/<repo>/tree/<revisión>`, campos `size` y `lfs.oid`) y URLs con la revisión fijada
//! (`resolve/<revisión>/<fichero>`): si el repositorio cambia, la app sigue descargando exactamente
//! el fichero verificado.
//!
//! ## Requisitos de RAM (`min_ram_bytes`)
//!
//! Es la RAM TOTAL mínima del dispositivo. Se calcula como memoria de trabajo del proceso
//! (pesos + caché KV con el contexto por defecto + estado recurrente + búferes de cómputo +
//! margen de la app) dividida entre la fracción de RAM que iOS/Android dejan usar de forma estable
//! a una app en primer plano (~50 %). Qwen3.5 es híbrido: solo 1 de cada 4 capas usa atención
//! completa (el resto, Gated DeltaNet con estado fijo), así que la caché KV es pequeña.
//!
//! - Qwen3.5-4B Q4_K_M: pesos 2,74 GB; KV f16 = 8 capas de atención × 2 × 4 cabezas KV × 256 × 2 B
//!   = 32 KiB/token → 256 MiB a 8192 tokens; estado DeltaNet ≈ 50 MiB; cómputo ≈ 350 MiB;
//!   embeddings cargados a la vez ≈ 0,65 GB → ≈ 4,0 GB de trabajo. Se exige 7 GiB de RAM total:
//!   los móviles de «8 GB» informan 7,2–7,7 GiB (memoria reservada por el sistema/módem).
//! - Qwen3.5-2B Q4_K_M: pesos 1,28 GB; KV = 6 capas × 2 × 2 × 256 × 2 B = 12 KiB/token → 96 MiB;
//!   estado ≈ 20 MiB; cómputo ≈ 250 MiB; embeddings ≈ 0,65 GB → ≈ 2,3 GB. Se exige 5 GiB
//!   (móviles de «6 GB», que informan 5,3–5,7 GiB).
//! - Qwen3-Embedding-0.6B Q8_0: pesos 0,64 GB; KV = 28 capas × 2 × 8 × 128 × 2 B = 112 KiB/token
//!   → 112 MiB a 1024 tokens; cómputo ≈ 100 MiB → ≈ 0,9 GB. Se exige 3 GiB (móviles de «4 GB»).

use crate::types::ModelRole;

const GIB: i64 = 1024 * 1024 * 1024;

/// Ficha de un modelo del catálogo.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelSpec {
    pub id: String,
    pub display_name: String,
    pub tier_label: String,
    pub role: ModelRole,
    pub family: String,
    pub quantization: String,
    pub file_name: String,
    pub url: String,
    pub sha256: String,
    pub size_bytes: i64,
    pub license: String,
    pub license_url: String,
    /// Contexto que usa la app (no el máximo de entrenamiento).
    pub context_length: u32,
    pub min_ram_bytes: i64,
    pub description: String,
    /// Mayor = más capaz (para elegir el modelo activo por defecto).
    pub capability: u32,
    /// Bytes de caché KV por token de contexto (f16), para reducir el contexto si falta RAM.
    pub kv_bytes_per_token: i64,
}

pub const QWEN35_4B: &str = "qwen3.5-4b-q4km";
pub const QWEN35_2B: &str = "qwen3.5-2b-q4km";
pub const QWEN3_EMBEDDING: &str = "qwen3-embedding-0.6b-q8";

/// Dimensión de los embeddings de Qwen3-Embedding-0.6B.
pub const EMBEDDING_DIM: usize = 1024;
/// Token EOS (`<|endoftext|>`) con el que debe terminar cada entrada de Qwen3-Embedding (pooling LAST).
pub const EMBEDDING_EOS_TOKEN: i32 = 151643;
/// Instrucción para consultas (los documentos se embeben sin prefijo).
pub const EMBEDDING_QUERY_PREFIX: &str = "Instruct: Given a search query in Spanish or English, retrieve passages from the user's personal notes that answer the query\nQuery:";

/// Catálogo por defecto, ordenado para la UI (Recomendado, Ligero, Búsqueda semántica).
pub fn default_catalog() -> Vec<ModelSpec> {
    vec![
        ModelSpec {
            id: QWEN35_4B.into(),
            display_name: "Qwen3.5 4B".into(),
            tier_label: "Recomendado".into(),
            role: ModelRole::Llm,
            family: "Qwen3.5".into(),
            quantization: "Q4_K_M".into(),
            file_name: "Qwen3.5-4B-Q4_K_M.gguf".into(),
            url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf".into(),
            sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4".into(),
            size_bytes: 2_740_937_888,
            license: "Apache-2.0".into(),
            license_url: "https://www.apache.org/licenses/LICENSE-2.0".into(),
            context_length: 8192,
            min_ram_bytes: 7 * GIB,
            description: "La mejor calidad para preguntas, resúmenes, flashcards y cuestionarios. \
                          Necesita un móvil con 8 GB de RAM o más."
                .into(),
            capability: 40,
            kv_bytes_per_token: 32 * 1024,
        },
        ModelSpec {
            id: QWEN35_2B.into(),
            display_name: "Qwen3.5 2B".into(),
            tier_label: "Ligero".into(),
            role: ModelRole::Llm,
            family: "Qwen3.5".into(),
            quantization: "Q4_K_M".into(),
            file_name: "Qwen3.5-2B-Q4_K_M.gguf".into(),
            url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf".into(),
            sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223".into(),
            size_bytes: 1_280_835_840,
            license: "Apache-2.0".into(),
            license_url: "https://www.apache.org/licenses/LICENSE-2.0".into(),
            context_length: 8192,
            min_ram_bytes: 5 * GIB,
            description: "Más rápido y con menos memoria; respuestas algo menos precisas. \
                          Para móviles con 6 GB de RAM o más."
                .into(),
            capability: 20,
            kv_bytes_per_token: 12 * 1024,
        },
        ModelSpec {
            id: QWEN3_EMBEDDING.into(),
            display_name: "Qwen3 Embedding 0.6B".into(),
            tier_label: "Búsqueda semántica".into(),
            role: ModelRole::Embedding,
            family: "Qwen3-Embedding".into(),
            quantization: "Q8_0".into(),
            file_name: "Qwen3-Embedding-0.6B-Q8_0.gguf".into(),
            url: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf".into(),
            sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439".into(),
            size_bytes: 639_150_592,
            license: "Apache-2.0".into(),
            license_url: "https://www.apache.org/licenses/LICENSE-2.0".into(),
            context_length: 1024,
            min_ram_bytes: 3 * GIB,
            description: "Encuentra fragmentos por su significado y no solo por palabras exactas, \
                          para que las respuestas usen las fuentes más relevantes. Opcional."
                .into(),
            capability: 0,
            kv_bytes_per_token: 112 * 1024,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_is_consistent() {
        let c = default_catalog();
        assert_eq!(c.len(), 3);
        let mut ids: Vec<_> = c.iter().map(|m| m.id.as_str()).collect();
        ids.dedup();
        assert_eq!(ids.len(), 3);
        for m in &c {
            assert_eq!(m.sha256.len(), 64);
            assert!(m.sha256.chars().all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()));
            assert!(m.url.starts_with("https://huggingface.co/"));
            assert!(m.url.ends_with(&m.file_name));
            // Revisión fijada (hash de commit de 40 caracteres), nunca `main`.
            let rev = m.url.split("/resolve/").nth(1).unwrap().split('/').next().unwrap();
            assert_eq!(rev.len(), 40, "{}", m.id);
            assert!(m.size_bytes > 0 && m.min_ram_bytes > m.size_bytes);
        }
        assert_eq!(c.iter().filter(|m| m.role == ModelRole::Llm).count(), 2);
    }
}
