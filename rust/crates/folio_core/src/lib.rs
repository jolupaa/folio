//! Folio core: dominio, persistencia (SQLite + migraciones), búsqueda FTS5, adjuntos y pizarras.
//!
//! `Core` es el punto de entrada. Los repositorios se implementan como `impl Core` en sus módulos.
//! `folio_ai` reutiliza `Db` para sus tablas (chunks, embeddings, estudio, chat, modelos).

pub mod attachments;
pub mod blocks;
pub mod boards;
pub mod db;
pub mod folders;
pub mod fsutil;
pub mod images;
pub mod maintenance;
pub mod model;
pub mod notes;
pub mod pdf;
pub mod scope;
pub mod search;
pub mod search_index;
pub mod storage;
pub mod text_find;
pub mod trash;
pub mod util;

pub use db::{ChangeSignal, Db, Paths};

use std::sync::Arc;

pub struct Core {
    pub db: Arc<Db>,
    pub paths: Paths,
}

impl Core {
    /// Abre/crea la base de datos y aplica migraciones. No arranca hilos.
    pub fn open(paths: Paths) -> anyhow::Result<Core> {
        paths.ensure()?;
        let db = Arc::new(Db::open(&paths.db_file())?);
        Ok(Core { db, paths })
    }
}
