-- Folio · esquema v1
-- Convenciones: ids TEXT (UUID v4 en minúsculas); tiempos INTEGER en milisegundos Unix (UTC);
-- borrado lógico con deleted_at (papelera); JSON en columnas TEXT.
-- PRAGMA foreign_keys = ON y journal_mode = WAL se fijan al abrir la conexión (no aquí).

-- ───────────────────────── Organización ─────────────────────────
CREATE TABLE folders (
  id          TEXT PRIMARY KEY,
  parent_id   TEXT REFERENCES folders(id) ON DELETE CASCADE,   -- NULL = carpeta de primer nivel
  name        TEXT NOT NULL CHECK (length(trim(name)) > 0),
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER                                            -- NOT NULL = en papelera
);
CREATE INDEX idx_folders_parent ON folders(parent_id);
CREATE INDEX idx_folders_deleted ON folders(deleted_at);

-- Notas de texto y pizarras comparten tabla: ambas viven en carpetas, se fijan y van a la papelera.
CREATE TABLE notes (
  id          TEXT PRIMARY KEY,
  folder_id   TEXT REFERENCES folders(id) ON DELETE SET NULL,   -- NULL = bandeja general «Notas»
  kind        TEXT NOT NULL CHECK (kind IN ('text','board')),
  title       TEXT NOT NULL DEFAULT '',
  body        TEXT NOT NULL DEFAULT '[]',   -- text: JSON de bloques (ver contrato); board: '[]'
  plain_text  TEXT NOT NULL DEFAULT '',     -- derivado en Rust (bloques o texto de pizarra)
  pinned      INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER,
  revision    INTEGER NOT NULL DEFAULT 0    -- se incrementa en cada guardado (control optimista)
);
CREATE INDEX idx_notes_folder ON notes(folder_id, deleted_at, pinned, updated_at);
CREATE INDEX idx_notes_deleted ON notes(deleted_at);

-- ───────────────────────── Adjuntos y páginas ─────────────────────────
CREATE TABLE attachments (
  id          TEXT PRIMARY KEY,
  note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('image','pdf')),
  file_name   TEXT NOT NULL,
  mime        TEXT NOT NULL,
  rel_path    TEXT NOT NULL,                -- relativo a <data_dir>/files
  size_bytes  INTEGER NOT NULL,
  sha256      TEXT NOT NULL,
  width       INTEGER,
  height      INTEGER,
  page_count  INTEGER NOT NULL DEFAULT 1,
  created_at  INTEGER NOT NULL
);
CREATE INDEX idx_attachments_note ON attachments(note_id);

-- Una fila por página (imagen = 1 página). Conserva el vínculo texto ↔ imagen/página original.
CREATE TABLE attachment_pages (
  id              TEXT PRIMARY KEY,
  attachment_id   TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
  page_index      INTEGER NOT NULL,          -- 0-based
  image_rel_path  TEXT,                      -- foto o render de página PDF usado para OCR
  text            TEXT NOT NULL DEFAULT '',
  text_source     TEXT NOT NULL DEFAULT 'none'
                  CHECK (text_source IN ('none','pdf_text','ocr','ocr_edited')),
  ocr_engine      TEXT,                      -- 'apple_vision' | 'mlkit_latin' | ...
  ocr_confidence  REAL,                      -- media 0..1 si el motor la ofrece
  ocr_layout      TEXT,                      -- JSON [{text,x,y,w,h,conf}] coords normalizadas 0..1
  materialized    INTEGER NOT NULL DEFAULT 0, -- 1 = su texto está copiado en el cuerpo de la nota
  updated_at      INTEGER NOT NULL,
  UNIQUE (attachment_id, page_index)
);

-- ───────────────────────── Pizarras ─────────────────────────
CREATE TABLE boards (
  note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
  scene       TEXT NOT NULL DEFAULT '{"version":1,"elements":[]}',
  updated_at  INTEGER NOT NULL
);

-- ───────────────────────── Búsqueda textual ─────────────────────────
-- Un documento de búsqueda por nota (título + texto) y otro por página de adjunto (OCR / texto PDF).
CREATE TABLE search_docs (
  id       INTEGER PRIMARY KEY,               -- = rowid de search_fts (estable)
  note_id  TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  page_id  TEXT REFERENCES attachment_pages(id) ON DELETE CASCADE,
  UNIQUE (note_id, page_id)
);
CREATE VIRTUAL TABLE search_fts USING fts5(
  title, body,
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3 4'
);
-- UNIQUE (note_id, page_id) no impide duplicados cuando page_id es NULL (NULL ≠ NULL en SQLite):
-- índice parcial que garantiza un único documento de nota por nota.
CREATE UNIQUE INDEX idx_search_docs_note_doc ON search_docs(note_id) WHERE page_id IS NULL;
CREATE INDEX idx_search_docs_page ON search_docs(page_id);
-- Al borrar un documento (también por CASCADE desde notes / attachment_pages) se borra su fila FTS.
CREATE TRIGGER search_docs_ad AFTER DELETE ON search_docs BEGIN
  DELETE FROM search_fts WHERE rowid = old.id;
END;

-- ───────────────────────── Índice para IA (RAG) ─────────────────────────
CREATE TABLE chunks (
  id              INTEGER PRIMARY KEY,
  note_id         TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  page_id         TEXT REFERENCES attachment_pages(id) ON DELETE CASCADE,
  ord             INTEGER NOT NULL,
  heading         TEXT,                      -- ruta de encabezados para contexto
  block_id        TEXT,                      -- primer bloque del fragmento (navegación)
  text            TEXT NOT NULL,
  char_start      INTEGER NOT NULL,
  char_end        INTEGER NOT NULL,
  hash            TEXT NOT NULL,
  token_estimate  INTEGER NOT NULL
);
CREATE INDEX idx_chunks_note ON chunks(note_id, page_id, ord);
CREATE VIRTUAL TABLE chunks_fts USING fts5(
  text, content = 'chunks', content_rowid = 'id',
  tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
  INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
  INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER chunks_au AFTER UPDATE OF text ON chunks BEGIN
  INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
  INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
END;

CREATE TABLE chunk_embeddings (
  chunk_id  INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  model_id  TEXT NOT NULL,
  dim       INTEGER NOT NULL,
  vec       BLOB NOT NULL                     -- f32 little-endian, normalizado L2
);

-- Estado del índice por nota: el indexador en segundo plano procesa las filas dirty = 1.
CREATE TABLE index_state (
  note_id         TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
  content_hash    TEXT NOT NULL DEFAULT '',
  dirty           INTEGER NOT NULL DEFAULT 1,
  chunked_at      INTEGER,
  embedded_model  TEXT,
  error           TEXT
);

-- ───────────────────────── Estudio ─────────────────────────
CREATE TABLE study_items (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('summary','outline','key_concepts','flashcards','quiz')),
  title       TEXT NOT NULL,
  scope       TEXT NOT NULL,                 -- JSON {"kind":"note|notes|folder|library","ids":[...]}
  content     TEXT NOT NULL,                 -- JSON según kind (ver contrato)
  model_id    TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
-- Sin FK a notes: el material sobrevive aunque la fuente se borre (se mostrará «fuente eliminada»).
CREATE TABLE study_item_sources (
  study_id  TEXT NOT NULL REFERENCES study_items(id) ON DELETE CASCADE,
  note_id   TEXT NOT NULL,
  PRIMARY KEY (study_id, note_id)
);
CREATE TABLE quiz_attempts (
  id            TEXT PRIMARY KEY,
  study_id      TEXT NOT NULL REFERENCES study_items(id) ON DELETE CASCADE,
  answers       TEXT NOT NULL DEFAULT '[]',  -- JSON [{question_id,response,correct,score,feedback}]
  score         REAL,
  created_at    INTEGER NOT NULL,
  completed_at  INTEGER
);

CREATE TABLE chat_threads (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  scope       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE TABLE chat_messages (
  id          TEXT PRIMARY KEY,
  thread_id   TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  role        TEXT NOT NULL CHECK (role IN ('user','assistant')),
  content     TEXT NOT NULL,
  citations   TEXT NOT NULL DEFAULT '[]',
  insufficient INTEGER NOT NULL DEFAULT 0,
  status      TEXT NOT NULL DEFAULT 'done' CHECK (status IN ('done','cancelled','error')),
  created_at  INTEGER NOT NULL
);
CREATE INDEX idx_chat_messages_thread ON chat_messages(thread_id, created_at);

-- ───────────────────────── Modelos y ajustes ─────────────────────────
CREATE TABLE models (
  id                TEXT PRIMARY KEY,        -- id del catálogo
  status            TEXT NOT NULL CHECK (status IN ('downloading','paused','installed','failed')),
  downloaded_bytes  INTEGER NOT NULL DEFAULT 0,
  total_bytes       INTEGER NOT NULL,
  file_rel_path     TEXT NOT NULL,           -- relativo a <data_dir>/models
  error             TEXT,
  updated_at        INTEGER NOT NULL
);
CREATE TABLE settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
