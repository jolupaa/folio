//! Conversión folio_core::model → DTOs de `api::types` (estructuras con los mismos campos).

use crate::api::types as t;
use folio_core::model as m;

macro_rules! conv_struct {
    ($from:ty => $to:ty { $($f:ident),* $(,)? }) => {
        impl From<$from> for $to {
            fn from(v: $from) -> Self { Self { $($f: v.$f.into()),* } }
        }
    };
}
macro_rules! conv_enum {
    ($a:ty, $b:ty { $($v:ident),* $(,)? }) => {
        impl From<$a> for $b { fn from(v: $a) -> Self { match v { $(<$a>::$v => <$b>::$v),* } } }
        impl From<$b> for $a { fn from(v: $b) -> Self { match v { $(<$b>::$v => <$a>::$v),* } } }
    };
}

conv_enum!(m::NoteKind, t::NoteKind { Text, Board });
conv_enum!(m::NoteListScope, t::NoteListScope { Inbox, Folder, All, Pinned });
conv_enum!(m::TrashKind, t::TrashKind { Note, Folder });
conv_enum!(m::MatchField, t::MatchField { Title, Body, Attachment });
conv_enum!(m::AttachmentKind, t::AttachmentKind { Image, Pdf });
conv_enum!(m::TextSource, t::TextSource { None, PdfText, Ocr, OcrEdited });

conv_struct!(m::StorageInfo => t::StorageInfo { free_bytes, total_bytes, database_bytes, files_bytes, models_bytes });
conv_struct!(m::Folder => t::Folder { id, parent_id, name, sort_order, note_count, total_note_count, child_count, created_at, updated_at });
conv_struct!(m::SaveResult => t::SaveResult { revision, updated_at, conflict });
conv_struct!(m::LibraryCounts => t::LibraryCounts { inbox, all, pinned, trash, study_items });
conv_struct!(m::TextMatch => t::TextMatch { start, end });
conv_struct!(m::Attachment => t::Attachment { id, note_id, kind, file_name, mime, path, size_bytes, width, height, page_count, created_at });
conv_struct!(m::OcrLine => t::OcrLine { text, x, y, w, h, confidence });
conv_struct!(t::OcrLine => m::OcrLine { text, x, y, w, h, confidence });
conv_struct!(t::CropRect => m::CropRect { x, y, w, h });
conv_struct!(m::ImageInfo => t::ImageInfo { path, width, height, size_bytes });
conv_struct!(m::Board => t::Board { note_id, title, scene_json, updated_at });

pub fn vec<A, B: From<A>>(v: Vec<A>) -> Vec<B> {
    v.into_iter().map(B::from).collect()
}

impl From<m::NoteSummary> for t::NoteSummary {
    fn from(v: m::NoteSummary) -> Self {
        Self {
            id: v.id, folder_id: v.folder_id, kind: v.kind.into(), title: v.title, preview: v.preview,
            pinned: v.pinned, attachment_count: v.attachment_count, thumbnail_path: v.thumbnail_path,
            created_at: v.created_at, updated_at: v.updated_at,
        }
    }
}
impl From<m::Note> for t::Note {
    fn from(v: m::Note) -> Self {
        Self {
            id: v.id, folder_id: v.folder_id, kind: v.kind.into(), title: v.title, body_json: v.body_json,
            pinned: v.pinned, created_at: v.created_at, updated_at: v.updated_at, revision: v.revision,
            attachments: vec(v.attachments),
        }
    }
}
impl From<m::TrashItem> for t::TrashItem {
    fn from(v: m::TrashItem) -> Self {
        Self {
            kind: v.kind.into(), id: v.id, title: v.title, note_kind: v.note_kind.map(Into::into),
            original_location: v.original_location, contained_notes: v.contained_notes,
            deleted_at: v.deleted_at, days_left: v.days_left,
        }
    }
}
impl From<m::SearchHit> for t::SearchHit {
    fn from(v: m::SearchHit) -> Self {
        Self {
            note_id: v.note_id, note_kind: v.note_kind.into(), title: v.title, snippet: v.snippet,
            matched_in: v.matched_in.into(), location: v.location, page_id: v.page_id,
            attachment_id: v.attachment_id, attachment_name: v.attachment_name, page_index: v.page_index,
            updated_at: v.updated_at, score: v.score,
        }
    }
}
impl From<m::SearchResults> for t::SearchResults {
    fn from(v: m::SearchResults) -> Self {
        Self { query: v.query, hits: vec(v.hits), elapsed_ms: v.elapsed_ms }
    }
}
impl From<m::AttachmentPage> for t::AttachmentPage {
    fn from(v: m::AttachmentPage) -> Self {
        Self {
            id: v.id, attachment_id: v.attachment_id, page_index: v.page_index, image_path: v.image_path,
            text: v.text, text_source: v.text_source.into(), ocr_engine: v.ocr_engine,
            ocr_confidence: v.ocr_confidence, lines: vec(v.lines), materialized: v.materialized,
        }
    }
}
impl From<m::PdfImportResult> for t::PdfImportResult {
    fn from(v: m::PdfImportResult) -> Self {
        Self { attachment: v.attachment.into(), pages: vec(v.pages), pages_needing_ocr: v.pages_needing_ocr }
    }
}
impl From<t::OcrPageInput> for m::OcrPageInput {
    fn from(v: t::OcrPageInput) -> Self {
        Self { image_path: v.image_path, text: v.text, engine: v.engine, confidence: v.confidence, lines: vec(v.lines), edited: v.edited }
    }
}
impl From<t::SearchScope> for m::SearchScope {
    fn from(v: t::SearchScope) -> Self {
        match (v.kind, v.id) {
            (t::SearchScopeKind::Folder, Some(id)) => m::SearchScope::Folder(id),
            (t::SearchScopeKind::Note, Some(id)) => m::SearchScope::Note(id),
            _ => m::SearchScope::Library,
        }
    }
}

// ─────────────────────────── IA ───────────────────────────
use folio_ai::types as a;

conv_enum!(a::ScopeKind, t::ScopeKind { Note, Notes, Folder, Library });
conv_enum!(a::AiEventKind, t::AiEventKind { Started, Progress, Sources, Token, Done, Cancelled, Error });
conv_enum!(a::ModelRole, t::ModelRole { Llm, Embedding });
conv_enum!(a::ModelStatus, t::ModelStatus { NotInstalled, Downloading, Paused, Verifying, Installed, Failed });
conv_enum!(a::DownloadEventKind, t::DownloadEventKind { Started, Progress, Verifying, Completed, Paused, Cancelled, Failed });
conv_enum!(a::StudyKind, t::StudyKind { Summary, Outline, KeyConcepts, Flashcards, Quiz });
conv_enum!(a::DetailLevel, t::DetailLevel { Brief, Detailed });
conv_enum!(a::QuizMix, t::QuizMix { MultipleChoice, OpenEnded, Mixed });
conv_enum!(a::ChatRole, t::ChatRole { User, Assistant });

conv_struct!(a::AiScope => t::AiScope { kind, ids });
conv_struct!(t::AiScope => a::AiScope { kind, ids });
conv_struct!(a::ScopeSummary => t::ScopeSummary { label, note_count, chunk_count, embedded_chunk_count, pending_notes });
conv_struct!(a::AiStatus => t::AiStatus { active_llm_id, llm_installed, llm_loaded, embedding_installed, device_supported, unavailable_reason });
conv_struct!(a::IndexStatus => t::IndexStatus { total_notes, pending_notes, chunk_count, embedded_chunk_count, embedding_model_id, running, last_error });
conv_struct!(a::Citation => t::Citation { n, note_id, note_title, location, chunk_id, block_id, page_id, attachment_name, page_index, snippet, exists });
conv_struct!(a::ModelInfo => t::ModelInfo { id, display_name, tier_label, role, family, quantization, file_name, url, sha256, size_bytes, license, license_url, context_length, min_ram_bytes, description, status, downloaded_bytes, error, is_active, supported_on_device });
conv_struct!(a::DeviceInfo => t::DeviceInfo { platform, arch, total_ram_bytes, available_ram_bytes, cpu_cores, free_storage_bytes, recommended_llm_id, can_run_any_llm, notes });
conv_struct!(a::DownloadEvent => t::DownloadEvent { model_id, kind, downloaded_bytes, total_bytes, bytes_per_second, message });
conv_struct!(t::StudyOptions => a::StudyOptions { detail, count, quiz_mix, title });
conv_struct!(a::SourceRef => t::SourceRef { note_id, title, exists });
conv_struct!(a::StudyItemSummary => t::StudyItemSummary { id, kind, title, scope_label, source_count, item_count, created_at, updated_at });
conv_struct!(a::QuizAttempt => t::QuizAttempt { id, study_id, answers_json, score, created_at, completed_at });
conv_struct!(a::ChatThreadSummary => t::ChatThreadSummary { id, title, scope_label, message_count, updated_at });

impl From<a::AiEvent> for t::AiEvent {
    fn from(v: a::AiEvent) -> Self {
        Self { task_id: v.task_id, kind: v.kind.into(), text: v.text, progress: v.progress, citations: vec(v.citations), result_id: v.result_id, thread_id: v.thread_id, insufficient: v.insufficient }
    }
}
impl From<a::StudyItem> for t::StudyItem {
    fn from(v: a::StudyItem) -> Self {
        Self { id: v.id, kind: v.kind.into(), title: v.title, scope: v.scope.into(), scope_label: v.scope_label, content_json: v.content_json, model_id: v.model_id, sources: vec(v.sources), created_at: v.created_at, updated_at: v.updated_at }
    }
}
impl From<a::ChatMessage> for t::ChatMessage {
    fn from(v: a::ChatMessage) -> Self {
        Self { id: v.id, thread_id: v.thread_id, role: v.role.into(), content: v.content, citations: vec(v.citations), insufficient: v.insufficient, status: v.status, created_at: v.created_at }
    }
}
impl From<a::ChatThread> for t::ChatThread {
    fn from(v: a::ChatThread) -> Self {
        Self { id: v.id, title: v.title, scope: v.scope.into(), scope_label: v.scope_label, messages: vec(v.messages), created_at: v.created_at, updated_at: v.updated_at }
    }
}
