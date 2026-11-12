use crate::api::types::*;
use crate::convert::vec;
use crate::state;

// ───────────── Carpetas ─────────────

/// Todas las carpetas no borradas, ordenadas por (parent_id, sort_order, nombre).
pub fn list_folders() -> anyhow::Result<Vec<Folder>> { Ok(vec(state::get()?.core.list_folders()?)) }

pub fn create_folder(parent_id: Option<String>, name: String) -> anyhow::Result<Folder> { Ok(state::get()?.core.create_folder(parent_id.as_deref(), &name)?.into()) }

pub fn rename_folder(id: String, name: String) -> anyhow::Result<Folder> { Ok(state::get()?.core.rename_folder(&id, &name)?.into()) }

/// Error si `new_parent_id` es la propia carpeta o una descendiente (ciclo).
pub fn move_folder(id: String, new_parent_id: Option<String>) -> anyhow::Result<Folder> { Ok(state::get()?.core.move_folder(&id, new_parent_id.as_deref())?.into()) }

/// Mueve a la papelera la carpeta, sus subcarpetas y sus notas (mismo `deleted_at`).
/// Devuelve el número de notas afectadas.
pub fn trash_folder(id: String) -> anyhow::Result<u32> { state::get()?.core.trash_folder(&id) }

/// Ruta de carpetas desde la raíz hasta `folder_id` (incluida). Vacía si None.
pub fn folder_path(folder_id: Option<String>) -> anyhow::Result<Vec<Folder>> { Ok(vec(state::get()?.core.folder_path(folder_id.as_deref())?)) }

pub fn library_counts() -> anyhow::Result<LibraryCounts> { Ok(state::get()?.core.library_counts()?.into()) }

// ───────────── Notas ─────────────

/// Fijadas primero; después por `updated_at` descendente.
pub fn list_notes(scope: NoteListScope, folder_id: Option<String>) -> anyhow::Result<Vec<NoteSummary>> { Ok(vec(state::get()?.core.list_notes(scope.into(), folder_id.as_deref())?)) }

pub fn get_note(id: String) -> anyhow::Result<Note> { Ok(state::get()?.core.get_note(&id)?.into()) }

/// Crea nota de texto (cuerpo "[]") o pizarra (fila en `boards` con escena vacía).
pub fn create_note(folder_id: Option<String>, kind: NoteKind, title: String) -> anyhow::Result<Note> { Ok(state::get()?.core.create_note(folder_id.as_deref(), kind.into(), &title)?.into()) }

/// Guardado automático. Valida el JSON de bloques, deriva texto plano, actualiza búsqueda
/// y marca la nota para reindexar (IA). `base_revision` = revisión que tenía la UI.
pub fn save_note(id: String, title: String, body_json: String, base_revision: i64) -> anyhow::Result<SaveResult> { Ok(state::get()?.core.save_note(&id, &title, &body_json, base_revision)?.into()) }

pub fn set_note_pinned(id: String, pinned: bool) -> anyhow::Result<()> { state::get()?.core.set_note_pinned(&id, pinned) }

pub fn move_note(id: String, folder_id: Option<String>) -> anyhow::Result<()> { state::get()?.core.move_note(&id, folder_id.as_deref()) }

pub fn trash_note(id: String) -> anyhow::Result<()> { state::get()?.core.trash_note(&id) }

// ───────────── Papelera ─────────────

/// Carpetas borradas de nivel superior + notas borradas cuya carpeta no está en la papelera.
pub fn list_trash() -> anyhow::Result<Vec<TrashItem>> { Ok(vec(state::get()?.core.list_trash()?)) }

/// Restaurar nota: si su carpeta (o ancestros) están borrados, se restauran también.
/// Restaurar carpeta: restaura su subárbol y las notas borradas en el mismo lote.
pub fn restore_from_trash(kind: TrashKind, id: String) -> anyhow::Result<()> { state::get()?.core.restore_from_trash(kind.into(), &id) }

/// Borra definitivamente (incluye ficheros adjuntos, índices y chunks).
pub fn delete_permanently(kind: TrashKind, id: String) -> anyhow::Result<()> { state::get()?.core.delete_permanently(kind.into(), &id) }

pub fn empty_trash() -> anyhow::Result<u32> { state::get()?.core.empty_trash() }
