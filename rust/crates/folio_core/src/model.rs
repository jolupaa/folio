//! Tipos de dominio de `folio_core`. Reflejan los DTOs del puente (`rust/src/api/types.rs`), que
//! los convierte uno a uno; aquí no dependen de flutter_rust_bridge.
//!
//! Convenciones: tiempos en milisegundos Unix UTC; rutas devueltas ABSOLUTAS.

use serde::{Deserialize, Serialize};

/// Días que un elemento permanece en la papelera antes de la purga automática.
pub const TRASH_RETENTION_DAYS: i64 = 30;
pub const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// Escena vacía de una pizarra nueva (docs/CONTRATOS.md §2).
pub const EMPTY_SCENE: &str = r#"{"version":1,"elements":[]}"#;

// ─────────────────────────── App ───────────────────────────

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StorageInfo {
    pub free_bytes: i64,
    pub total_bytes: i64,
    pub database_bytes: i64,
    pub files_bytes: i64,
    pub models_bytes: i64,
}

/// Resultado del mantenimiento de arranque.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StartupReport {
    /// Elementos de la papelera purgados por antigüedad (como se cuentan en la papelera).
    pub purged_trash_items: u32,
    /// Adjuntos sin referencia en su nota/pizarra eliminados.
    pub orphan_attachments_removed: u32,
    /// Directorios de `files/` sin fila en `attachments` eliminados.
    pub orphan_dirs_removed: u32,
}

// ─────────────────────────── Biblioteca ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum NoteKind {
    Text,
    Board,
}

impl NoteKind {
    pub fn as_str(self) -> &'static str {
        match self {
            NoteKind::Text => "text",
            NoteKind::Board => "board",
        }
    }
    pub fn from_db(s: &str) -> NoteKind {
        match s {
            "board" => NoteKind::Board,
            _ => NoteKind::Text,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteListScope {
    Inbox,
    Folder,
    All,
    Pinned,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Folder {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
    pub sort_order: i64,
    pub note_count: u32,
    pub total_note_count: u32,
    pub child_count: u32,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteSummary {
    pub id: String,
    pub folder_id: Option<String>,
    pub kind: NoteKind,
    pub title: String,
    pub preview: String,
    pub pinned: bool,
    pub attachment_count: u32,
    pub thumbnail_path: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Note {
    pub id: String,
    pub folder_id: Option<String>,
    pub kind: NoteKind,
    pub title: String,
    pub body_json: String,
    pub pinned: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub revision: i64,
    pub attachments: Vec<Attachment>,
    /// Momento en que se movió a la papelera (None = activa).
    pub deleted_at: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SaveResult {
    pub revision: i64,
    pub updated_at: i64,
    pub conflict: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrashKind {
    Note,
    Folder,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrashItem {
    pub kind: TrashKind,
    pub id: String,
    pub title: String,
    pub note_kind: Option<NoteKind>,
    pub original_location: Vec<String>,
    pub contained_notes: u32,
    pub deleted_at: i64,
    pub days_left: u32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LibraryCounts {
    pub inbox: u32,
    pub all: u32,
    pub pinned: u32,
    pub trash: u32,
    pub study_items: u32,
}

// ─────────────────────────── Búsqueda ───────────────────────────

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SearchScope {
    Library,
    /// Carpeta y todo su subárbol.
    Folder(String),
    /// Una nota: su texto y el de sus adjuntos.
    Note(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchField {
    Title,
    Body,
    Attachment,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub note_id: String,
    pub note_kind: NoteKind,
    pub title: String,
    pub snippet: String,
    pub matched_in: MatchField,
    pub location: Vec<String>,
    pub page_id: Option<String>,
    pub attachment_id: Option<String>,
    pub attachment_name: Option<String>,
    pub page_index: Option<u32>,
    pub updated_at: i64,
    /// Relevancia: mayor = mejor (−bm25).
    pub score: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SearchResults {
    pub query: String,
    pub hits: Vec<SearchHit>,
    pub elapsed_ms: u32,
}

/// Coincidencia en unidades UTF-16.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextMatch {
    pub start: u32,
    pub end: u32,
}

// ─────────────────────────── Adjuntos / OCR ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttachmentKind {
    Image,
    Pdf,
}

impl AttachmentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            AttachmentKind::Image => "image",
            AttachmentKind::Pdf => "pdf",
        }
    }
    pub fn from_db(s: &str) -> AttachmentKind {
        match s {
            "pdf" => AttachmentKind::Pdf,
            _ => AttachmentKind::Image,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextSource {
    None,
    PdfText,
    Ocr,
    OcrEdited,
}

impl TextSource {
    pub fn as_str(self) -> &'static str {
        match self {
            TextSource::None => "none",
            TextSource::PdfText => "pdf_text",
            TextSource::Ocr => "ocr",
            TextSource::OcrEdited => "ocr_edited",
        }
    }
    pub fn from_db(s: &str) -> TextSource {
        match s {
            "pdf_text" => TextSource::PdfText,
            "ocr" => TextSource::Ocr,
            "ocr_edited" => TextSource::OcrEdited,
            _ => TextSource::None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Attachment {
    pub id: String,
    pub note_id: String,
    pub kind: AttachmentKind,
    pub file_name: String,
    pub mime: String,
    pub path: String,
    pub size_bytes: i64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub page_count: u32,
    pub created_at: i64,
}

/// Línea reconocida por OCR. En BD (`attachment_pages.ocr_layout`) se guarda como
/// `[{text,x,y,w,h,conf}]`; al leer se acepta también `confidence`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OcrLine {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default)]
    pub w: f64,
    #[serde(default)]
    pub h: f64,
    #[serde(rename = "conf", alias = "confidence", default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AttachmentPage {
    pub id: String,
    pub attachment_id: String,
    pub page_index: u32,
    pub image_path: Option<String>,
    pub text: String,
    pub text_source: TextSource,
    pub ocr_engine: Option<String>,
    pub ocr_confidence: Option<f64>,
    pub lines: Vec<OcrLine>,
    pub materialized: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PdfImportResult {
    pub attachment: Attachment,
    pub pages: Vec<AttachmentPage>,
    pub pages_needing_ocr: Vec<u32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OcrPageInput {
    pub image_path: Option<String>,
    pub text: String,
    pub engine: String,
    pub confidence: Option<f64>,
    pub lines: Vec<OcrLine>,
    pub edited: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CropRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageInfo {
    pub path: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: i64,
}

// ─────────────────────────── Pizarras ───────────────────────────

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Board {
    pub note_id: String,
    pub title: String,
    pub scene_json: String,
    pub updated_at: i64,
}
