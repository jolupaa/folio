//! Gestor de modelos: catálogo + estado en disco/BD, descargas reanudables (HTTP Range) con
//! verificación SHA-256, pausa, cancelación y eliminación.

use crate::catalog::{default_catalog, ModelSpec};
use crate::device::DeviceSnapshot;
use crate::types::{DownloadEvent, DownloadEventKind, ModelInfo, ModelRole, ModelStatus};
use folio_core::util::now_ms;
use folio_core::Db;
use parking_lot::Mutex;
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const RUN: u8 = 0;
const PAUSE: u8 = 1;
const CANCEL: u8 = 2;
/// Margen de espacio libre que debe quedar tras la descarga.
const SPACE_MARGIN: u64 = 64 * 1024 * 1024;
pub const ACTIVE_LLM_KEY: &str = "active_llm";

pub type DownloadSink = Box<dyn Fn(DownloadEvent) + Send + Sync>;
type FreeSpaceFn = Box<dyn Fn(&Path) -> Option<u64> + Send + Sync>;

pub struct ModelManager {
    db: Arc<Db>,
    dir: PathBuf,
    catalog: Vec<ModelSpec>,
    /// Descargas activas: id → señal de control.
    active: Mutex<HashMap<String, Arc<AtomicU8>>>,
    verifying: Mutex<Vec<String>>,
    free_space: FreeSpaceFn,
}

impl ModelManager {
    pub fn new(db: Arc<Db>, models_dir: PathBuf) -> Arc<ModelManager> {
        Self::with_catalog(db, models_dir, default_catalog(), Box::new(crate::device::free_space))
    }

    pub fn with_catalog(db: Arc<Db>, dir: PathBuf, catalog: Vec<ModelSpec>, free_space: FreeSpaceFn) -> Arc<ModelManager> {
        let _ = std::fs::create_dir_all(&dir);
        let m = Arc::new(ModelManager {
            db,
            dir,
            catalog,
            active: Mutex::new(HashMap::new()),
            verifying: Mutex::new(Vec::new()),
            free_space,
        });
        m.reconcile();
        m
    }

    pub fn catalog(&self) -> &[ModelSpec] {
        &self.catalog
    }

    pub fn spec(&self, id: &str) -> anyhow::Result<&ModelSpec> {
        self.catalog.iter().find(|m| m.id == id).ok_or_else(|| anyhow::anyhow!("Modelo desconocido: {id}"))
    }

    fn final_path(&self, spec: &ModelSpec) -> PathBuf {
        self.dir.join(&spec.file_name)
    }
    fn part_path(&self, spec: &ModelSpec) -> PathBuf {
        self.dir.join(format!("{}.part", spec.file_name))
    }

    /// Ajusta la BD al disco tras un reinicio: descargas a medias → pausadas; instalados sin
    /// fichero → no instalados.
    fn reconcile(&self) {
        let w = self.db.write();
        let _ = w.execute("UPDATE models SET status = 'paused' WHERE status = 'downloading'", []);
        for spec in &self.catalog {
            let status: Option<String> =
                w.query_row("SELECT status FROM models WHERE id = ?1", params![spec.id], |r| r.get(0)).optional().unwrap_or(None);
            match status.as_deref() {
                Some("installed") if !self.final_path(spec).exists() => {
                    let _ = w.execute("DELETE FROM models WHERE id = ?1", params![spec.id]);
                }
                Some("paused") | Some("failed") if !self.part_path(spec).exists() => {
                    let _ = w.execute("UPDATE models SET downloaded_bytes = 0 WHERE id = ?1", params![spec.id]);
                }
                _ => {}
            }
        }
    }

    fn row(&self, id: &str) -> Option<(String, i64, Option<String>)> {
        self.db
            .read()
            .query_row("SELECT status, downloaded_bytes, error FROM models WHERE id = ?1", params![id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()
            .unwrap_or(None)
    }

    fn set_row(&self, spec: &ModelSpec, status: &str, downloaded: i64, error: Option<&str>) {
        let _ = self.db.write().execute(
            "INSERT INTO models(id,status,downloaded_bytes,total_bytes,file_rel_path,error,updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(id) DO UPDATE SET status=excluded.status, downloaded_bytes=excluded.downloaded_bytes,
               error=excluded.error, updated_at=excluded.updated_at",
            params![spec.id, status, downloaded, spec.size_bytes, spec.file_name, error, now_ms()],
        );
    }

    pub fn is_installed(&self, id: &str) -> bool {
        self.installed_path(id).is_some()
    }

    /// Ruta del fichero si el modelo está instalado y presente en disco.
    pub fn installed_path(&self, id: &str) -> Option<PathBuf> {
        let spec = self.spec(id).ok()?;
        let (status, _, _) = self.row(id)?;
        let p = self.final_path(spec);
        (status == "installed" && p.exists()).then_some(p)
    }

    pub fn status_of(&self, spec: &ModelSpec) -> (ModelStatus, i64, Option<String>) {
        if self.verifying.lock().contains(&spec.id) {
            return (ModelStatus::Verifying, spec.size_bytes, None);
        }
        let downloading = self.active.lock().contains_key(&spec.id);
        match self.row(&spec.id) {
            None => (ModelStatus::NotInstalled, 0, None),
            Some((status, bytes, error)) => match status.as_str() {
                "installed" if self.final_path(spec).exists() => (ModelStatus::Installed, spec.size_bytes, None),
                "installed" => (ModelStatus::NotInstalled, 0, None),
                "downloading" if downloading => (ModelStatus::Downloading, bytes, None),
                "downloading" | "paused" => (ModelStatus::Paused, bytes, None),
                "failed" => (ModelStatus::Failed, bytes, error),
                _ => (ModelStatus::NotInstalled, 0, None),
            },
        }
    }

    pub fn list(&self, device: &DeviceSnapshot) -> Vec<ModelInfo> {
        let active = self.active_llm(device);
        self.catalog
            .iter()
            .map(|s| {
                let (status, downloaded_bytes, error) = self.status_of(s);
                ModelInfo {
                    id: s.id.clone(),
                    display_name: s.display_name.clone(),
                    tier_label: s.tier_label.clone(),
                    role: s.role,
                    family: s.family.clone(),
                    quantization: s.quantization.clone(),
                    file_name: s.file_name.clone(),
                    url: s.url.clone(),
                    sha256: s.sha256.clone(),
                    size_bytes: s.size_bytes,
                    license: s.license.clone(),
                    license_url: s.license_url.clone(),
                    context_length: s.context_length,
                    min_ram_bytes: s.min_ram_bytes,
                    description: s.description.clone(),
                    status,
                    downloaded_bytes,
                    error,
                    is_active: active.as_deref() == Some(s.id.as_str()),
                    supported_on_device: device.supports(s),
                }
            })
            .collect()
    }

    /// LLM activo: el elegido por el usuario si sigue instalado; si no, el instalado más capaz
    /// que soporte el dispositivo; si ninguno lo soporta, el instalado más capaz.
    pub fn active_llm(&self, device: &DeviceSnapshot) -> Option<String> {
        let chosen: Option<String> = self
            .db
            .read()
            .query_row("SELECT value FROM settings WHERE key = ?1", params![ACTIVE_LLM_KEY], |r| r.get(0))
            .optional()
            .unwrap_or(None);
        if let Some(id) = chosen {
            if self.is_installed(&id) {
                return Some(id);
            }
        }
        let mut installed: Vec<&ModelSpec> =
            self.catalog.iter().filter(|m| m.role == ModelRole::Llm && self.is_installed(&m.id)).collect();
        installed.sort_by(|a, b| b.capability.cmp(&a.capability));
        installed.iter().find(|m| device.supports(m)).or(installed.first()).map(|m| m.id.clone())
    }

    pub fn set_active_llm(&self, id: &str) -> anyhow::Result<()> {
        let spec = self.spec(id)?;
        anyhow::ensure!(spec.role == ModelRole::Llm, "Este modelo no es un modelo de lenguaje");
        anyhow::ensure!(self.is_installed(id), "El modelo no está instalado");
        self.db.write().execute(
            "INSERT INTO settings(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![ACTIVE_LLM_KEY, id],
        )?;
        Ok(())
    }

    /// Modelo de embeddings instalado (id, ruta).
    pub fn embedding_model(&self) -> Option<(String, PathBuf)> {
        self.catalog
            .iter()
            .filter(|m| m.role == ModelRole::Embedding)
            .find_map(|m| self.installed_path(&m.id).map(|p| (m.id.clone(), p)))
    }

    pub fn pause(&self, id: &str) -> anyhow::Result<()> {
        if let Some(c) = self.active.lock().get(id) {
            c.store(PAUSE, Ordering::SeqCst);
        }
        Ok(())
    }

    /// Cancela y elimina el fichero parcial (también si la descarga estaba pausada o fallida).
    pub fn cancel(&self, id: &str) -> anyhow::Result<()> {
        let spec = self.spec(id)?;
        if let Some(c) = self.active.lock().get(id) {
            c.store(CANCEL, Ordering::SeqCst);
            return Ok(());
        }
        if !self.is_installed(id) {
            let _ = std::fs::remove_file(self.part_path(spec));
            self.db.write().execute("DELETE FROM models WHERE id = ?1", params![id])?;
        }
        Ok(())
    }

    /// Elimina el fichero del modelo (y cualquier parcial). El llamador descarga antes de memoria.
    pub fn delete(&self, id: &str) -> anyhow::Result<()> {
        let spec = self.spec(id)?;
        if let Some(c) = self.active.lock().get(id) {
            c.store(CANCEL, Ordering::SeqCst);
        }
        let _ = std::fs::remove_file(self.part_path(spec));
        match std::fs::remove_file(self.final_path(spec)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => anyhow::bail!("No se pudo eliminar el modelo: {e}"),
        }
        let w = self.db.write();
        w.execute("DELETE FROM models WHERE id = ?1", params![id])?;
        w.execute("DELETE FROM settings WHERE key = ?1 AND value = ?2", params![ACTIVE_LLM_KEY, id])?;
        Ok(())
    }

    /// Inicia o reanuda la descarga en un hilo propio. Emite eventos hasta uno terminal.
    pub fn download(self: &Arc<Self>, id: &str, sink: DownloadSink) -> anyhow::Result<()> {
        let spec = self.spec(id)?.clone();
        let ctl = Arc::new(AtomicU8::new(RUN));
        {
            let mut active = self.active.lock();
            if active.contains_key(id) {
                anyhow::bail!("Este modelo ya se está descargando");
            }
            active.insert(id.to_string(), ctl.clone());
        }
        let me = self.clone();
        std::thread::Builder::new().name(format!("folio-dl-{id}")).spawn(move || {
            let ev = |kind, downloaded: i64, bps: i64, message: Option<String>| {
                sink(DownloadEvent {
                    model_id: spec.id.clone(),
                    kind,
                    downloaded_bytes: downloaded,
                    total_bytes: spec.size_bytes,
                    bytes_per_second: bps,
                    message,
                })
            };
            let outcome = me.run_download(&spec, &ctl, &ev);
            me.verifying.lock().retain(|v| v != &spec.id);
            me.active.lock().remove(&spec.id);
            let part_len = std::fs::metadata(me.part_path(&spec)).map(|m| m.len() as i64).unwrap_or(0);
            match outcome {
                Ok(Outcome::Completed) => {
                    me.set_row(&spec, "installed", spec.size_bytes, None);
                    ev(DownloadEventKind::Completed, spec.size_bytes, 0, None);
                }
                Ok(Outcome::Paused) => {
                    me.set_row(&spec, "paused", part_len, None);
                    ev(DownloadEventKind::Paused, part_len, 0, None);
                }
                Ok(Outcome::Cancelled) => {
                    let _ = std::fs::remove_file(me.part_path(&spec));
                    let _ = me.db.write().execute("DELETE FROM models WHERE id = ?1", params![spec.id]);
                    ev(DownloadEventKind::Cancelled, 0, 0, None);
                }
                Err(e) => {
                    let msg = format!("{e:#}");
                    me.set_row(&spec, "failed", part_len, Some(&msg));
                    ev(DownloadEventKind::Failed, part_len, 0, Some(msg));
                }
            }
        })?;
        Ok(())
    }

    fn run_download(
        &self,
        spec: &ModelSpec,
        ctl: &AtomicU8,
        ev: &dyn Fn(DownloadEventKind, i64, i64, Option<String>),
    ) -> anyhow::Result<Outcome> {
        let final_path = self.final_path(spec);
        if self.is_installed(&spec.id) {
            return Ok(Outcome::Completed);
        }
        std::fs::create_dir_all(&self.dir)?;
        let part = self.part_path(spec);
        let total = spec.size_bytes as u64;
        let mut have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        if have > total {
            let _ = std::fs::remove_file(&part);
            have = 0;
        }
        if let Some(free) = (self.free_space)(&self.dir) {
            let needed = total - have + SPACE_MARGIN;
            if free < needed {
                anyhow::bail!(
                    "Espacio insuficiente: se necesitan {} libres y hay {}",
                    crate::device::format_bytes(needed),
                    crate::device::format_bytes(free)
                );
            }
        }
        self.set_row(spec, "downloading", have as i64, None);
        ev(DownloadEventKind::Started, have as i64, 0, None);

        if have < total {
            let config = ureq::Agent::config_builder()
                .http_status_as_error(false)
                .timeout_connect(Some(Duration::from_secs(20)))
                .timeout_recv_response(Some(Duration::from_secs(30)))
                .build();
            let agent: ureq::Agent = config.into();
            let mut req = agent.get(&spec.url).header("User-Agent", "Folio/1.0");
            if have > 0 {
                req = req.header("Range", format!("bytes={have}-"));
            }
            let mut resp = req.call().map_err(|e| anyhow::anyhow!("Sin conexión o servidor no disponible ({e})"))?;
            let status = resp.status().as_u16();
            let mut file = match status {
                206 => std::fs::OpenOptions::new().append(true).open(&part)?,
                200 => {
                    have = 0;
                    std::fs::File::create(&part)?
                }
                416 => {
                    let _ = std::fs::remove_file(&part);
                    anyhow::bail!("La descarga parcial no era válida; vuelve a intentarlo");
                }
                s => anyhow::bail!("El servidor respondió con el código {s}"),
            };
            let mut reader = resp.body_mut().as_reader();
            let mut buf = vec![0u8; 128 * 1024];
            let mut last_emit = Instant::now();
            let mut last_db = Instant::now();
            let mut window_bytes = 0u64;
            let mut bps = 0i64;
            loop {
                match ctl.load(Ordering::SeqCst) {
                    PAUSE => {
                        file.flush()?;
                        return Ok(Outcome::Paused);
                    }
                    CANCEL => return Ok(Outcome::Cancelled),
                    _ => {}
                }
                let n = reader.read(&mut buf).map_err(|e| anyhow::anyhow!("Se interrumpió la conexión ({e}). Puedes reanudar la descarga."))?;
                if n == 0 {
                    break;
                }
                if have + n as u64 > total {
                    anyhow::bail!("El servidor envió más datos de los esperados");
                }
                file.write_all(&buf[..n]).map_err(|e| anyhow::anyhow!("No se pudo escribir en el almacenamiento ({e})"))?;
                have += n as u64;
                window_bytes += n as u64;
                let el = last_emit.elapsed();
                if el >= Duration::from_millis(250) {
                    let inst = (window_bytes as f64 / el.as_secs_f64()) as i64;
                    bps = if bps == 0 { inst } else { (bps * 7 + inst * 3) / 10 };
                    window_bytes = 0;
                    last_emit = Instant::now();
                    ev(DownloadEventKind::Progress, have as i64, bps, None);
                }
                if last_db.elapsed() >= Duration::from_secs(2) {
                    last_db = Instant::now();
                    self.set_row(spec, "downloading", have as i64, None);
                }
            }
            file.flush()?;
            file.sync_all().ok();
            if have < total {
                anyhow::bail!("La descarga se cortó antes de terminar. Puedes reanudarla.");
            }
        }

        self.verifying.lock().push(spec.id.clone());
        ev(DownloadEventKind::Verifying, total as i64, 0, None);
        let mut hasher = Sha256::new();
        let mut f = std::fs::File::open(&part)?;
        let mut buf = vec![0u8; 1024 * 1024];
        loop {
            if ctl.load(Ordering::SeqCst) == CANCEL {
                return Ok(Outcome::Cancelled);
            }
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let digest = hex::encode(hasher.finalize());
        if !digest.eq_ignore_ascii_case(&spec.sha256) {
            let _ = std::fs::remove_file(&part);
            anyhow::bail!("El fichero descargado está dañado (la verificación no coincide). Vuelve a descargarlo.");
        }
        std::fs::rename(&part, &final_path)?;
        Ok(Outcome::Completed)
    }
}

enum Outcome {
    Completed,
    Paused,
    Cancelled,
}
