//! Tipos del dominio de IA. Reflejan los DTOs de `rust/src/api/types.rs` (la capa API convierte
//! campo a campo); aquí además se serializan a/desde JSON con el formato de docs/CONTRATOS.md.

use serde::{Deserialize, Serialize};

// ─────────────────────────── Ámbito ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeKind {
    /// Una nota (ids[0]).
    Note,
    /// Varias notas seleccionadas.
    Notes,
    /// Carpeta ids[0] y subcarpetas.
    Folder,
    /// Toda la biblioteca.
    Library,
}

/// Ámbito de una pregunta o material. Se guarda como JSON `{"kind":"note|notes|folder|library","ids":[…]}`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AiScope {
    pub kind: ScopeKind,
    #[serde(default)]
    pub ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopeSummary {
    pub label: String,
    pub note_count: u32,
    pub chunk_count: u32,
    pub embedded_chunk_count: u32,
    pub pending_notes: u32,
}

// ─────────────────────────── Citas y eventos ───────────────────────────

/// Cita (docs/CONTRATOS.md §4). Claves JSON en snake_case; los opcionales se serializan como null.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Citation {
    pub n: u32,
    pub note_id: String,
    #[serde(default)]
    pub note_title: String,
    #[serde(default)]
    pub location: Vec<String>,
    #[serde(default)]
    pub chunk_id: i64,
    #[serde(default)]
    pub block_id: Option<String>,
    #[serde(default)]
    pub page_id: Option<String>,
    #[serde(default)]
    pub attachment_name: Option<String>,
    #[serde(default)]
    pub page_index: Option<u32>,
    #[serde(default)]
    pub snippet: String,
    #[serde(default = "default_true")]
    pub exists: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AiEventKind {
    Started,
    Progress,
    Sources,
    Token,
    Done,
    Cancelled,
    Error,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AiEvent {
    pub task_id: String,
    pub kind: AiEventKind,
    pub text: String,
    pub progress: Option<f64>,
    pub citations: Vec<Citation>,
    pub result_id: Option<String>,
    pub thread_id: Option<String>,
    pub insufficient: bool,
}

impl AiEvent {
    pub fn new(task_id: &str, kind: AiEventKind) -> AiEvent {
        AiEvent {
            task_id: task_id.to_string(),
            kind,
            text: String::new(),
            progress: None,
            citations: Vec::new(),
            result_id: None,
            thread_id: None,
            insufficient: false,
        }
    }
    pub fn with_text(mut self, text: impl Into<String>) -> AiEvent {
        self.text = text.into();
        self
    }
    pub fn with_progress(mut self, p: Option<f64>) -> AiEvent {
        self.progress = p;
        self
    }
    pub fn with_thread(mut self, thread_id: Option<String>) -> AiEvent {
        self.thread_id = thread_id;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AiStatus {
    pub active_llm_id: Option<String>,
    pub llm_installed: bool,
    pub llm_loaded: bool,
    pub embedding_installed: bool,
    pub device_supported: bool,
    pub unavailable_reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexStatus {
    pub total_notes: u32,
    pub pending_notes: u32,
    pub chunk_count: u32,
    pub embedded_chunk_count: u32,
    pub embedding_model_id: Option<String>,
    pub running: bool,
    pub last_error: Option<String>,
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

#[derive(Clone, Debug, PartialEq)]
pub struct ModelInfo {
    pub id: String,
    pub display_name: String,
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
    pub supported_on_device: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceInfo {
    pub platform: String,
    pub arch: String,
    pub total_ram_bytes: i64,
    pub available_ram_bytes: i64,
    pub cpu_cores: u32,
    pub free_storage_bytes: i64,
    pub recommended_llm_id: Option<String>,
    pub can_run_any_llm: bool,
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

#[derive(Clone, Debug, PartialEq)]
pub struct DownloadEvent {
    pub model_id: String,
    pub kind: DownloadEventKind,
    pub downloaded_bytes: i64,
    pub total_bytes: i64,
    pub bytes_per_second: i64,
    pub message: Option<String>,
}

impl DownloadEventKind {
    /// Eventos tras los que el stream se cierra.
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            DownloadEventKind::Completed
                | DownloadEventKind::Paused
                | DownloadEventKind::Cancelled
                | DownloadEventKind::Failed
        )
    }
}

// ─────────────────────────── Estudio ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StudyKind {
    Summary,
    Outline,
    KeyConcepts,
    Flashcards,
    Quiz,
}

impl StudyKind {
    pub fn as_db(self) -> &'static str {
        match self {
            StudyKind::Summary => "summary",
            StudyKind::Outline => "outline",
            StudyKind::KeyConcepts => "key_concepts",
            StudyKind::Flashcards => "flashcards",
            StudyKind::Quiz => "quiz",
        }
    }
    pub fn from_db(s: &str) -> Option<StudyKind> {
        Some(match s {
            "summary" => StudyKind::Summary,
            "outline" => StudyKind::Outline,
            "key_concepts" => StudyKind::KeyConcepts,
            "flashcards" => StudyKind::Flashcards,
            "quiz" => StudyKind::Quiz,
            _ => return None,
        })
    }
    /// Nombre visible (título por defecto «<nombre> · <ámbito>»).
    pub fn display_name(self) -> &'static str {
        match self {
            StudyKind::Summary => "Resumen",
            StudyKind::Outline => "Esquema",
            StudyKind::KeyConcepts => "Conceptos clave",
            StudyKind::Flashcards => "Flashcards",
            StudyKind::Quiz => "Cuestionario",
        }
    }
    pub fn is_text(self) -> bool {
        matches!(self, StudyKind::Summary | StudyKind::Outline | StudyKind::KeyConcepts)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DetailLevel {
    Brief,
    Detailed,
}

impl DetailLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            DetailLevel::Brief => "brief",
            DetailLevel::Detailed => "detailed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuizMix {
    MultipleChoice,
    OpenEnded,
    Mixed,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StudyOptions {
    pub detail: DetailLevel,
    pub count: u32,
    pub quiz_mix: QuizMix,
    pub title: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceRef {
    pub note_id: String,
    pub title: String,
    pub exists: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StudyItemSummary {
    pub id: String,
    pub kind: StudyKind,
    pub title: String,
    pub scope_label: String,
    pub source_count: u32,
    pub item_count: u32,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StudyItem {
    pub id: String,
    pub kind: StudyKind,
    pub title: String,
    pub scope: AiScope,
    pub scope_label: String,
    pub content_json: String,
    pub model_id: Option<String>,
    pub sources: Vec<SourceRef>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct QuizAttempt {
    pub id: String,
    pub study_id: String,
    pub answers_json: String,
    pub score: Option<f64>,
    pub created_at: i64,
    pub completed_at: Option<i64>,
}

// ─────────────────────────── Conversación ───────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChatMessage {
    pub id: String,
    pub thread_id: String,
    pub role: ChatRole,
    pub content: String,
    pub citations: Vec<Citation>,
    pub insufficient: bool,
    pub status: String,
    pub created_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatThreadSummary {
    pub id: String,
    pub title: String,
    pub scope_label: String,
    pub message_count: u32,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChatThread {
    pub id: String,
    pub title: String,
    pub scope: AiScope,
    pub scope_label: String,
    pub messages: Vec<ChatMessage>,
    pub created_at: i64,
    pub updated_at: i64,
}
