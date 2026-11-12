//! Superficie pública Rust ⇄ Dart (flutter_rust_bridge 2.13).
//! Capa fina: valida entrada, delega en `folio_core` / `folio_llm` y convierte a DTOs de `types`.
pub mod ai;
pub mod app;
pub mod attachments;
pub mod boards;
pub mod library;
pub mod models;
pub mod search;
pub mod study;
pub mod types;
