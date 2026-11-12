//! Folio AI: índice RAG (fragmentación, BM25 + vectores), gestor de modelos (descarga/verificación),
//! inferencia local con llama.cpp, conversación con citas y materiales de estudio.
//!
//! Punto de entrada: `Ai`. Se crea tras `folio_core::Core::open` y comparte su `Db`.

pub mod catalog;
pub mod chunker;
pub mod device;
pub mod engine;
pub mod index;
pub mod models;
pub mod prompts;
pub mod store;
pub mod text;
pub mod types;

use crate::device::DeviceSnapshot;
use crate::engine::{CancelToken, Embedder, Engine, GenParams, Generator, LoadOptions, StopReason};
use crate::index::Hit;
use crate::models::ModelManager;
use crate::text::{finalize_answer, StreamFilter, INSUFFICIENT_MESSAGE};
use crate::types::*;
use folio_core::util::new_id;
use folio_core::{Db, Paths};
use parking_lot::Mutex;
use rusqlite::Connection;
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub type AiSink = Arc<dyn Fn(AiEvent) + Send + Sync>;
type IndexWatcher = Box<dyn Fn(IndexStatus) -> bool + Send>;

const NO_MODEL_MESSAGE: &str = "Instala un modelo de IA en Ajustes › Modelos de IA para usar esta función.";
/// Tokens reservados para la respuesta en preguntas.
const ANSWER_TOKENS: u32 = 700;
/// Máximo de grupos en el resumen por partes (cada grupo es una llamada al modelo).
const MAX_GROUPS: usize = 16;

struct LoadedGen {
    model_id: String,
    gen: Box<dyn Generator>,
}

struct Inner {
    db: Arc<Db>,
    paths: Paths,
    engine: Arc<dyn Engine>,
    models: Arc<ModelManager>,
    device_override: Option<DeviceSnapshot>,
    /// Conexión propia para recuperación (usa tablas temporales).
    qconn: Mutex<Connection>,
    gen: Mutex<Option<LoadedGen>>,
    emb: Mutex<Option<(String, Box<dyn Embedder>)>>,
    tasks: Mutex<HashMap<String, CancelToken>>,
    active_gens: AtomicUsize,
    release_pending: AtomicBool,
    bg_started: AtomicBool,
    index_running: AtomicBool,
    index_error: Mutex<Option<String>>,
    watchers: Mutex<Vec<IndexWatcher>>,
}

#[derive(Clone)]
pub struct Ai {
    inner: Arc<Inner>,
}

enum End {
    Done(AiEvent),
    Cancelled,
}

impl Ai {
    pub fn new(db: Arc<Db>, paths: Paths) -> anyhow::Result<Ai> {
        let models = ModelManager::new(db.clone(), paths.models_dir());
        Self::with_parts(db, paths, engine::default_engine(), models, None)
    }

    /// Constructor inyectable (tests y pruebas en host).
    pub fn with_parts(
        db: Arc<Db>,
        paths: Paths,
        engine: Arc<dyn Engine>,
        models: Arc<ModelManager>,
        device_override: Option<DeviceSnapshot>,
    ) -> anyhow::Result<Ai> {
        let qconn = Mutex::new(db.connect()?);
        Ok(Ai {
            inner: Arc::new(Inner {
                db,
                paths,
                engine,
                models,
                device_override,
                qconn,
                gen: Mutex::new(None),
                emb: Mutex::new(None),
                tasks: Mutex::new(HashMap::new()),
                active_gens: AtomicUsize::new(0),
                release_pending: AtomicBool::new(false),
                bg_started: AtomicBool::new(false),
                index_running: AtomicBool::new(false),
                index_error: Mutex::new(None),
                watchers: Mutex::new(Vec::new()),
            }),
        })
    }

    pub fn db(&self) -> &Arc<Db> {
        &self.inner.db
    }
    pub fn models(&self) -> &Arc<ModelManager> {
        &self.inner.models
    }
    pub fn device(&self) -> DeviceSnapshot {
        self.inner.device_override.clone().unwrap_or_else(|| DeviceSnapshot::probe(&self.inner.paths.data_dir))
    }
    pub fn device_info(&self) -> DeviceInfo {
        device::device_info(&self.device(), self.inner.models.catalog())
    }
    pub fn list_models(&self) -> Vec<ModelInfo> {
        self.inner.models.list(&self.device())
    }

    /// Elimina un modelo, descargándolo antes de memoria.
    pub fn delete_model(&self, id: &str) -> anyhow::Result<()> {
        {
            let mut g = self.inner.gen.lock();
            if g.as_ref().is_some_and(|l| l.model_id == id) {
                *g = None;
            }
        }
        {
            let mut e = self.inner.emb.lock();
            if e.as_ref().is_some_and(|(m, _)| m == id) {
                *e = None;
            }
        }
        self.inner.models.delete(id)
    }

    // ─────────────────────────── Estado ───────────────────────────

    pub fn ai_status(&self) -> AiStatus {
        let device = self.device();
        let active = self.inner.models.active_llm(&device);
        let supported = active
            .as_deref()
            .and_then(|id| self.inner.models.spec(id).ok())
            .map(|s| device.supports(s))
            .unwrap_or_else(|| device::device_info(&device, self.inner.models.catalog()).can_run_any_llm);
        let reason = if active.is_none() {
            Some(NO_MODEL_MESSAGE.to_string())
        } else if let Some(r) = &device.cpu_incompatibility {
            Some(r.clone())
        } else if !supported {
            Some("Este dispositivo tiene poca memoria para el modelo instalado; la IA puede ir lenta o cerrarse.".to_string())
        } else {
            None
        };
        AiStatus {
            llm_installed: active.is_some(),
            llm_loaded: self.inner.gen.try_lock().map(|g| g.is_some()).unwrap_or(true),
            embedding_installed: self.inner.models.embedding_model().is_some(),
            device_supported: supported,
            unavailable_reason: reason,
            active_llm_id: active,
        }
    }

    pub fn index_status(&self) -> anyhow::Result<IndexStatus> {
        let model = self.inner.models.embedding_model().map(|(id, _)| id);
        Ok(index::status(
            &self.inner.db.read(),
            model.as_deref(),
            self.inner.index_running.load(Ordering::SeqCst),
            self.inner.index_error.lock().clone(),
        )?)
    }

    /// Registra un observador (devuelve false para darse de baja). Emite el estado actual.
    pub fn watch_index(&self, watcher: impl Fn(IndexStatus) -> bool + Send + 'static) -> anyhow::Result<()> {
        if watcher(self.index_status()?) {
            self.inner.watchers.lock().push(Box::new(watcher));
        }
        Ok(())
    }

    fn notify_index(&self) {
        let Ok(st) = self.index_status() else { return };
        self.inner.watchers.lock().retain(|w| w(st.clone()));
    }

    pub fn reindex_all(&self) -> anyhow::Result<()> {
        {
            let w = self.inner.db.write();
            w.execute_batch(
                "DELETE FROM chunks;
                 INSERT INTO index_state(note_id, dirty) SELECT id, 1 FROM notes WHERE true
                   ON CONFLICT(note_id) DO UPDATE SET dirty = 1;",
            )?;
        }
        self.inner.db.signal().bump();
        Ok(())
    }

    pub fn describe_scope(&self, scope: &AiScope) -> anyhow::Result<ScopeSummary> {
        let model = self.inner.models.embedding_model().map(|(id, _)| id);
        store::describe_scope(&self.inner.db.read(), scope, model.as_deref())
    }

    // ─────────────────────────── Indexador ───────────────────────────

    /// Arranca el indexador en segundo plano (idempotente). Espera en `db.signal()`.
    pub fn start_background(&self) -> anyhow::Result<()> {
        if self.inner.bg_started.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        let me = self.clone();
        std::thread::Builder::new().name("folio-indexer".into()).spawn(move || me.indexer_loop())?;
        Ok(())
    }

    fn indexer_loop(&self) {
        let conn = match self.inner.db.connect() {
            Ok(c) => c,
            Err(e) => {
                *self.inner.index_error.lock() = Some(format!("{e:#}"));
                return;
            }
        };
        let signal = self.inner.db.signal();
        let _ = index::ensure_index_rows(&conn);
        loop {
            let seen = signal.current();
            let more = match self.index_pass(&conn, seen) {
                Ok(more) => {
                    *self.inner.index_error.lock() = None;
                    more
                }
                Err(e) => {
                    log::error!("indexador: {e:#}");
                    *self.inner.index_error.lock() = Some(format!("{e:#}"));
                    std::thread::sleep(Duration::from_secs(2));
                    false
                }
            };
            self.inner.index_running.store(false, Ordering::SeqCst);
            self.notify_index();
            if !more {
                signal.wait_for_change(seen, Duration::from_secs(30));
            }
        }
    }

    /// Una pasada: fragmenta notas sucias y embebe pendientes. Devuelve true si queda trabajo.
    fn index_pass(&self, conn: &Connection, seen: u64) -> anyhow::Result<bool> {
        let signal = self.inner.db.signal();
        loop {
            let dirty = index::dirty_notes(conn, 32)?;
            if dirty.is_empty() {
                break;
            }
            self.inner.index_running.store(true, Ordering::SeqCst);
            for id in dirty {
                if let Err(e) = index::index_note(conn, &id) {
                    log::error!("indexar {id}: {e:#}");
                    conn.execute(
                        "UPDATE index_state SET dirty = 0, error = ?2 WHERE note_id = ?1",
                        rusqlite::params![id, format!("{e:#}")],
                    )?;
                }
            }
            self.notify_index();
        }
        let Some((model_id, path)) = self.inner.models.embedding_model() else { return Ok(false) };
        let mut done = 0usize;
        loop {
            // Cede ante generaciones activas y ante cambios nuevos (se reindexa primero).
            if self.inner.active_gens.load(Ordering::SeqCst) > 0 {
                std::thread::sleep(Duration::from_millis(400));
                continue;
            }
            if signal.current() != seen {
                return Ok(true);
            }
            let pending = index::chunks_pending_embedding(conn, &model_id, 8)?;
            if pending.is_empty() {
                return Ok(false);
            }
            self.inner.index_running.store(true, Ordering::SeqCst);
            for (chunk_id, text) in pending {
                let vec = {
                    let mut e = self.inner.emb.lock();
                    let emb = self.embedder(&mut e, &model_id, &path)?;
                    emb.embed(&text)?
                };
                index::store_embedding(conn, chunk_id, &model_id, &vec)?;
                done += 1;
            }
            if done % 16 == 0 {
                self.notify_index();
            }
        }
    }

    /// Indexa ahora mismo las notas sucias del ámbito (para que la IA vea las últimas ediciones).
    fn index_scope_now(&self, conn: &Connection, scope: &AiScope) -> anyhow::Result<usize> {
        let n = index::load_scope(conn, &store::scope_spec(scope)?)?;
        let mut s = conn.prepare_cached(
            "SELECT sn.id FROM temp.scope_notes sn LEFT JOIN index_state st ON st.note_id = sn.id
             WHERE st.note_id IS NULL OR st.dirty = 1",
        )?;
        let dirty: Vec<String> = s.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?;
        drop(s);
        for id in dirty {
            index::index_note(conn, &id)?;
        }
        Ok(n)
    }

    // ─────────────────────────── Motores ───────────────────────────

    fn load_options(&self, n_ctx: u32) -> LoadOptions {
        let d = self.device();
        LoadOptions {
            n_ctx,
            n_threads: d.cpu_cores.clamp(1, 4) as i32,
            n_threads_batch: d.performance_cores.clamp(1, 6) as i32,
            n_batch: 512,
            n_gpu_layers: if cfg!(target_os = "ios") { 999 } else { 0 },
        }
    }

    fn embedder<'a>(
        &self,
        slot: &'a mut Option<(String, Box<dyn Embedder>)>,
        model_id: &str,
        path: &std::path::Path,
    ) -> anyhow::Result<&'a mut Box<dyn Embedder>> {
        if slot.as_ref().is_none_or(|(m, _)| m != model_id) {
            let ctx = self.inner.models.spec(model_id).map(|s| s.context_length).unwrap_or(1024);
            *slot = Some((model_id.to_string(), self.inner.engine.load_embedder(path, &self.load_options(ctx))?));
        }
        Ok(&mut slot.as_mut().expect("embedder cargado").1)
    }

    fn embed_query(&self, query: &str) -> Option<(String, Vec<f32>)> {
        let (model_id, path) = self.inner.models.embedding_model()?;
        let mut e = self.inner.emb.lock();
        let r = self
            .embedder(&mut e, &model_id, &path)
            .and_then(|emb| emb.embed(&format!("{}{}", catalog::EMBEDDING_QUERY_PREFIX, query)));
        match r {
            Ok(v) => Some((model_id, v)),
            Err(err) => {
                log::warn!("embedding de la consulta: {err:#}");
                None
            }
        }
    }

    /// Ejecuta `f` con el LLM activo cargado. Una generación a la vez.
    fn with_generator<R>(
        &self,
        task_id: &str,
        emit: &AiSink,
        f: impl FnOnce(&mut dyn Generator, &str) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let device = self.device();
        let model_id = self.inner.models.active_llm(&device).ok_or_else(|| anyhow::anyhow!(NO_MODEL_MESSAGE))?;
        let path = self.inner.models.installed_path(&model_id).ok_or_else(|| anyhow::anyhow!(NO_MODEL_MESSAGE))?;
        let mut guard = match self.inner.gen.try_lock() {
            Some(g) => g,
            None => {
                emit(AiEvent::new(task_id, AiEventKind::Progress).with_text("En cola: hay otra tarea de IA en curso…"));
                self.inner.gen.lock()
            }
        };
        self.inner.active_gens.fetch_add(1, Ordering::SeqCst);
        let result = (|| {
            if guard.as_ref().is_none_or(|l| l.model_id != model_id) {
                *guard = None;
                emit(AiEvent::new(task_id, AiEventKind::Progress).with_text("Cargando el modelo…"));
                let spec = self.inner.models.spec(&model_id)?;
                // Con poca RAM libre se reduce el contexto (menos caché KV).
                let n_ctx = if device.total_ram < spec.min_ram_bytes as u64 { spec.context_length.min(4096) } else { spec.context_length };
                let gen = self.inner.engine.load_generator(&path, &self.load_options(n_ctx))?;
                *guard = Some(LoadedGen { model_id: model_id.clone(), gen });
            }
            let loaded = guard.as_mut().expect("modelo cargado");
            f(loaded.gen.as_mut(), &model_id)
        })();
        self.inner.active_gens.fetch_sub(1, Ordering::SeqCst);
        if self.inner.release_pending.swap(false, Ordering::SeqCst) {
            *guard = None;
            drop(guard);
            *self.inner.emb.lock() = None;
        }
        result
    }

    /// Libera los modelos de memoria; si hay una tarea activa, al terminar.
    pub fn release_memory(&self) {
        if self.inner.active_gens.load(Ordering::SeqCst) > 0 {
            self.inner.release_pending.store(true, Ordering::SeqCst);
            return;
        }
        if let Some(mut g) = self.inner.gen.try_lock() {
            *g = None;
        }
        if let Some(mut e) = self.inner.emb.try_lock() {
            *e = None;
        }
    }

    // ─────────────────────────── Tareas ───────────────────────────

    pub fn cancel_task(&self, task_id: &str) -> bool {
        match self.inner.tasks.lock().get(task_id) {
            Some(c) => {
                c.cancel();
                true
            }
            None => false,
        }
    }

    fn spawn_task(
        &self,
        emit: AiSink,
        thread_id: Option<String>,
        f: impl FnOnce(&Ai, &str, &CancelToken, &AiSink) -> anyhow::Result<End> + Send + 'static,
    ) -> anyhow::Result<String> {
        let task_id = new_id();
        let cancel = CancelToken::new();
        self.inner.tasks.lock().insert(task_id.clone(), cancel.clone());
        emit(AiEvent::new(&task_id, AiEventKind::Started).with_thread(thread_id));
        let me = self.clone();
        let tid = task_id.clone();
        std::thread::Builder::new().name("folio-ai-task".into()).spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(&me, &tid, &cancel, &emit)));
            me.inner.tasks.lock().remove(&tid);
            match r {
                Ok(Ok(End::Done(ev))) => emit(ev),
                Ok(Ok(End::Cancelled)) => emit(AiEvent::new(&tid, AiEventKind::Cancelled)),
                Ok(Err(e)) => emit(AiEvent::new(&tid, AiEventKind::Error).with_text(format!("{e:#}"))),
                Err(_) => emit(AiEvent::new(&tid, AiEventKind::Error).with_text("La tarea de IA falló de forma inesperada.")),
            }
        })?;
        Ok(task_id)
    }

    // ─────────────────────────── Preguntas ───────────────────────────

    /// Pregunta sobre las fuentes del ámbito. Devuelve el id de tarea (también llega en `Started`).
    pub fn ask(&self, scope: AiScope, question: String, thread_id: Option<String>, emit: AiSink) -> anyhow::Result<String> {
        let question = question.trim().to_string();
        anyhow::ensure!(!question.is_empty(), "Escribe una pregunta");
        let (thread_id, scope) = {
            let w = self.inner.db.write();
            match thread_id {
                Some(t) => {
                    let s = store::thread_scope(&w, &t)?;
                    (t, s)
                }
                None => (store::create_thread(&w, &text::snippet(&question, 60), &scope)?, scope),
            }
        };
        let history = store::thread_messages(&self.inner.db.read(), &thread_id)?;
        store::add_message(&self.inner.db.write(), &thread_id, ChatRole::User, &question, &[], false, "done")?;
        let th = thread_id.clone();
        self.spawn_task(emit, Some(thread_id), move |ai, task, cancel, emit| ai.run_ask(task, cancel, emit, &th, &scope, &question, &history))
    }

    #[allow(clippy::too_many_arguments)]
    fn run_ask(
        &self,
        task: &str,
        cancel: &CancelToken,
        emit: &AiSink,
        thread_id: &str,
        scope: &AiScope,
        question: &str,
        history: &[ChatMessage],
    ) -> anyhow::Result<End> {
        let th = Some(thread_id.to_string());
        let save = |content: &str, cites: &[Citation], insufficient: bool, status: &str| {
            store::add_message(&self.inner.db.write(), thread_id, ChatRole::Assistant, content, cites, insufficient, status)
        };
        if self.inner.models.active_llm(&self.device()).is_none() {
            save(NO_MODEL_MESSAGE, &[], false, "error")?;
            anyhow::bail!(NO_MODEL_MESSAGE);
        }
        emit(AiEvent::new(task, AiEventKind::Progress).with_text("Buscando en tus notas…").with_thread(th.clone()));
        let qvec = self.embed_query(question);
        let hits = {
            let conn = self.inner.qconn.lock();
            self.index_scope_now(&conn, scope)?;
            index::retrieve(&conn, question, qvec.as_ref().map(|(m, v)| (m.as_str(), v.as_slice())), 12)?
        };
        if cancel.is_cancelled() {
            save("", &[], false, "cancelled")?;
            return Ok(End::Cancelled);
        }
        if hits.is_empty() {
            let id = save(INSUFFICIENT_MESSAGE, &[], true, "done")?;
            let mut ev = AiEvent::new(task, AiEventKind::Done).with_text(INSUFFICIENT_MESSAGE).with_thread(th);
            ev.insufficient = true;
            ev.result_id = Some(id);
            return Ok(End::Done(ev));
        }

        let generated = self.with_generator(task, emit, |gen, _| {
            let hist = prompts::history_turns(history);
            let fixed = gen.count_tokens(&prompts::ask_prompt(&[], &hist, question));
            let budget = (gen.n_ctx() as usize).saturating_sub(fixed + ANSWER_TOKENS as usize + 64);
            let mut used_tokens = 0usize;
            let mut selected: Vec<(u32, &Hit)> = Vec::new();
            for h in &hits {
                let n = selected.len() as u32 + 1;
                let cost = gen.count_tokens(&prompts::source_block(n, h, &[]));
                if used_tokens + cost > budget {
                    if selected.is_empty() {
                        continue;
                    }
                    break;
                }
                used_tokens += cost;
                selected.push((n, h));
            }
            anyhow::ensure!(!selected.is_empty(), "Las fuentes no caben en el contexto del modelo");
            let citations: Vec<Citation> = {
                let conn = self.inner.db.read();
                selected.iter().map(|(n, h)| store::citation_for(&conn, *n, h)).collect()
            };
            let mut ev = AiEvent::new(task, AiEventKind::Sources).with_thread(th.clone());
            ev.citations = citations.clone();
            emit(ev);
            let sources: Vec<String> = selected.iter().map(|(n, h)| prompts::source_block(*n, h, &citations[*n as usize - 1].location)).collect();
            let prompt = prompts::ask_prompt(&sources, &hist, question);
            let mut filter = StreamFilter::new(citations.iter().map(|c| c.n));
            let out = gen.generate(&prompt, &GenParams::prose(ANSWER_TOKENS), cancel, &mut |delta| {
                let shown = filter.push(delta);
                if !shown.is_empty() {
                    emit(AiEvent::new(task, AiEventKind::Token).with_text(shown));
                }
            })?;
            let texts: Vec<(u32, String)> = selected.iter().map(|(n, h)| (*n, h.text.clone())).collect();
            Ok((out, citations, texts))
        });
        let (out, citations, source_texts) = match generated {
            Ok(v) => v,
            Err(e) => {
                let _ = save(&format!("{e:#}"), &[], false, "error");
                return Err(e);
            }
        };
        let allowed: BTreeSet<u32> = citations.iter().map(|c| c.n).collect();
        let mut fin = finalize_answer(&out.text, &|n| allowed.contains(&n));
        if !fin.insufficient && fin.used.is_empty() && out.stop != StopReason::Cancelled {
            // El modelo respondió sin referencias: se atribuye por coincidencia con las fuentes
            // enviadas; si ninguna respalda el texto, no se inventa ninguna cita.
            let refs: Vec<(u32, &str)> = source_texts.iter().map(|(n, t)| (*n, t.as_str())).collect();
            let inferred = text::infer_citations(&fin.text, &refs);
            if !inferred.is_empty() {
                let marks: String = inferred.iter().map(|n| format!(" [{n}]")).collect();
                emit(AiEvent::new(task, AiEventKind::Token).with_text(marks.clone()));
                fin.text.push_str(&marks);
                fin.used = inferred;
            }
        }
        let used: Vec<Citation> = citations.into_iter().filter(|c| fin.used.contains(&c.n)).collect();
        if out.stop == StopReason::Cancelled {
            let partial = if fin.insufficient { String::new() } else { fin.text };
            save(&partial, &used, false, "cancelled")?;
            return Ok(End::Cancelled);
        }
        let id = save(&fin.text, &used, fin.insufficient, "done")?;
        let mut ev = AiEvent::new(task, AiEventKind::Done).with_text(fin.text).with_thread(th);
        ev.citations = used;
        ev.insufficient = fin.insufficient;
        ev.result_id = Some(id);
        Ok(End::Done(ev))
    }

    // ─────────────────────────── Estudio ───────────────────────────

    pub fn generate_study(&self, kind: StudyKind, scope: AiScope, options: StudyOptions, emit: AiSink) -> anyhow::Result<String> {
        self.spawn_task(emit, None, move |ai, task, cancel, emit| ai.run_study(task, cancel, emit, kind, &scope, &options))
    }

    fn run_study(
        &self,
        task: &str,
        cancel: &CancelToken,
        emit: &AiSink,
        kind: StudyKind,
        scope: &AiScope,
        options: &StudyOptions,
    ) -> anyhow::Result<End> {
        if self.inner.models.active_llm(&self.device()).is_none() {
            anyhow::bail!(NO_MODEL_MESSAGE);
        }
        let progress = |msg: String, p: Option<f64>| emit(AiEvent::new(task, AiEventKind::Progress).with_text(msg).with_progress(p));
        progress("Leyendo tus fuentes…".into(), None);
        let chunks = {
            let conn = self.inner.qconn.lock();
            self.index_scope_now(&conn, scope)?;
            index::all_chunks_in_scope(&conn)?
        };
        anyhow::ensure!(!chunks.is_empty(), "Las fuentes seleccionadas no tienen texto. Añade contenido o reconoce el texto de los adjuntos.");
        let count = options.count.clamp(3, 30) as usize;
        let citations: Vec<Citation> = {
            let conn = self.inner.db.read();
            chunks.iter().enumerate().map(|(i, h)| store::citation_for(&conn, i as u32 + 1, h)).collect()
        };
        let allowed: BTreeSet<u32> = citations.iter().map(|c| c.n).collect();
        let blocks: Vec<String> = chunks.iter().enumerate().map(|(i, h)| prompts::source_block(i as u32 + 1, h, &citations[i].location)).collect();
        let max_out = prompts::max_tokens(kind, options.detail, count);

        let produced = self.with_generator(task, emit, |gen, model_id| {
            let n_ctx = gen.n_ctx() as usize;
            let budget = n_ctx.saturating_sub(max_out as usize + 450);
            let costs: Vec<usize> = blocks.iter().map(|b| gen.count_tokens(b)).collect();
            let total: usize = costs.iter().sum();
            let mut truncated = false;
            let material = if total <= budget {
                blocks.join("\n\n")
            } else {
                // Por partes: puntos clave de cada grupo (con sus citas) y síntesis final.
                let group_budget = n_ctx.saturating_sub(700 + 450);
                let mut groups: Vec<Vec<usize>> = vec![Vec::new()];
                let mut acc = 0usize;
                for (i, c) in costs.iter().enumerate() {
                    if acc + c > group_budget && !groups.last().expect("grupo").is_empty() {
                        groups.push(Vec::new());
                        acc = 0;
                    }
                    groups.last_mut().expect("grupo").push(i);
                    acc += c;
                }
                if groups.len() > MAX_GROUPS {
                    // Muestreo uniforme: se avisa de que el material es parcial.
                    truncated = true;
                    let step = groups.len() as f64 / MAX_GROUPS as f64;
                    groups = (0..MAX_GROUPS).map(|k| groups[(k as f64 * step) as usize].clone()).collect();
                    log::warn!("estudio: ámbito demasiado grande, se procesan {MAX_GROUPS} grupos de fuentes");
                }
                let per_group = (budget / groups.len()).clamp(120, 600) as u32;
                let mut notes = Vec::new();
                for (gi, g) in groups.iter().enumerate() {
                    if cancel.is_cancelled() {
                        return Ok(None);
                    }
                    progress(format!("Analizando las fuentes: parte {} de {}", gi + 1, groups.len()), Some(gi as f64 / (groups.len() + 1) as f64));
                    let src = g.iter().map(|&i| blocks[i].as_str()).collect::<Vec<_>>().join("\n\n");
                    let out = gen.generate(&prompts::map_prompt(&src), &GenParams::prose(per_group), cancel, &mut |_| {})?;
                    if out.stop == StopReason::Cancelled {
                        return Ok(None);
                    }
                    let fin = finalize_answer(&out.text, &|n| allowed.contains(&n));
                    if !fin.insufficient {
                        notes.push(fin.text);
                    }
                }
                anyhow::ensure!(!notes.is_empty(), "No se pudo extraer contenido de las fuentes");
                notes.join("\n")
            };
            progress(prompts::writing_message(kind).into(), Some(0.9));
            let prompt = prompts::study_prompt(kind, options, count, &material);
            let params = match prompts::grammar(kind, options.quiz_mix) {
                Some(g) => GenParams::json(max_out, g),
                None => GenParams::prose(max_out),
            };
            let is_text = kind.is_text();
            let mut filter = StreamFilter::new(allowed.iter().copied());
            let out = gen.generate(&prompt, &params, cancel, &mut |delta| {
                if is_text {
                    let shown = filter.push(delta);
                    if !shown.is_empty() {
                        emit(AiEvent::new(task, AiEventKind::Token).with_text(shown));
                    }
                }
            })?;
            if out.stop == StopReason::Cancelled {
                return Ok(None);
            }
            Ok(Some((out.text, model_id.to_string(), truncated)))
        })?;
        let Some((raw, model_id, truncated)) = produced else { return Ok(End::Cancelled) };

        let (mut content, used, shown_text) = prompts::build_content(kind, options, count, &raw, &allowed)?;
        let used_citations: Vec<&Citation> = citations.iter().filter(|c| used.contains(&c.n)).collect();
        content["citations"] = serde_json::to_value(&used_citations)?;
        if truncated {
            content["partial"] = json!(true);
        }
        let mut note_ids: Vec<String> = Vec::new();
        for h in &chunks {
            if !note_ids.contains(&h.note_id) {
                note_ids.push(h.note_id.clone());
            }
        }
        let title = {
            let conn = self.inner.db.read();
            options.title.clone().filter(|t| !t.trim().is_empty()).unwrap_or_else(|| format!("{} · {}", kind.display_name(), store::scope_title(&conn, scope)))
        };
        let id = store::insert_study_item(&self.inner.db.write(), kind, &title, scope, &content, Some(&model_id), &note_ids)?;
        let mut ev = AiEvent::new(task, AiEventKind::Done).with_text(shown_text);
        ev.citations = used_citations.into_iter().cloned().collect();
        ev.result_id = Some(id);
        Ok(End::Done(ev))
    }

    /// Corrige una respuesta abierta. `Done.text` = JSON {"score","correct","feedback"}.
    pub fn grade_open_answer(&self, study_id: String, question_id: String, response: String, emit: AiSink) -> anyhow::Result<String> {
        let item = store::get_study_item(&self.inner.db.read(), &study_id)?;
        let content: Value = serde_json::from_str(&item.content_json)?;
        let q = content
            .get("questions")
            .and_then(|q| q.as_array())
            .and_then(|qs| qs.iter().find(|q| q.get("id").and_then(|i| i.as_str()) == Some(question_id.as_str())))
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("La pregunta ya no existe"))?;
        self.spawn_task(emit, None, move |ai, task, cancel, emit| {
            if response.trim().is_empty() {
                let v = json!({"score": 0.0, "correct": false, "feedback": "No has escrito ninguna respuesta."});
                return Ok(End::Done(AiEvent::new(task, AiEventKind::Done).with_text(v.to_string())));
            }
            let prompt = prompts::grade_prompt(&q, &response);
            let out = ai.with_generator(task, emit, |gen, _| gen.generate(&prompt, &GenParams::json(300, prompts::GRADE_GRAMMAR.into()), cancel, &mut |_| {}))?;
            if out.stop == StopReason::Cancelled {
                return Ok(End::Cancelled);
            }
            let v = prompts::parse_grade(&out.text)?;
            Ok(End::Done(AiEvent::new(task, AiEventKind::Done).with_text(v.to_string())))
        })
    }
}
