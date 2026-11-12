//! Conexiones SQLite, migraciones versionadas (PRAGMA user_version) y señal de cambios.
//!
//! Modelo de concurrencia: una conexión de escritura y una de lectura protegidas por mutex
//! (WAL permite leer mientras se escribe). Los trabajadores en segundo plano (indexador,
//! descargas) abren su propia conexión con `Db::connect()`.

use anyhow::Context;
use parking_lot::{Condvar, Mutex, MutexGuard};
use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// Migraciones en orden. NUNCA editar una ya publicada: añadir una nueva.
const MIGRATIONS: &[(u32, &str)] = &[(1, include_str!("../migrations/0001_init.sql"))];

pub const SCHEMA_VERSION: u32 = MIGRATIONS[MIGRATIONS.len() - 1].0;

/// Rutas de almacenamiento de la app.
#[derive(Clone, Debug)]
pub struct Paths {
    /// Directorio persistente (Application Support en iOS, filesDir en Android).
    pub data_dir: PathBuf,
    /// Directorio de caché (temporales, renders de PDF).
    pub cache_dir: PathBuf,
}

impl Paths {
    pub fn new(data_dir: impl Into<PathBuf>, cache_dir: impl Into<PathBuf>) -> Self {
        Paths { data_dir: data_dir.into(), cache_dir: cache_dir.into() }
    }
    pub fn db_file(&self) -> PathBuf {
        self.data_dir.join("folio.sqlite3")
    }
    /// Adjuntos: `files/<attachment_id>/<nombre>`; las rutas en BD son relativas a este dir.
    pub fn files_dir(&self) -> PathBuf {
        self.data_dir.join("files")
    }
    /// Modelos GGUF descargados (excluidos de copia de seguridad en iOS desde Swift).
    pub fn models_dir(&self) -> PathBuf {
        self.data_dir.join("models")
    }
    pub fn tmp_dir(&self) -> PathBuf {
        self.cache_dir.join("tmp")
    }
    pub fn ensure(&self) -> anyhow::Result<()> {
        for d in [self.data_dir.clone(), self.files_dir(), self.models_dir(), self.tmp_dir()] {
            std::fs::create_dir_all(&d).with_context(|| format!("crear {}", d.display()))?;
        }
        Ok(())
    }
}

/// Contador de generación + condvar: cualquier cambio que afecte a búsqueda/IA llama a `bump()`;
/// el indexador espera con `wait_for_change`.
#[derive(Default)]
pub struct ChangeSignal {
    gen: Mutex<u64>,
    cv: Condvar,
}

impl ChangeSignal {
    pub fn bump(&self) {
        let mut g = self.gen.lock();
        *g += 1;
        self.cv.notify_all();
    }
    pub fn current(&self) -> u64 {
        *self.gen.lock()
    }
    /// Espera hasta que la generación sea distinta de `seen` o venza el timeout. Devuelve la actual.
    pub fn wait_for_change(&self, seen: u64, timeout: Duration) -> u64 {
        let mut g = self.gen.lock();
        if *g == seen {
            let _ = self.cv.wait_for(&mut g, timeout);
        }
        *g
    }
}

pub struct Db {
    path: PathBuf,
    writer: Mutex<Connection>,
    reader: Mutex<Connection>,
    signal: Arc<ChangeSignal>,
}

impl Db {
    pub fn open(path: &Path) -> anyhow::Result<Db> {
        let mut writer = open_connection(path)?;
        migrate(&mut writer)?;
        let reader = open_connection(path)?;
        Ok(Db {
            path: path.to_path_buf(),
            writer: Mutex::new(writer),
            reader: Mutex::new(reader),
            signal: Arc::new(ChangeSignal::default()),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Conexión de escritura (serializada). Mantener el guard el menor tiempo posible.
    pub fn write(&self) -> MutexGuard<'_, Connection> {
        self.writer.lock()
    }

    /// Conexión de lectura para la UI (búsqueda, listados).
    pub fn read(&self) -> MutexGuard<'_, Connection> {
        self.reader.lock()
    }

    /// Nueva conexión independiente para hilos en segundo plano.
    pub fn connect(&self) -> anyhow::Result<Connection> {
        open_connection(&self.path)
    }

    pub fn signal(&self) -> Arc<ChangeSignal> {
        self.signal.clone()
    }

    pub fn schema_version(&self) -> anyhow::Result<u32> {
        Ok(self.read().query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))?)
    }
}

fn open_connection(path: &Path) -> anyhow::Result<Connection> {
    let conn = Connection::open(path).with_context(|| format!("abrir {}", path.display()))?;
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.execute_batch(
        "PRAGMA foreign_keys = ON;
         PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA temp_store = MEMORY;",
    )?;
    Ok(conn)
}

/// Aplica en orden las migraciones pendientes, cada una en su transacción.
pub fn migrate(conn: &mut Connection) -> anyhow::Result<u32> {
    let current: u32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if current > SCHEMA_VERSION {
        anyhow::bail!(
            "La base de datos es de una versión más reciente de la app ({current} > {SCHEMA_VERSION})"
        );
    }
    for (version, sql) in MIGRATIONS.iter().filter(|(v, _)| *v > current) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql).with_context(|| format!("migración {version}"))?;
        tx.pragma_update(None, "user_version", version)?;
        tx.commit()?;
        log::info!("migración {version} aplicada");
    }
    Ok(SCHEMA_VERSION)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_fresh_db_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("t.sqlite3");
        let db = Db::open(&p).unwrap();
        assert_eq!(db.schema_version().unwrap(), SCHEMA_VERSION);
        drop(db);
        let db = Db::open(&p).unwrap();
        assert_eq!(db.schema_version().unwrap(), SCHEMA_VERSION);
        let n: i64 = db
            .read()
            .query_row("SELECT count(*) FROM sqlite_master WHERE name = 'search_fts'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    #[test]
    fn foreign_keys_enforced() {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("t.sqlite3")).unwrap();
        let r = db.write().execute(
            "INSERT INTO attachments(id,note_id,kind,file_name,mime,rel_path,size_bytes,sha256,created_at)
             VALUES ('a','no-existe','image','x.jpg','image/jpeg','a/x.jpg',1,'h',0)",
            [],
        );
        assert!(r.is_err());
    }

    #[test]
    fn change_signal_wakes_waiter() {
        let s = Arc::new(ChangeSignal::default());
        let seen = s.current();
        let s2 = s.clone();
        let h = std::thread::spawn(move || s2.wait_for_change(seen, Duration::from_secs(5)));
        std::thread::sleep(Duration::from_millis(50));
        s.bump();
        assert_eq!(h.join().unwrap(), seen + 1);
    }
}
