use crate::api::types::*;
use crate::convert::vec;
use crate::frb_generated::StreamSink;
use crate::state;
use folio_ai::store;
use std::sync::Arc;

fn ai_sink(sink: StreamSink<AiEvent>) -> folio_ai::AiSink {
    Arc::new(move |ev| {
        let _ = sink.add(ev.into());
    })
}

/// Si la tarea no pudo ni empezar, el error llega como evento (la UI solo escucha el stream).
fn start(sink: StreamSink<AiEvent>, f: impl FnOnce(folio_ai::AiSink) -> anyhow::Result<String>) -> anyhow::Result<()> {
    let emit = ai_sink(sink);
    if let Err(e) = f(emit.clone()) {
        emit(folio_ai::types::AiEvent::new("", folio_ai::types::AiEventKind::Error).with_text(format!("{e:#}")));
    }
    Ok(())
}

pub fn ai_status() -> anyhow::Result<AiStatus> {
    Ok(state::get()?.ai.ai_status().into())
}

pub fn index_status() -> anyhow::Result<IndexStatus> {
    Ok(state::get()?.ai.index_status()?.into())
}

/// Emite el estado del indexador cada vez que cambia (y al suscribirse).
pub fn watch_index(sink: StreamSink<IndexStatus>) -> anyhow::Result<()> {
    state::get()?.ai.watch_index(move |st| sink.add(st.into()).is_ok())
}

pub fn reindex_all() -> anyhow::Result<()> {
    state::get()?.ai.reindex_all()
}

pub fn describe_scope(scope: AiScope) -> anyhow::Result<ScopeSummary> {
    Ok(state::get()?.ai.describe_scope(&scope.into())?.into())
}

/// Pregunta sobre las fuentes del ámbito (RAG). Crea el hilo si `thread_id` es None.
/// Eventos: Started → Progress/Sources → Token* → Done | Cancelled | Error.
pub fn ask(scope: AiScope, question: String, thread_id: Option<String>, sink: StreamSink<AiEvent>) -> anyhow::Result<()> {
    let ai = &state::get()?.ai;
    start(sink, |emit| ai.ask(scope.into(), question, thread_id, emit))
}

/// Genera y GUARDA un material de estudio; `Done.result_id` = id del StudyItem.
pub fn generate_study(kind: StudyKind, scope: AiScope, options: StudyOptions, sink: StreamSink<AiEvent>) -> anyhow::Result<()> {
    let ai = &state::get()?.ai;
    start(sink, |emit| ai.generate_study(kind.into(), scope.into(), options.into(), emit))
}

/// Corrige una respuesta abierta. `Done.text` = JSON {"score":0..1,"correct":bool,"feedback":"..."}.
pub fn grade_open_answer(study_id: String, question_id: String, response: String, sink: StreamSink<AiEvent>) -> anyhow::Result<()> {
    let ai = &state::get()?.ai;
    start(sink, |emit| ai.grade_open_answer(study_id, question_id, response, emit))
}

/// Cancela una tarea (generación, OCR coordinado, indexación manual). true si existía.
#[flutter_rust_bridge::frb(sync)]
pub fn cancel_task(task_id: String) -> bool {
    state::get().map(|s| s.ai.cancel_task(&task_id)).unwrap_or(false)
}

/// Libera el modelo de memoria (p. ej. al pasar la app a segundo plano).
pub fn release_ai_memory() -> anyhow::Result<()> {
    state::get()?.ai.release_memory();
    Ok(())
}

pub fn list_threads() -> anyhow::Result<Vec<ChatThreadSummary>> {
    Ok(vec(store::list_threads(&state::get()?.ai.db().read())?))
}

pub fn get_thread(thread_id: String) -> anyhow::Result<ChatThread> {
    Ok(store::get_thread(&state::get()?.ai.db().read(), &thread_id)?.into())
}

pub fn rename_thread(thread_id: String, title: String) -> anyhow::Result<()> {
    store::rename_thread(&state::get()?.ai.db().write(), &thread_id, &title)
}

pub fn delete_thread(thread_id: String) -> anyhow::Result<()> {
    store::delete_thread(&state::get()?.ai.db().write(), &thread_id)
}
