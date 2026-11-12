use crate::api::types::*;
use crate::state;

#[flutter_rust_bridge::frb(init)]
pub fn init_frb() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Abre (o crea) la base de datos en `data_dir`, aplica migraciones, prepara carpetas
/// (`files/`, `models/`, `tmp/`), purga papelera > 30 días, recolecta adjuntos huérfanos
/// y arranca el indexador en segundo plano. Idempotente: llamadas posteriores devuelven el estado.
pub fn init_app(data_dir: String, cache_dir: String) -> anyhow::Result<AppInfo> {
    let (s, first, purged) = state::init(&data_dir, &cache_dir)?;
    Ok(AppInfo {
        data_dir,
        schema_version: s.core.db.schema_version()?,
        first_run: first,
        purged_trash_items: purged,
    })
}

pub fn storage_info() -> anyhow::Result<StorageInfo> {
    Ok(state::get()?.core.storage_info()?.into())
}

pub fn get_setting(key: String) -> anyhow::Result<Option<String>> {
    state::get()?.core.get_setting(&key)
}

pub fn set_setting(key: String, value: String) -> anyhow::Result<()> {
    state::get()?.core.set_setting(&key, &value)
}
