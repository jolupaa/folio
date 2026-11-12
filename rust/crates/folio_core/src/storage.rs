//! Almacenamiento: espacio del volumen (statvfs), tamaños de la app y ajustes clave/valor.

use crate::fsutil::path_size;
use crate::model::StorageInfo;
use crate::Core;
use anyhow::bail;
use rusqlite::{params, OptionalExtension};
use std::path::Path;

/// (libres para la app, totales) en bytes del volumen que contiene `path`.
#[cfg(unix)]
pub fn volume_space(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: `st` es POD y statvfs solo escribe en él; `c` es una cadena C válida.
    unsafe {
        let mut st: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut st) != 0 {
            return None;
        }
        #[allow(clippy::unnecessary_cast)]
        let frsize = if st.f_frsize as u64 > 0 { st.f_frsize as u64 } else { st.f_bsize as u64 };
        #[allow(clippy::unnecessary_cast)]
        Some(((st.f_bavail as u64).saturating_mul(frsize), (st.f_blocks as u64).saturating_mul(frsize)))
    }
}

#[cfg(not(unix))]
pub fn volume_space(_path: &Path) -> Option<(u64, u64)> {
    None
}

fn clamp_i64(v: u64) -> i64 {
    v.min(i64::MAX as u64) as i64
}

/// Longitud máxima de una clave de ajuste.
const MAX_KEY_CHARS: usize = 200;

impl Core {
    pub fn storage_info(&self) -> anyhow::Result<StorageInfo> {
        let (free, total) = volume_space(&self.paths.data_dir).unwrap_or((0, 0));
        let db = self.paths.db_file();
        let mut database = path_size(&db);
        for suffix in ["-wal", "-shm"] {
            let mut p = db.clone().into_os_string();
            p.push(suffix);
            database += path_size(Path::new(&p));
        }
        Ok(StorageInfo {
            free_bytes: clamp_i64(free),
            total_bytes: clamp_i64(total),
            database_bytes: clamp_i64(database),
            files_bytes: clamp_i64(path_size(&self.paths.files_dir())),
            models_bytes: clamp_i64(path_size(&self.paths.models_dir())),
        })
    }

    pub fn get_setting(&self, key: &str) -> anyhow::Result<Option<String>> {
        Ok(self
            .db
            .read()
            .prepare_cached("SELECT value FROM settings WHERE key = ?1")?
            .query_row(params![key], |r| r.get(0))
            .optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> anyhow::Result<()> {
        if key.trim().is_empty() {
            bail!("La clave del ajuste no puede estar vacía");
        }
        if key.chars().count() > MAX_KEY_CHARS {
            bail!("La clave del ajuste es demasiado larga");
        }
        self.db.write().execute(
            "INSERT INTO settings(key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statvfs_reports_space() {
        let d = tempfile::tempdir().unwrap();
        let (free, total) = volume_space(d.path()).unwrap();
        assert!(total > 0);
        assert!(free <= total);
        assert!(volume_space(Path::new("/no/existe/folio")).is_none());
    }
}
