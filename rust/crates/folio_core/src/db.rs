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
const MIGRATIONS: &[(u32, &str)] = &[
    (1, include_str!("../migrations/0001_init.sql")),
    (2, include_str!("../migrations/0002_study_skills.sql")),
];

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
///
/// Las claves foráneas se desactivan mientras se migra (el PRAGMA no tiene efecto dentro de una
/// transacción) para poder reconstruir tablas sin borrados en cascada; antes de confirmar cada
/// migración se comprueba que no queda ninguna referencia rota. Al terminar se restauran siempre.
pub fn migrate(conn: &mut Connection) -> anyhow::Result<u32> {
    let current: u32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if current > SCHEMA_VERSION {
        anyhow::bail!(
            "La base de datos es de una versión más reciente de la app ({current} > {SCHEMA_VERSION})"
        );
    }
    if current == SCHEMA_VERSION {
        return Ok(SCHEMA_VERSION);
    }
    let fk_on: bool = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0))?;
    conn.execute_batch("PRAGMA foreign_keys = OFF;")?;
    let result = apply_pending(conn, current);
    if fk_on {
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    }
    result?;
    Ok(SCHEMA_VERSION)
}

fn apply_pending(conn: &mut Connection, current: u32) -> anyhow::Result<()> {
    for (version, sql) in MIGRATIONS.iter().filter(|(v, _)| *v > current) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql).with_context(|| format!("migración {version}"))?;
        let broken: i64 = tx.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |r| r.get(0))?;
        anyhow::ensure!(broken == 0, "migración {version}: claves foráneas rotas ({broken})");
        tx.pragma_update(None, "user_version", version)?;
        tx.commit()?;
        log::info!("migración {version} aplicada");
    }
    Ok(())
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

    /// Una instalación v1 con materiales, fuentes e intentos se actualiza sin perder nada y la
    /// cascada sigue funcionando (la migración 2 reconstruye `study_items`).
    #[test]
    fn migration_2_keeps_study_data_and_cascades() {
        let dir = tempfile::tempdir().unwrap();
        let mut conn = Connection::open(dir.path().join("v1.sqlite3")).unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(include_str!("../migrations/0001_init.sql")).unwrap();
        conn.pragma_update(None, "user_version", 1).unwrap();
        conn.execute_batch(
            "INSERT INTO study_items(id,kind,title,scope,content,model_id,created_at,updated_at)
               VALUES ('s1','quiz','Test','{}','{\"questions\":[]}',NULL,1,2);
             INSERT INTO study_item_sources(study_id,note_id) VALUES ('s1','n1');
             INSERT INTO quiz_attempts(id,study_id,answers,score,created_at) VALUES ('a1','s1','[]',0.5,3);",
        )
        .unwrap();

        assert_eq!(migrate(&mut conn).unwrap(), 2);

        let count = |sql: &str| conn.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
        assert_eq!(count("SELECT count(*) FROM study_items WHERE id='s1' AND kind='quiz' AND skill IS NULL AND title='Test'"), 1);
        assert_eq!(count("SELECT count(*) FROM study_item_sources WHERE study_id='s1'"), 1);
        assert_eq!(count("SELECT count(*) FROM quiz_attempts WHERE study_id='s1'"), 1);
        assert_eq!(count("PRAGMA foreign_keys"), 1);

        conn.execute(
            "INSERT INTO study_items(id,kind,skill,title,scope,content,created_at,updated_at)
             VALUES ('s2','skill','feynman','T','{}','{}',1,1)",
            [],
        )
        .unwrap();
        assert!(conn
            .execute("INSERT INTO study_items(id,kind,title,scope,content,created_at,updated_at) VALUES ('s3','skill','T','{}','{}',1,1)", [])
            .is_err());
        assert!(conn
            .execute("INSERT INTO study_items(id,kind,skill,title,scope,content,created_at,updated_at) VALUES ('s4','summary','x','T','{}','{}',1,1)", [])
            .is_err());

        conn.execute("DELETE FROM study_items WHERE id='s1'", []).unwrap();
        assert_eq!(count("SELECT count(*) FROM study_item_sources"), 0);
        assert_eq!(count("SELECT count(*) FROM quiz_attempts"), 0);
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
