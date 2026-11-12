//! DTOs expuestos a Dart mediante flutter_rust_bridge.
//!
//! Convenciones del contrato:
//! - ids: `String` (UUID v4). Tiempos: `i64` milisegundos Unix UTC. Tamaños en bytes: `i64`.
//! - Las rutas de ficheros que se devuelven a Dart son ABSOLUTAS.
//! - JSON opaco para Dart cuando la estructura la gestiona la UI (cuerpo de nota, escena de pizarra,
//!   contenido de materiales de estudio); su formato está documentado en docs/CONTRATOS.md.
//! - Fragmentos de búsqueda: coincidencias delimitadas por U+E000 (inicio) y U+E001 (fin).

// ─────────────────────────── App ───────────────────────────

pub struct AppInfo {
    pub data_dir: String,
    pub schema_version: u32,
    pub first_run: bool,
    /// Elementos purgados de la papelera por antigüedad (> 30 días) en este arranque.
    pub purged_trash_items: u32,
}

pub struct StorageInfo {
    pub free_bytes: i64,
    pub total_bytes: i64,
    pub database_bytes: i64,
    pub files_bytes: i64,
    pub models_bytes: i64,
}

// ─────────────────────────── Biblioteca ───────────────────────────

pub struct Folder {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
    pub sort_order: i64,
    /// Notas no borradas directamente en esta carpeta.
    pub note_count: u32,
    /// Notas no borradas en esta carpeta y todas sus subcarpetas.
    pub total_note_count: u32,
    pub child_count: u32,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteKind {
    Text,
    Board,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteListScope {
    /// Notas sin carpeta (bandeja «Notas»).
    Inbox,
    /// Notas directamente en `folder_id` (no recursivo).
    Folder,
    /// Todas las notas no borradas.
    All,
    /// Notas fijadas de toda la biblioteca.
    Pinned,
}

pub struct NoteSummary {
    pub id: String,
    pub folder_id: Option<String>,
    pub kind: NoteKind,
    /// Título visible: título explícito o, si está vacío, primera línea del texto; si no, cadena vacía.
    pub title: String,
    /// Primeros ~140 caracteres de texto plano (sin el título).
    pub preview: String,
    pub pinned: bool,
    pub attachment_count: u32,
    /// Ruta absoluta de la primera imagen adjunta (miniatura), si existe.
    pub thumbnail_path: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub struct Note {
    pub id: String,
    pub folder_id: Option<String>,
    pub kind: NoteKind,
    pub title: String,
    /// JSON de bloques (docs/CONTRATOS.md §1). Para pizarras: "[]".
    pub body_json: String,
    pub pinned: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub revision: i64,
    pub attachments: Vec<Attachment>,
}

pub struct SaveResult {
    pub revision: i64,
    pub updated_at: i64,
    /// true si `base_revision` no coincidía (otro guardado intermedio). Se guarda igualmente
    /// (última escritura gana) pero la UI puede avisar.
    pub conflict: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrashKind {
    Note,
    Folder,
}

pub struct TrashItem {
    pub kind: TrashKind,
    pub id: String,
    pub title: String,
    pub note_kind: Option<NoteKind>,
    /// Ruta de carpetas original (nombres), vacía = bandeja «Notas».
    pub original_location: Vec<String>,
    /// Para carpetas: número de notas que se restaurarán con ella.
    pub contained_notes: u32,
    pub deleted_at: i64,
    pub days_left: u32,
}

pub struct LibraryCounts {
    pub inbox: u32,
    pub all: u32,
    pub pinned: u32,
    pub trash: u32,
    pub study_items: u32,
}

// ─────────────────────────── Búsqueda ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SearchScopeKind {
    Library,
    /// Carpeta `id` y todas sus subcarpetas.
    Folder,
    /// Una nota `id`: su texto y el texto de sus adjuntos (OCR / PDF).
    Note,
}

pub struct SearchScope {
    pub kind: SearchScopeKind,
    pub id: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchField {
    Title,
    Body,
    Attachment,
}

pub struct SearchHit {
    pub note_id: String,
    pub note_kind: NoteKind,
    pub title: String,
    /// Fragmento con coincidencias marcadas con U+E000 … U+E001.
    pub snippet: String,
    pub matched_in: MatchField,
    /// Nombres de carpetas desde la raíz; vacío = bandeja «Notas».
    pub location: Vec<String>,
    pub page_id: Option<String>,
    pub attachment_id: Option<String>,
    pub attachment_name: Option<String>,
    /// 0-based.
    pub page_index: Option<u32>,
    pub updated_at: i64,
    pub score: f64,
}

pub struct SearchResults {
    pub query: String,
    pub hits: Vec<SearchHit>,
    pub elapsed_ms: u32,
}

/// Coincidencia en texto, en unidades UTF-16 (compatibles con `String` de Dart).
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextSource {
    None,
    PdfText,
    Ocr,
    OcrEdited,
}

pub struct Attachment {
    pub id: String,
    pub note_id: String,
    pub kind: AttachmentKind,
    pub file_name: String,
    pub mime: String,
    /// Ruta absoluta.
    pub path: String,
    pub size_bytes: i64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub page_count: u32,
    pub created_at: i64,
}

pub struct OcrLine {
    pub text: String,
    /// Coordenadas normalizadas 0..1, origen arriba-izquierda.
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub confidence: Option<f64>,
}

pub struct AttachmentPage {
    pub id: String,
    pub attachment_id: String,
    pub page_index: u32,
    /// Ruta absoluta de la imagen de la página (foto o render de PDF), si existe.
    pub image_path: Option<String>,
    pub text: String,
    pub text_source: TextSource,
    pub ocr_engine: Option<String>,
    pub ocr_confidence: Option<f64>,
    pub lines: Vec<OcrLine>,
    /// true si su texto está copiado en el cuerpo de la nota (no se indexa dos veces).
    pub materialized: bool,
}

pub struct PdfImportResult {
    pub attachment: Attachment,
    pub pages: Vec<AttachmentPage>,
    /// Índices (0-based) de páginas sin capa de texto útil: candidatas a OCR.
    pub pages_needing_ocr: Vec<u32>,
}

/// Resultado de OCR (posiblemente corregido) de una página, producido por el adaptador nativo.
pub struct OcrPageInput {
    /// Imagen procesada (temporal); Rust la copia al almacenamiento de la app.
    pub image_path: Option<String>,
    pub text: String,
    /// 'apple_vision' | 'mlkit_latin' | ...
    pub engine: String,
    pub confidence: Option<f64>,
    pub lines: Vec<OcrLine>,
    /// true si el usuario corrigió el texto reconocido.
    pub edited: bool,
}

pub struct CropRect {
    /// Normalizado 0..1 respecto a la imagen YA rotada.
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

pub struct ImageInfo {
    pub path: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: i64,
}

// ─────────────────────────── Pizarras ───────────────────────────

pub struct Board {
    pub note_id: String,
    pub title: String,
    /// Escena JSON (docs/CONTRATOS.md §2).
    pub scene_json: String,
    pub updated_at: i64,
}

// ─────────────────────────── Modelos ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelRole {
    Llm,
    Embedding,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelStatus {
    NotInstalled,
    Downloading,
    Paused,
    Verifying,
    Installed,
    Failed,
}

pub struct ModelInfo {
    pub id: String,
    pub display_name: String,
    /// «Recomendado», «Ligero», «Búsqueda semántica»…
    pub tier_label: String,
    pub role: ModelRole,
    pub family: String,
    pub quantization: String,
    pub file_name: String,
    pub url: String,
    pub sha256: String,
    pub size_bytes: i64,
    pub license: String,
    pub license_url: String,
    pub context_length: u32,
    pub min_ram_bytes: i64,
    pub description: String,
    pub status: ModelStatus,
    pub downloaded_bytes: i64,
    pub error: Option<String>,
    pub is_active: bool,
    /// Si el dispositivo cumple los requisitos mínimos estimados.
    pub supported_on_device: bool,
}

pub struct DeviceInfo {
    pub platform: String,
    pub arch: String,
    pub total_ram_bytes: i64,
    pub available_ram_bytes: i64,
    pub cpu_cores: u32,
    pub free_storage_bytes: i64,
    pub recommended_llm_id: Option<String>,
    pub can_run_any_llm: bool,
    /// Explicaciones legibles (p. ej. «RAM insuficiente para el modelo Recomendado»).
    pub notes: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownloadEventKind {
    Started,
    Progress,
    Verifying,
    Completed,
    Paused,
    Cancelled,
    Failed,
}

pub struct DownloadEvent {
    pub model_id: String,
    pub kind: DownloadEventKind,
    pub downloaded_bytes: i64,
    pub total_bytes: i64,
    pub bytes_per_second: i64,
    pub message: Option<String>,
}

// ─────────────────────────── IA ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScopeKind {
    /// Una nota (ids[0]).
    Note,
    /// Varias notas seleccionadas (ids).
    Notes,
    /// Carpeta ids[0] y subcarpetas.
    Folder,
    /// Toda la biblioteca.
    Library,
}

pub struct AiScope {
    pub kind: ScopeKind,
    pub ids: Vec<String>,
}

pub struct ScopeSummary {
    /// «Esta nota», «3 fuentes», «Física», «Toda la biblioteca».
    pub label: String,
    pub note_count: u32,
    pub chunk_count: u32,
    pub embedded_chunk_count: u32,
    /// Notas del ámbito pendientes de indexar.
    pub pending_notes: u32,
}

pub struct AiStatus {
    pub active_llm_id: Option<String>,
    pub llm_installed: bool,
    pub llm_loaded: bool,
    pub embedding_installed: bool,
    pub device_supported: bool,
    /// Motivo legible si la IA no está disponible.
    pub unavailable_reason: Option<String>,
}

pub struct IndexStatus {
    pub total_notes: u32,
    pub pending_notes: u32,
    pub chunk_count: u32,
    pub embedded_chunk_count: u32,
    pub embedding_model_id: Option<String>,
    pub running: bool,
    pub last_error: Option<String>,
}

pub struct Citation {
    /// Número [n] tal como aparece en el texto.
    pub n: u32,
    pub note_id: String,
    pub note_title: String,
    pub location: Vec<String>,
    pub chunk_id: i64,
    pub block_id: Option<String>,
    pub page_id: Option<String>,
    pub attachment_name: Option<String>,
    pub page_index: Option<u32>,
    /// Texto del fragmento (≤ 300 caracteres) para previsualizar y resaltar.
    pub snippet: String,
    /// false si la nota/página ya no existe (borrada tras generar el material).
    pub exists: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AiEventKind {
    /// Tarea creada: `task_id` válido para cancelar.
    Started,
    /// Mensaje de estado y/o progreso (recuperando, cargando modelo, resumiendo parte 2/5…).
    Progress,
    /// Fuentes recuperadas (citations) antes de generar.
    Sources,
    /// Fragmento de texto generado (`text` es un delta).
    Token,
    /// Fin correcto: `text` = resultado completo, `result_id` = mensaje / material guardado.
    Done,
    Cancelled,
    Error,
}

pub struct AiEvent {
    pub task_id: String,
    pub kind: AiEventKind,
    pub text: String,
    pub progress: Option<f64>,
    pub citations: Vec<Citation>,
    pub result_id: Option<String>,
    pub thread_id: Option<String>,
    /// Las fuentes no contienen información suficiente.
    pub insufficient: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StudyKind {
    Summary,
    Outline,
    KeyConcepts,
    Flashcards,
    Quiz,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DetailLevel {
    Brief,
    Detailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuizMix {
    MultipleChoice,
    OpenEnded,
    Mixed,
}

pub struct StudyOptions {
    pub detail: DetailLevel,
    /// Nº de flashcards o preguntas (se acota a 3..=30).
    pub count: u32,
    pub quiz_mix: QuizMix,
    pub title: Option<String>,
}

pub struct SourceRef {
    pub note_id: String,
    pub title: String,
    pub exists: bool,
}

pub struct StudyItemSummary {
    pub id: String,
    pub kind: StudyKind,
    pub title: String,
    pub scope_label: String,
    pub source_count: u32,
    /// Nº de tarjetas / preguntas (0 para textos).
    pub item_count: u32,
    pub created_at: i64,
    pub updated_at: i64,
}

pub struct StudyItem {
    pub id: String,
    pub kind: StudyKind,
    pub title: String,
    pub scope: AiScope,
    pub scope_label: String,
    /// JSON (docs/CONTRATOS.md §3). Las citas incluidas tienen `exists` recalculado al leer.
    pub content_json: String,
    pub model_id: Option<String>,
    pub sources: Vec<SourceRef>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub struct QuizAttempt {
    pub id: String,
    pub study_id: String,
    pub answers_json: String,
    pub score: Option<f64>,
    pub created_at: i64,
    pub completed_at: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChatRole {
    User,
    Assistant,
}

pub struct ChatMessage {
    pub id: String,
    pub thread_id: String,
    pub role: ChatRole,
    pub content: String,
    pub citations: Vec<Citation>,
    pub insufficient: bool,
    /// 'done' | 'cancelled' | 'error'
    pub status: String,
    pub created_at: i64,
}

pub struct ChatThreadSummary {
    pub id: String,
    pub title: String,
    pub scope_label: String,
    pub message_count: u32,
    pub updated_at: i64,
}

pub struct ChatThread {
    pub id: String,
    pub title: String,
    pub scope: AiScope,
    pub scope_label: String,
    pub messages: Vec<ChatMessage>,
    pub created_at: i64,
    pub updated_at: i64,
}
