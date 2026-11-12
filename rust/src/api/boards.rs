use crate::api::types::*;
use crate::state;

pub fn get_board(note_id: String) -> anyhow::Result<Board> { Ok(state::get()?.core.get_board(&note_id)?.into()) }

/// Guarda la escena (JSON) y deriva el texto plano de los elementos de texto para búsqueda e IA.
pub fn save_board(note_id: String, title: String, scene_json: String) -> anyhow::Result<i64> { state::get()?.core.save_board(&note_id, &title, &scene_json) }
