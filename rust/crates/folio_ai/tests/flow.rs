//! Tests de integración con el motor simulado: índice, ámbito, citas, estudio, cancelación y descargas.

use folio_ai::catalog::{ModelSpec, QWEN35_2B, QWEN3_EMBEDDING};
use folio_ai::device::DeviceSnapshot;
use folio_ai::engine::mock::MockEngine;
use folio_ai::models::ModelManager;
use folio_ai::types::*;
use folio_ai::{index, store, Ai, AiSink};
use folio_core::model::NoteKind;
use folio_core::{Core, Paths};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

const GIB: u64 = 1 << 30;

fn device() -> DeviceSnapshot {
    DeviceSnapshot { total_ram: 12 * GIB, available_ram: 8 * GIB, cpu_cores: 8, performance_cores: 4, free_storage: 100 * GIB, cpu_incompatibility: None }
}

struct Env {
    _dir: tempfile::TempDir,
    core: Core,
    ai: Ai,
}

fn install(core: &Core, models: &ModelManager, id: &str) {
    let spec = models.spec(id).unwrap();
    std::fs::write(core.paths.models_dir().join(&spec.file_name), b"gguf").unwrap();
    core.db
        .write()
        .execute(
            "INSERT OR REPLACE INTO models(id,status,downloaded_bytes,total_bytes,file_rel_path,updated_at) VALUES (?1,'installed',?2,?2,?3,0)",
            rusqlite::params![id, spec.size_bytes, spec.file_name],
        )
        .unwrap();
}

fn env_with(engine: MockEngine, llm: bool, emb: bool) -> Env {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path().join("data"), dir.path().join("cache"));
    let core = Core::open(paths.clone()).unwrap();
    let models = ModelManager::new(core.db.clone(), paths.models_dir());
    if llm {
        install(&core, &models, QWEN35_2B);
    }
    if emb {
        install(&core, &models, QWEN3_EMBEDDING);
    }
    let ai = Ai::with_parts(core.db.clone(), paths, Arc::new(engine), models, Some(device())).unwrap();
    Env { _dir: dir, core, ai }
}

fn body(paragraphs: &[&str]) -> String {
    let blocks: Vec<serde_json::Value> =
        paragraphs.iter().enumerate().map(|(i, t)| serde_json::json!({"id": format!("b{i}"), "type": "paragraph", "text": t})).collect();
    serde_json::to_string(&blocks).unwrap()
}

fn note(core: &Core, folder: Option<&str>, title: &str, paragraphs: &[&str]) -> String {
    let n = core.create_note(folder, NoteKind::Text, title).unwrap();
    core.save_note(&n.id, title, &body(paragraphs), n.revision).unwrap();
    n.id
}

fn collect(run: impl FnOnce(AiSink)) -> Vec<AiEvent> {
    let (tx, rx) = mpsc::channel();
    let tx = std::sync::Mutex::new(tx);
    run(Arc::new(move |ev| {
        let _ = tx.lock().unwrap().send(ev);
    }));
    let mut out = Vec::new();
    loop {
        let ev = rx.recv_timeout(Duration::from_secs(20)).expect("evento de IA");
        let end = matches!(ev.kind, AiEventKind::Done | AiEventKind::Cancelled | AiEventKind::Error);
        out.push(ev);
        if end {
            return out;
        }
    }
}

fn scope_note(id: &str) -> AiScope {
    AiScope { kind: ScopeKind::Note, ids: vec![id.to_string()] }
}
fn scope_folder(id: &str) -> AiScope {
    AiScope { kind: ScopeKind::Folder, ids: vec![id.to_string()] }
}

#[test]
fn index_reuses_unchanged_chunks_and_follows_edits() {
    let e = env_with(MockEngine::new(), false, false);
    let long = "La cinemática estudia el movimiento. ".repeat(40);
    let id = note(&e.core, None, "Cinemática", &[&long, "La velocidad es el cambio de posición.", &long.replace("cinemática", "dinámica")]);
    let conn = e.core.db.connect().unwrap();
    let (_, inserted, _) = index::index_note(&conn, &id).unwrap();
    assert!(inserted >= 2, "varios fragmentos: {inserted}");
    // Sin cambios: todo se reutiliza.
    let (reused, ins2, del2) = index::index_note(&conn, &id).unwrap();
    assert_eq!((reused, ins2, del2), (inserted, 0, 0));
    // Editar el último párrafo conserva los primeros fragmentos.
    let n = e.core.get_note(&id).unwrap();
    e.core.save_note(&id, "Cinemática", &body(&[&long, "La velocidad es el cambio de posición.", "Texto nuevo sobre termodinámica."]), n.revision).unwrap();
    let dirty: i64 = conn.query_row("SELECT dirty FROM index_state WHERE note_id = ?1", [&id], |r| r.get(0)).unwrap();
    assert_eq!(dirty, 1, "guardar marca la nota para reindexar");
    let (reused, ins3, del3) = index::index_note(&conn, &id).unwrap();
    assert!(reused >= 1 && ins3 >= 1 && del3 >= 1, "reutiliza={reused} inserta={ins3} borra={del3}");
    let found: i64 = conn.query_row("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'termodinamica'", [], |r| r.get(0)).unwrap();
    assert_eq!(found, 1);
    let gone: i64 = conn.query_row("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'dinamica'", [], |r| r.get(0)).unwrap();
    assert_eq!(gone, 0, "el texto eliminado sale del índice");
}

#[test]
fn retrieval_respects_scope_move_and_trash() {
    let e = env_with(MockEngine::new(), false, false);
    let fis = e.core.create_folder(None, "Física").unwrap();
    let sub = e.core.create_folder(Some(&fis.id), "Tema 1").unwrap();
    let qui = e.core.create_folder(None, "Química").unwrap();
    let a = note(&e.core, Some(&sub.id), "Energía", &["La energía cinética depende de la masa y la velocidad."]);
    let b = note(&e.core, Some(&qui.id), "Reacciones", &["La energía de activación inicia la reacción química."]);
    let conn = e.core.db.connect().unwrap();
    for id in [&a, &b] {
        index::index_note(&conn, id).unwrap();
    }
    let run = |scope: &AiScope| -> Vec<String> {
        index::load_scope(&conn, &store::scope_spec(scope).unwrap()).unwrap();
        index::retrieve(&conn, "¿Qué es la energía?", None, 10).unwrap().into_iter().map(|h| h.note_id).collect()
    };
    assert_eq!(run(&scope_folder(&fis.id)), vec![a.clone()], "carpeta recursiva, sin Química");
    assert_eq!(run(&scope_folder(&qui.id)), vec![b.clone()]);
    assert_eq!(run(&AiScope { kind: ScopeKind::Library, ids: vec![] }).len(), 2);
    assert_eq!(run(&scope_note(&b)), vec![b.clone()]);
    // Mover cambia el ámbito sin reindexar.
    e.core.move_note(&b, Some(&fis.id)).unwrap();
    assert_eq!(run(&scope_folder(&fis.id)).len(), 2);
    assert!(run(&scope_folder(&qui.id)).is_empty());
    // La papelera excluye la nota de inmediato.
    e.core.trash_note(&a).unwrap();
    assert_eq!(run(&AiScope { kind: ScopeKind::Library, ids: vec![] }), vec![b.clone()]);
    assert!(run(&scope_note(&a)).is_empty());
}

#[test]
fn ask_streams_validates_citations_and_persists_thread() {
    let e = env_with(MockEngine::new(), true, true);
    let id = note(&e.core, None, "Cinemática", &["La velocidad es el cambio de posición por unidad de tiempo."]);
    let evs = collect(|sink| {
        e.ai.ask(scope_note(&id), "¿Qué es la velocidad?".into(), None, sink).unwrap();
    });
    assert_eq!(evs[0].kind, AiEventKind::Started);
    let thread_id = evs[0].thread_id.clone().expect("hilo creado");
    assert!(evs.iter().any(|e| e.kind == AiEventKind::Sources && !e.citations.is_empty()));
    let streamed: String = evs.iter().filter(|e| e.kind == AiEventKind::Token).map(|e| e.text.as_str()).collect();
    assert!(!streamed.contains("razonamiento") && !streamed.contains("[99]"), "stream filtrado: {streamed}");
    let done = evs.last().unwrap();
    assert_eq!(done.kind, AiEventKind::Done, "{done:?}");
    assert!(done.text.contains("[1]") && !done.text.contains("[99]") && !done.text.contains("think"));
    assert_eq!(done.citations.len(), 1);
    assert_eq!(done.citations[0].note_id, id);
    assert!(done.citations[0].exists);
    // La cita apunta a un fragmento que existe.
    let n: i64 = e.core.db.read().query_row("SELECT count(*) FROM chunks WHERE id = ?1", [done.citations[0].chunk_id], |r| r.get(0)).unwrap();
    assert_eq!(n, 1);
    let thread = store::get_thread(&e.core.db.read(), &thread_id).unwrap();
    assert_eq!(thread.messages.len(), 2);
    assert_eq!(thread.messages[1].content, done.text);
    // Tras borrar la nota, la cita guardada se marca como inexistente.
    e.core.trash_note(&id).unwrap();
    let thread = store::get_thread(&e.core.db.read(), &thread_id).unwrap();
    assert!(!thread.messages[1].citations[0].exists);
}

#[test]
fn ask_reports_insufficient_sources_and_missing_model() {
    let e = env_with(MockEngine::new(), true, false);
    let id = note(&e.core, None, "Cinemática", &["La velocidad es el cambio de posición."]);
    // Nada relevante en el ámbito: no se llama al modelo.
    let evs = collect(|s| {
        e.ai.ask(scope_note(&id), "fotosíntesis cloroplastos".into(), None, s).unwrap();
    });
    let done = evs.last().unwrap();
    assert!(done.kind == AiEventKind::Done && done.insufficient, "{done:?}");
    // El modelo responde NO_CONSTA.
    let evs = collect(|s| {
        e.ai.ask(scope_note(&id), "velocidad [[sin-datos]]".into(), None, s).unwrap();
    });
    let done = evs.last().unwrap();
    assert!(done.insufficient && done.citations.is_empty());
    assert!(!evs.iter().any(|e| e.kind == AiEventKind::Token && e.text.contains("NO_CONSTA")));

    let e = env_with(MockEngine::new(), false, false);
    let id = note(&e.core, None, "N", &["Texto."]);
    let evs = collect(|s| {
        e.ai.ask(scope_note(&id), "¿qué?".into(), None, s).unwrap();
    });
    let last = evs.last().unwrap();
    assert_eq!(last.kind, AiEventKind::Error);
    assert!(last.text.contains("Instala un modelo"));
    assert!(!e.ai.ai_status().llm_installed);
}

#[test]
fn study_materials_are_generated_saved_and_cited() {
    let e = env_with(MockEngine::new(), true, false);
    let f = e.core.create_folder(None, "Física").unwrap();
    let a = note(&e.core, Some(&f.id), "Cinemática", &["La velocidad es el cambio de posición."]);
    let _b = note(&e.core, Some(&f.id), "Dinámica", &["La aceleración se mide en metros por segundo al cuadrado."]);
    let opts = |count| StudyOptions { detail: DetailLevel::Brief, count, quiz_mix: QuizMix::Mixed, title: None };
    for kind in [StudyKind::Summary, StudyKind::Flashcards, StudyKind::Quiz] {
        let evs = collect(|s| {
            e.ai.generate_study(kind, scope_folder(&f.id), opts(5), s).unwrap();
        });
        let done = evs.last().unwrap();
        assert_eq!(done.kind, AiEventKind::Done, "{kind:?}: {done:?}");
        let item = store::get_study_item(&e.core.db.read(), done.result_id.as_ref().unwrap()).unwrap();
        assert_eq!(item.sources.len(), 2);
        assert!(item.title.contains("Física"), "{}", item.title);
        let v: serde_json::Value = serde_json::from_str(&item.content_json).unwrap();
        store::validate_content(kind, &item.content_json).unwrap();
        assert!(!item.content_json.contains("[99]"), "citas inventadas eliminadas del texto");
        for arr in v["cards"].as_array().into_iter().flatten().chain(v["questions"].as_array().into_iter().flatten()) {
            for n in arr["citations"].as_array().unwrap() {
                assert!(n.as_u64().unwrap() <= 2, "cita inventada en la lista: {n}");
            }
        }
        let cites = v["citations"].as_array().unwrap();
        assert!(!cites.is_empty());
        for c in cites {
            assert!(c["n"].as_u64().unwrap() <= 2 && c["exists"].as_bool().unwrap());
        }
        match kind {
            StudyKind::Flashcards => assert_eq!(v["cards"].as_array().unwrap().len(), 2),
            StudyKind::Quiz => {
                assert_eq!(v["questions"][0]["kind"], "mcq");
                assert_eq!(v["questions"][1]["id"], "q2");
            }
            _ => assert!(v["text"].as_str().unwrap().contains("[1]")),
        }
    }
    assert_eq!(store::list_study_items(&e.core.db.read(), Some(&a)).unwrap().len(), 3);
    assert_eq!(e.core.library_counts().unwrap().study_items, 3);
    // Corrección de respuesta abierta.
    let quiz = store::list_study_items(&e.core.db.read(), None).unwrap().into_iter().find(|i| i.kind == StudyKind::Quiz).unwrap();
    let evs = collect(|s| {
        e.ai.grade_open_answer(quiz.id.clone(), "q2".into(), "Es el cambio de velocidad".into(), s).unwrap();
    });
    let g: serde_json::Value = serde_json::from_str(&evs.last().unwrap().text).unwrap();
    assert_eq!(g["correct"], true);
    // Fuente borrada → marcada en el material.
    e.core.trash_note(&a).unwrap();
    let item = store::get_study_item(&e.core.db.read(), &quiz.id).unwrap();
    assert!(item.sources.iter().any(|s| !s.exists));
}

#[test]
fn large_scope_uses_map_reduce() {
    let e = env_with(MockEngine::new().with_n_ctx(2048), true, false);
    let f = e.core.create_folder(None, "Historia").unwrap();
    for i in 0..12 {
        let p = format!("Capítulo {i}. {}", "La revolución industrial transformó la producción y el transporte. ".repeat(18));
        note(&e.core, Some(&f.id), &format!("Tema {i}"), &[&p]);
    }
    let evs = collect(|s| {
        e.ai.generate_study(StudyKind::Summary, scope_folder(&f.id), StudyOptions { detail: DetailLevel::Detailed, count: 5, quiz_mix: QuizMix::Mixed, title: Some("Mi resumen".into()) }, s).unwrap();
    });
    assert!(evs.iter().any(|e| e.kind == AiEventKind::Progress && e.text.contains("parte 2 de")), "progreso por partes");
    let done = evs.last().unwrap();
    assert_eq!(done.kind, AiEventKind::Done, "{done:?}");
    let item = store::get_study_item(&e.core.db.read(), done.result_id.as_ref().unwrap()).unwrap();
    assert_eq!(item.title, "Mi resumen");
    assert_eq!(item.sources.len(), 12);
}

#[test]
fn generation_can_be_cancelled() {
    let e = env_with(MockEngine::new().with_delay(Duration::from_millis(40)), true, false);
    let id = note(&e.core, None, "Cinemática", &["La velocidad es el cambio de posición."]);
    let (tx, rx) = mpsc::channel();
    let tx = std::sync::Mutex::new(tx);
    let task = e.ai.ask(scope_note(&id), "¿Qué es la velocidad?".into(), None, Arc::new(move |ev| {
        let _ = tx.lock().unwrap().send(ev);
    })).unwrap();
    let mut cancelled = false;
    loop {
        let ev = rx.recv_timeout(Duration::from_secs(20)).unwrap();
        match ev.kind {
            AiEventKind::Token if !cancelled => {
                assert!(e.ai.cancel_task(&task));
                cancelled = true;
            }
            AiEventKind::Cancelled => break,
            AiEventKind::Done | AiEventKind::Error => panic!("debía cancelarse: {ev:?}"),
            _ => {}
        }
    }
    assert!(!e.ai.cancel_task(&task), "la tarea ya no existe");
    let threads = store::list_threads(&e.core.db.read()).unwrap();
    let t = store::get_thread(&e.core.db.read(), &threads[0].id).unwrap();
    assert_eq!(t.messages.last().unwrap().status, "cancelled");
}

#[test]
fn background_indexer_chunks_and_embeds() {
    let engine = MockEngine::new();
    let e = env_with(engine, true, true);
    e.ai.start_background().unwrap();
    let id = note(&e.core, None, "Óptica", &["La refracción cambia la dirección de la luz."]);
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        let st = e.ai.index_status().unwrap();
        if st.pending_notes == 0 && st.chunk_count >= 1 && st.embedded_chunk_count == st.chunk_count {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "indexador lento: {st:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
    let s = e.ai.describe_scope(&scope_note(&id)).unwrap();
    assert_eq!((s.label.as_str(), s.note_count, s.pending_notes), ("Esta nota", 1, 0));
    assert_eq!(s.chunk_count, s.embedded_chunk_count);
}

// ─────────────────────────── Descargas ───────────────────────────

fn serve(data: Vec<u8>, slow: bool) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}/model.gguf", server.server_addr().to_ip().unwrap());
    let ranged = Arc::new(AtomicUsize::new(0));
    let r2 = ranged.clone();
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            let range = req.headers().iter().find(|h| h.field.equiv("Range")).map(|h| h.value.as_str().to_string());
            let start = range.as_deref().and_then(|r| r.strip_prefix("bytes=")).and_then(|r| r.trim_end_matches('-').parse::<usize>().ok());
            let (status, from) = match start {
                Some(s) => {
                    r2.fetch_add(1, Ordering::SeqCst);
                    (206, s)
                }
                None => (200, 0),
            };
            let body = data[from..].to_vec();
            let len = body.len();
            let reader: Box<dyn std::io::Read + Send> = if slow { Box::new(Slow(std::io::Cursor::new(body))) } else { Box::new(std::io::Cursor::new(body)) };
            let _ = req.respond(tiny_http::Response::new(tiny_http::StatusCode(status), vec![], reader, Some(len), None));
        }
    });
    (url, ranged)
}

struct Slow(std::io::Cursor<Vec<u8>>);
impl std::io::Read for Slow {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        std::thread::sleep(Duration::from_millis(15));
        let n = buf.len().min(16 * 1024);
        self.0.read(&mut buf[..n])
    }
}

fn spec(url: &str, data: &[u8], sha: Option<&str>) -> ModelSpec {
    use sha2::Digest;
    let mut s = folio_ai::catalog::default_catalog().into_iter().find(|m| m.id == QWEN35_2B).unwrap();
    s.url = url.to_string();
    s.size_bytes = data.len() as i64;
    s.sha256 = sha.map(str::to_string).unwrap_or_else(|| hex::encode(sha2::Sha256::digest(data)));
    s.file_name = "model.gguf".into();
    s
}

fn manager(dir: &tempfile::TempDir, spec: ModelSpec, free: u64) -> (Arc<folio_core::Db>, Arc<ModelManager>) {
    let db = Arc::new(folio_core::Db::open(&dir.path().join("t.sqlite3")).unwrap());
    let m = ModelManager::with_catalog(db.clone(), dir.path().join("models"), vec![spec], Box::new(move |_| Some(free)));
    (db, m)
}

fn download(m: &Arc<ModelManager>, on: impl Fn(&DownloadEvent) + Send + Sync + 'static) -> DownloadEvent {
    let (tx, rx) = mpsc::channel();
    let tx = std::sync::Mutex::new(tx);
    m.download(QWEN35_2B, Box::new(move |ev| {
        on(&ev);
        if ev.kind.is_terminal() {
            let _ = tx.lock().unwrap().send(ev);
        }
    })).unwrap();
    rx.recv_timeout(Duration::from_secs(30)).expect("fin de descarga")
}

#[test]
fn download_pause_resume_verify_and_delete() {
    let data: Vec<u8> = (0..600_000u32).map(|i| (i % 251) as u8).collect();
    let (url, ranged) = serve(data.clone(), true);
    let dir = tempfile::tempdir().unwrap();
    let (_db, m) = manager(&dir, spec(&url, &data, None), u64::MAX);
    let m2 = m.clone();
    let end = download(&m, move |ev| {
        if ev.kind == DownloadEventKind::Progress && ev.downloaded_bytes > 100_000 {
            m2.pause(QWEN35_2B).unwrap();
        }
    });
    assert_eq!(end.kind, DownloadEventKind::Paused);
    assert!(end.downloaded_bytes > 0 && end.downloaded_bytes < data.len() as i64);
    assert_eq!(m.list(&device())[0].status, ModelStatus::Paused);
    // Reanuda con Range y verifica.
    let end = download(&m, |_| {});
    assert_eq!(end.kind, DownloadEventKind::Completed, "{end:?}");
    assert!(ranged.load(std::sync::atomic::Ordering::SeqCst) >= 1, "se reanudó con Range");
    assert_eq!(std::fs::read(dir.path().join("models/model.gguf")).unwrap(), data);
    let info = &m.list(&device())[0];
    assert!(info.status == ModelStatus::Installed && info.is_active);
    m.delete(QWEN35_2B).unwrap();
    assert!(!dir.path().join("models/model.gguf").exists());
    assert_eq!(m.list(&device())[0].status, ModelStatus::NotInstalled);
}

#[test]
fn download_cancel_bad_hash_and_no_space() {
    let data = vec![7u8; 300_000];
    let (url, _) = serve(data.clone(), true);
    // Cancelar borra el parcial.
    let dir = tempfile::tempdir().unwrap();
    let (_db, m) = manager(&dir, spec(&url, &data, None), u64::MAX);
    let m2 = m.clone();
    let end = download(&m, move |ev| {
        if ev.kind == DownloadEventKind::Progress {
            m2.cancel(QWEN35_2B).unwrap();
        }
    });
    assert_eq!(end.kind, DownloadEventKind::Cancelled);
    assert!(!dir.path().join("models/model.gguf.part").exists());
    // Hash incorrecto: se descarta el fichero.
    let dir = tempfile::tempdir().unwrap();
    let (_db, m) = manager(&dir, spec(&url, &data, Some(&"0".repeat(64))), u64::MAX);
    let end = download(&m, |_| {});
    assert_eq!(end.kind, DownloadEventKind::Failed);
    assert!(end.message.unwrap().contains("dañado"));
    assert!(std::fs::read_dir(dir.path().join("models")).unwrap().next().is_none());
    assert_eq!(m.list(&device())[0].status, ModelStatus::Failed);
    // Espacio insuficiente: ni empieza.
    let dir = tempfile::tempdir().unwrap();
    let (_db, m) = manager(&dir, spec(&url, &data, None), 1000);
    let end = download(&m, |_| {});
    assert_eq!(end.kind, DownloadEventKind::Failed);
    assert!(end.message.unwrap().contains("Espacio insuficiente"));
    // Servidor caído: fallo legible y reanudable.
    let dir = tempfile::tempdir().unwrap();
    let (_db, m) = manager(&dir, spec("http://127.0.0.1:9/x.gguf", &data, None), u64::MAX);
    let end = download(&m, |_| {});
    assert_eq!(end.kind, DownloadEventKind::Failed);
}
