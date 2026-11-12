use crate::api::types::*;
use crate::convert::vec;
use crate::state;
use folio_ai::store;

/// Materiales de estudio; si `note_id` es Some, solo los que usan esa nota como fuente.
pub fn list_study_items(note_id: Option<String>) -> anyhow::Result<Vec<StudyItemSummary>> {
    Ok(vec(store::list_study_items(&state::get()?.ai.db().read(), note_id.as_deref())?))
}

pub fn get_study_item(id: String) -> anyhow::Result<StudyItem> {
    Ok(store::get_study_item(&state::get()?.ai.db().read(), &id)?.into())
}

/// Edición manual (título y contenido JSON validado según el tipo).
pub fn update_study_item(id: String, title: String, content_json: String) -> anyhow::Result<StudyItem> {
    Ok(store::update_study_item(&state::get()?.ai.db().write(), &id, &title, &content_json)?.into())
}

pub fn delete_study_item(id: String) -> anyhow::Result<()> {
    store::delete_study_item(&state::get()?.ai.db().write(), &id)
}

pub fn save_quiz_attempt(study_id: String, answers_json: String, score: Option<f64>, completed: bool) -> anyhow::Result<QuizAttempt> {
    Ok(store::save_quiz_attempt(&state::get()?.ai.db().write(), &study_id, &answers_json, score, completed)?.into())
}

pub fn list_quiz_attempts(study_id: String) -> anyhow::Result<Vec<QuizAttempt>> {
    Ok(vec(store::list_quiz_attempts(&state::get()?.ai.db().read(), &study_id)?))
}
