-- Técnicas de estudio: tipo 'skill' y columna `skill` (id del catálogo de folio_ai::skills).
-- SQLite no permite cambiar un CHECK: se reconstruye la tabla (procedimiento de 12 pasos).
-- `migrate` desactiva las claves foráneas mientras dura la migración; si no, el DROP borraría en
-- cascada study_item_sources y quiz_attempts.
CREATE TABLE study_items_new (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('summary','outline','key_concepts','flashcards','quiz','skill')),
  skill       TEXT,                          -- id de la técnica; solo con kind = 'skill'
  title       TEXT NOT NULL,
  scope       TEXT NOT NULL,                 -- JSON {"kind":"note|notes|folder|library","ids":[...]}
  content     TEXT NOT NULL,                 -- JSON según kind (ver contrato)
  model_id    TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  CHECK ((kind = 'skill') = (skill IS NOT NULL))
);
INSERT INTO study_items_new(id, kind, skill, title, scope, content, model_id, created_at, updated_at)
  SELECT id, kind, NULL, title, scope, content, model_id, created_at, updated_at FROM study_items;
DROP TABLE study_items;
ALTER TABLE study_items_new RENAME TO study_items;
