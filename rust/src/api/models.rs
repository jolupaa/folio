use crate::api::types::*;
use crate::convert::vec;
use crate::frb_generated::StreamSink;
use crate::state;

pub fn list_models() -> anyhow::Result<Vec<ModelInfo>> {
    Ok(vec(state::get()?.ai.list_models()))
}

pub fn device_info() -> anyhow::Result<DeviceInfo> {
    Ok(state::get()?.ai.device_info().into())
}

/// Inicia o reanuda (HTTP Range) la descarga. Comprueba espacio libre antes de empezar.
/// Emite eventos hasta Completed/Paused/Cancelled/Failed y cierra el stream.
pub fn download_model(model_id: String, sink: StreamSink<DownloadEvent>) -> anyhow::Result<()> {
    let ai = &state::get()?.ai;
    let signal = ai.db().signal();
    ai.models().download(
        &model_id,
        Box::new(move |ev| {
            let done = ev.kind == folio_ai::types::DownloadEventKind::Completed;
            let _ = sink.add(ev.into());
            if done {
                // Un modelo nuevo (p. ej. embeddings) despierta al indexador.
                signal.bump();
            }
        }),
    )
}

pub fn pause_model_download(model_id: String) -> anyhow::Result<()> {
    state::get()?.ai.models().pause(&model_id)
}

/// Cancela y elimina el fichero parcial.
pub fn cancel_model_download(model_id: String) -> anyhow::Result<()> {
    state::get()?.ai.models().cancel(&model_id)
}

/// Elimina el fichero del modelo y descarga de memoria si estaba cargado.
pub fn delete_model(model_id: String) -> anyhow::Result<()> {
    state::get()?.ai.delete_model(&model_id)
}

pub fn set_active_llm(model_id: String) -> anyhow::Result<()> {
    state::get()?.ai.models().set_active_llm(&model_id)
}
