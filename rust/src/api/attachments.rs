use crate::api::types::*;
use crate::convert::vec;
use crate::state;

/// Copia una imagen al almacenamiento de la app y la asocia a la nota (1 página, sin texto).
pub fn import_image(note_id: String, source_path: String, file_name: String) -> anyhow::Result<Attachment> { Ok(state::get()?.core.import_image(&note_id, &source_path, &file_name)?.into()) }

/// Copia un PDF, extrae la capa de texto de cada página e indica qué páginas necesitan OCR.
pub fn import_pdf(note_id: String, source_path: String, file_name: String) -> anyhow::Result<PdfImportResult> { Ok(state::get()?.core.import_pdf(&note_id, &source_path, &file_name)?.into()) }

pub fn get_attachment(id: String) -> anyhow::Result<Attachment> { Ok(state::get()?.core.get_attachment(&id)?.into()) }

pub fn list_attachment_pages(attachment_id: String) -> anyhow::Result<Vec<AttachmentPage>> { Ok(vec(state::get()?.core.list_attachment_pages(&attachment_id)?)) }

pub fn get_page(page_id: String) -> anyhow::Result<AttachmentPage> { Ok(state::get()?.core.get_page(&page_id)?.into()) }

/// Guarda el resultado de OCR de una página existente (p. ej. página escaneada de un PDF).
pub fn set_page_ocr(page_id: String, input: OcrPageInput) -> anyhow::Result<AttachmentPage> { Ok(state::get()?.core.set_page_ocr(&page_id, &input.into())?.into()) }

/// Corrección manual del texto de una página → text_source = OcrEdited (o PdfText si lo era).
pub fn update_page_text(page_id: String, text: String) -> anyhow::Result<AttachmentPage> { Ok(state::get()?.core.update_page_text(&page_id, &text)?.into()) }

pub fn delete_attachment(id: String) -> anyhow::Result<()> { state::get()?.core.delete_attachment(&id) }

/// Normaliza orientación EXIF, rota `rotate_quarter_turns`×90° (horario), recorta y limita
/// el lado mayor a `max_dimension`. Escribe JPEG (calidad 90) en `output_path`.
pub fn process_image(input_path: String, output_path: String, rotate_quarter_turns: i32, crop: Option<CropRect>, max_dimension: u32) -> anyhow::Result<ImageInfo> { let crop: Option<folio_core::model::CropRect> = crop.map(Into::into); Ok(folio_core::images::process_image(std::path::Path::new(&input_path), std::path::Path::new(&output_path), rotate_quarter_turns, crop.as_ref(), max_dimension)?.into()) }

/// Crea una nota con las páginas escaneadas: por página, bloque de imagen + párrafos del texto
/// (con `source_page_id`). Las páginas quedan `materialized = true`.
pub fn create_note_from_scan(folder_id: Option<String>, title: String, pages: Vec<OcrPageInput>) -> anyhow::Result<Note> { let pages: Vec<folio_core::model::OcrPageInput> = vec(pages); Ok(state::get()?.core.create_note_from_scan(folder_id.as_deref(), &title, &pages)?.into()) }

/// Añade las páginas escaneadas al final de una nota existente.
pub fn append_scan_to_note(note_id: String, pages: Vec<OcrPageInput>) -> anyhow::Result<Note> { let pages: Vec<folio_core::model::OcrPageInput> = vec(pages); Ok(state::get()?.core.append_scan_to_note(&note_id, &pages)?.into()) }
