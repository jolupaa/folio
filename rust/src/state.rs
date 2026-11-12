//! Estado global de la app en el lado Rust (inicializado por `api::app::init_app`).

use anyhow::anyhow;
use folio_ai::Ai;
use folio_core::{Core, Paths};
use std::sync::{Mutex, OnceLock};

pub struct AppState {
    pub core: Core,
    pub ai: Ai,
}

static STATE: OnceLock<AppState> = OnceLock::new();
static INIT_LOCK: Mutex<()> = Mutex::new(());

/// Inicializa una sola vez. Devuelve (estado, primera_ejecución, elementos purgados de la papelera).
pub fn init(data_dir: &str, cache_dir: &str) -> anyhow::Result<(&'static AppState, bool, u32)> {
    let _guard = INIT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(s) = STATE.get() {
        return Ok((s, false, 0));
    }
    let paths = Paths::new(data_dir, cache_dir);
    let first_run = !paths.db_file().exists();
    let core = Core::open(paths.clone())?;
    let report = core.startup_maintenance();
    let ai = Ai::new(core.db.clone(), paths)?;
    let _ = STATE.set(AppState { core, ai });
    let s = STATE.get().expect("estado inicializado");
    s.ai.start_background()?;
    Ok((s, first_run, report.purged_trash_items))
}

/// Estado inicializado o error legible si la app aún no llamó a `init_app`.
pub fn get() -> anyhow::Result<&'static AppState> {
    STATE.get().ok_or_else(|| anyhow!("La app no está inicializada (falta init_app)"))
}
