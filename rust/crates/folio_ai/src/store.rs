//! Persistencia de materiales de estudio, intentos de cuestionario y conversaciones; utilidades
//! de ámbito y de citas (comprobación de que las fuentes siguen existiendo).

use crate::index::Hit;
use crate::text::snippet;
use crate::types::*;
use folio_core::scope::{folder_location, note_ids_in_scope, ScopeSpec};
use folio_core::util::{new_id, now_ms};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

pub fn scope_spec(scope: &AiScope) -> anyhow::Result<ScopeSpec> {
    let first = || scope.ids.first().cloned().ok_or_else(|| anyhow::anyhow!("Ámbito sin identificador"));
    Ok(match scope.kind {
        ScopeKind::Note => ScopeSpec::Note(first()?),
        ScopeKind::Notes => ScopeSpec::Notes(scope.ids.clone()),
        ScopeKind::Folder => ScopeSpec::Folder(first()?),
        ScopeKind::Library => ScopeSpec::Library,
    })
}

pub fn scope_label(conn: &Connection, scope: &AiScope) -> String {
    match scope.kind {
        ScopeKind::Note => "Esta nota".into(),
        ScopeKind::Notes => match scope.ids.len() {
            1 => "1 fuente".into(),
            n => format!("{n} fuentes"),
        },
        ScopeKind::Folder => scope
            .ids
            .first()
            .and_then(|id| conn.query_row("SELECT name FROM folders WHERE id = ?1", params![id], |r| r.get(0)).optional().ok().flatten())
            .unwrap_or_else(|| "Carpeta".into()),
        ScopeKind::Library => "Toda la biblioteca".into(),
    }
}

/// Nombre para títulos por defecto («Resumen · Física», «Resumen · Tema 2»).
pub fn scope_title(conn: &Connection, scope: &AiScope) -> String {
    if scope.kind == ScopeKind::Note {
        if let Some(id) = scope.ids.first() {
            let row: Option<(String, String)> = conn
                .query_row("SELECT title, plain_text FROM notes WHERE id = ?1", params![id], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()
                .ok()
                .flatten();
            if let Some((t, p)) = row {
                let d = folio_core::blocks::display_title(&t, &p);
                if !d.is_empty() {
                    return d;
                }
            }
        }
        return "Nota".into();
    }
    scope_label(conn, scope)
}

pub fn describe_scope(conn: &Connection, scope: &AiScope, embedding_model: Option<&str>) -> anyhow::Result<ScopeSummary> {
    let ids = note_ids_in_scope(conn, &scope_spec(scope)?)?;
    let (mut chunks, mut embedded, mut pending) = (0u32, 0u32, 0u32);
    let mut c = conn.prepare_cached("SELECT count(*) FROM chunks WHERE note_id = ?1")?;
    let mut e = conn.prepare_cached(
        "SELECT count(*) FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id WHERE c.note_id = ?1 AND e.model_id = ?2",
    )?;
    let mut d = conn.prepare_cached("SELECT dirty FROM index_state WHERE note_id = ?1")?;
    for id in &ids {
        chunks += c.query_row(params![id], |r| r.get::<_, u32>(0))?;
        if let Some(m) = embedding_model {
            embedded += e.query_row(params![id, m], |r| r.get::<_, u32>(0))?;
        }
        if d.query_row(params![id], |r| r.get::<_, i64>(0)).optional()?.unwrap_or(1) != 0 {
            pending += 1;
        }
    }
    Ok(ScopeSummary {
        label: scope_label(conn, scope),
        note_count: ids.len() as u32,
        chunk_count: chunks,
        embedded_chunk_count: embedded,
        pending_notes: pending,
    })
}

pub fn citation_for(conn: &Connection, n: u32, h: &Hit) -> Citation {
    Citation {
        n,
        note_id: h.note_id.clone(),
        note_title: h.note_title.clone(),
        location: folder_location(conn, h.folder_id.as_deref()).unwrap_or_default(),
        chunk_id: h.chunk_id,
        block_id: h.block_id.clone(),
        page_id: h.page_id.clone(),
        attachment_name: h.attachment_name.clone(),
        page_index: h.page_index,
        snippet: snippet(&h.text, 300),
        exists: true,
    }
}

fn source_exists(conn: &Connection, note_id: &str, page_id: Option<&str>) -> bool {
    let note: bool = conn
        .query_row("SELECT 1 FROM notes WHERE id = ?1 AND deleted_at IS NULL", params![note_id], |_| Ok(true))
        .optional()
        .ok()
        .flatten()
        .unwrap_or(false);
    match page_id {
        Some(p) if note => conn
            .query_row("SELECT 1 FROM attachment_pages WHERE id = ?1", params![p], |_| Ok(true))
            .optional()
            .ok()
            .flatten()
            .unwrap_or(false),
        _ => note,
    }
}

pub fn refresh_citations(conn: &Connection, citations: &mut [Citation]) {
    for c in citations {
        c.exists = source_exists(conn, &c.note_id, c.page_id.as_deref());
    }
}

fn refresh_content_citations(conn: &Connection, content: &str) -> String {
    let Ok(mut v) = serde_json::from_str::<Value>(content) else { return content.to_string() };
    if let Some(arr) = v.get_mut("citations").and_then(|c| c.as_array_mut()) {
        for c in arr {
            let note_id = c.get("note_id").and_then(|x| x.as_str()).unwrap_or("").to_string();
            let page_id = c.get("page_id").and_then(|x| x.as_str()).map(str::to_string);
            let exists = source_exists(conn, &note_id, page_id.as_deref());
            if let Some(o) = c.as_object_mut() {
                o.insert("exists".into(), Value::Bool(exists));
            }
        }
    }
    v.to_string()
}

// ─────────────────────────── Estudio ───────────────────────────

/// Valida el contenido según el tipo (docs/CONTRATOS.md §3).
pub fn validate_content(kind: StudyKind, content_json: &str) -> anyhow::Result<Value> {
    let v: Value = serde_json::from_str(content_json).map_err(|e| anyhow::anyhow!("Contenido no válido: {e}"))?;
    let str_field = |o: &Value, k: &str| o.get(k).and_then(|x| x.as_str()).map(|s| !s.trim().is_empty()).unwrap_or(false);
    match kind {
        StudyKind::Summary | StudyKind::Outline | StudyKind::KeyConcepts => {
            anyhow::ensure!(v.get("text").and_then(|t| t.as_str()).is_some(), "Falta el texto");
        }
        StudyKind::Flashcards => {
            let cards = v.get("cards").and_then(|c| c.as_array()).ok_or_else(|| anyhow::anyhow!("Faltan las tarjetas"))?;
            for c in cards {
                anyhow::ensure!(str_field(c, "front") && str_field(c, "back"), "Cada tarjeta necesita pregunta y respuesta");
            }
        }
        StudyKind::Quiz => {
            let qs = v.get("questions").and_then(|c| c.as_array()).ok_or_else(|| anyhow::anyhow!("Faltan las preguntas"))?;
            for q in qs {
                anyhow::ensure!(str_field(q, "question"), "Cada pregunta necesita un enunciado");
                match q.get("kind").and_then(|k| k.as_str()) {
                    Some("mcq") => {
                        let n = q.get("options").and_then(|o| o.as_array()).map(|o| o.len()).unwrap_or(0);
                        let idx = q.get("answer_index").and_then(|i| i.as_u64()).unwrap_or(u64::MAX);
                        anyhow::ensure!(n >= 2 && (idx as usize) < n, "Pregunta de opción múltiple sin opciones o sin respuesta válida");
                    }
                    Some("open") => {}
                    _ => anyhow::bail!("Tipo de pregunta desconocido"),
                }
            }
        }
    }
    Ok(v)
}

fn item_count(kind: StudyKind, content: &str) -> u32 {
    let key = match kind {
        StudyKind::Flashcards => "cards",
        StudyKind::Quiz => "questions",
        _ => return 0,
    };
    serde_json::from_str::<Value>(content)
        .ok()
        .and_then(|v| v.get(key).and_then(|a| a.as_array()).map(|a| a.len() as u32))
        .unwrap_or(0)
}

#[allow(clippy::too_many_arguments)]
pub fn insert_study_item(
    conn: &Connection,
    kind: StudyKind,
    title: &str,
    scope: &AiScope,
    content: &Value,
    model_id: Option<&str>,
    source_note_ids: &[String],
) -> anyhow::Result<String> {
    let id = new_id();
    let now = now_ms();
    conn.execute(
        "INSERT INTO study_items(id,kind,title,scope,content,model_id,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?7)",
        params![id, kind.as_db(), title, serde_json::to_string(scope)?, content.to_string(), model_id, now],
    )?;
    for n in source_note_ids {
        conn.execute("INSERT OR IGNORE INTO study_item_sources(study_id, note_id) VALUES (?1, ?2)", params![id, n])?;
    }
    Ok(id)
}

pub fn list_study_items(conn: &Connection, note_id: Option<&str>) -> anyhow::Result<Vec<StudyItemSummary>> {
    let sql = "SELECT s.id, s.kind, s.title, s.scope, s.content, s.created_at, s.updated_at,
                 (SELECT count(*) FROM study_item_sources x WHERE x.study_id = s.id)
               FROM study_items s
               WHERE ?1 IS NULL OR EXISTS (SELECT 1 FROM study_item_sources x WHERE x.study_id = s.id AND x.note_id = ?1)
               ORDER BY s.updated_at DESC";
    let mut st = conn.prepare_cached(sql)?;
    let rows = st.query_map(params![note_id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, u32>(7)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (id, kind, title, scope, content, created_at, updated_at, source_count) = row?;
        let Some(kind) = StudyKind::from_db(&kind) else { continue };
        let scope_label = serde_json::from_str::<AiScope>(&scope).map(|s| scope_label(conn, &s)).unwrap_or_default();
        out.push(StudyItemSummary {
            id,
            kind,
            title,
            scope_label,
            source_count,
            item_count: item_count(kind, &content),
            created_at,
            updated_at,
        });
    }
    Ok(out)
}

pub fn get_study_item(conn: &Connection, id: &str) -> anyhow::Result<StudyItem> {
    let row: Option<(String, String, String, String, Option<String>, i64, i64)> = conn
        .query_row(
            "SELECT kind, title, scope, content, model_id, created_at, updated_at FROM study_items WHERE id = ?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
        )
        .optional()?;
    let (kind, title, scope, content, model_id, created_at, updated_at) =
        row.ok_or_else(|| anyhow::anyhow!("El material de estudio ya no existe"))?;
    let kind = StudyKind::from_db(&kind).ok_or_else(|| anyhow::anyhow!("Tipo de material desconocido"))?;
    let scope: AiScope = serde_json::from_str(&scope).unwrap_or(AiScope { kind: ScopeKind::Library, ids: vec![] });
    let mut st = conn.prepare_cached(
        "SELECT x.note_id, n.title, n.plain_text, n.deleted_at FROM study_item_sources x
         LEFT JOIN notes n ON n.id = x.note_id WHERE x.study_id = ?1",
    )?;
    let sources = st
        .query_map(params![id], |r| {
            let title: Option<String> = r.get(1)?;
            let plain: Option<String> = r.get(2)?;
            let deleted: Option<i64> = r.get(3)?;
            let exists = title.is_some() && deleted.is_none();
            let shown = folio_core::blocks::display_title(title.as_deref().unwrap_or(""), plain.as_deref().unwrap_or(""));
            Ok(SourceRef {
                note_id: r.get(0)?,
                title: if title.is_none() { "Fuente eliminada".into() } else if shown.is_empty() { "Sin título".into() } else { shown },
                exists,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(StudyItem {
        id: id.to_string(),
        kind,
        title,
        scope_label: scope_label(conn, &scope),
        scope,
        content_json: refresh_content_citations(conn, &content),
        model_id,
        sources,
        created_at,
        updated_at,
    })
}

pub fn update_study_item(conn: &Connection, id: &str, title: &str, content_json: &str) -> anyhow::Result<StudyItem> {
    let current = get_study_item(conn, id)?;
    let v = validate_content(current.kind, content_json)?;
    anyhow::ensure!(!title.trim().is_empty(), "El título no puede estar vacío");
    conn.execute(
        "UPDATE study_items SET title = ?2, content = ?3, updated_at = ?4 WHERE id = ?1",
        params![id, title.trim(), v.to_string(), now_ms()],
    )?;
    get_study_item(conn, id)
}

pub fn delete_study_item(conn: &Connection, id: &str) -> anyhow::Result<()> {
    conn.execute("DELETE FROM study_items WHERE id = ?1", params![id])?;
    Ok(())
}

pub fn save_quiz_attempt(conn: &Connection, study_id: &str, answers_json: &str, score: Option<f64>, completed: bool) -> anyhow::Result<QuizAttempt> {
    let v: Value = serde_json::from_str(answers_json).map_err(|e| anyhow::anyhow!("Respuestas no válidas: {e}"))?;
    anyhow::ensure!(v.is_array(), "Respuestas no válidas");
    let now = now_ms();
    let a = QuizAttempt {
        id: new_id(),
        study_id: study_id.to_string(),
        answers_json: v.to_string(),
        score,
        created_at: now,
        completed_at: completed.then_some(now),
    };
    conn.execute(
        "INSERT INTO quiz_attempts(id,study_id,answers,score,created_at,completed_at) VALUES (?1,?2,?3,?4,?5,?6)",
        params![a.id, a.study_id, a.answers_json, a.score, a.created_at, a.completed_at],
    )?;
    Ok(a)
}

pub fn list_quiz_attempts(conn: &Connection, study_id: &str) -> anyhow::Result<Vec<QuizAttempt>> {
    let mut st = conn.prepare_cached(
        "SELECT id, study_id, answers, score, created_at, completed_at FROM quiz_attempts WHERE study_id = ?1 ORDER BY created_at DESC",
    )?;
    let v = st
        .query_map(params![study_id], |r| {
            Ok(QuizAttempt {
                id: r.get(0)?,
                study_id: r.get(1)?,
                answers_json: r.get(2)?,
                score: r.get(3)?,
                created_at: r.get(4)?,
                completed_at: r.get(5)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(v)
}

// ─────────────────────────── Conversaciones ───────────────────────────

pub fn create_thread(conn: &Connection, title: &str, scope: &AiScope) -> anyhow::Result<String> {
    let id = new_id();
    let now = now_ms();
    conn.execute(
        "INSERT INTO chat_threads(id,title,scope,created_at,updated_at) VALUES (?1,?2,?3,?4,?4)",
        params![id, title, serde_json::to_string(scope)?, now],
    )?;
    Ok(id)
}

pub fn thread_scope(conn: &Connection, thread_id: &str) -> anyhow::Result<AiScope> {
    let s: Option<String> =
        conn.query_row("SELECT scope FROM chat_threads WHERE id = ?1", params![thread_id], |r| r.get(0)).optional()?;
    let s = s.ok_or_else(|| anyhow::anyhow!("La conversación ya no existe"))?;
    Ok(serde_json::from_str(&s)?)
}

#[allow(clippy::too_many_arguments)]
pub fn add_message(
    conn: &Connection,
    thread_id: &str,
    role: ChatRole,
    content: &str,
    citations: &[Citation],
    insufficient: bool,
    status: &str,
) -> anyhow::Result<String> {
    let id = new_id();
    let now = now_ms();
    conn.execute(
        "INSERT INTO chat_messages(id,thread_id,role,content,citations,insufficient,status,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        params![
            id,
            thread_id,
            if role == ChatRole::User { "user" } else { "assistant" },
            content,
            serde_json::to_string(citations)?,
            insufficient as i64,
            status,
            now
        ],
    )?;
    conn.execute("UPDATE chat_threads SET updated_at = ?2 WHERE id = ?1", params![thread_id, now])?;
    Ok(id)
}

pub fn thread_messages(conn: &Connection, thread_id: &str) -> anyhow::Result<Vec<ChatMessage>> {
    let mut st = conn.prepare_cached(
        "SELECT id, role, content, citations, insufficient, status, created_at FROM chat_messages
         WHERE thread_id = ?1 ORDER BY created_at, rowid",
    )?;
    let mut msgs = st
        .query_map(params![thread_id], |r| {
            let role: String = r.get(1)?;
            let cites: String = r.get(3)?;
            Ok(ChatMessage {
                id: r.get(0)?,
                thread_id: thread_id.to_string(),
                role: if role == "user" { ChatRole::User } else { ChatRole::Assistant },
                content: r.get(2)?,
                citations: serde_json::from_str(&cites).unwrap_or_default(),
                insufficient: r.get::<_, i64>(4)? != 0,
                status: r.get(5)?,
                created_at: r.get(6)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for m in &mut msgs {
        refresh_citations(conn, &mut m.citations);
    }
    Ok(msgs)
}

pub fn get_thread(conn: &Connection, thread_id: &str) -> anyhow::Result<ChatThread> {
    let row: Option<(String, String, i64, i64)> = conn
        .query_row("SELECT title, scope, created_at, updated_at FROM chat_threads WHERE id = ?1", params![thread_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .optional()?;
    let (title, scope, created_at, updated_at) = row.ok_or_else(|| anyhow::anyhow!("La conversación ya no existe"))?;
    let scope: AiScope = serde_json::from_str(&scope).unwrap_or(AiScope { kind: ScopeKind::Library, ids: vec![] });
    Ok(ChatThread {
        id: thread_id.to_string(),
        title,
        scope_label: scope_label(conn, &scope),
        scope,
        messages: thread_messages(conn, thread_id)?,
        created_at,
        updated_at,
    })
}

pub fn list_threads(conn: &Connection) -> anyhow::Result<Vec<ChatThreadSummary>> {
    let mut st = conn.prepare_cached(
        "SELECT t.id, t.title, t.scope, t.updated_at, (SELECT count(*) FROM chat_messages m WHERE m.thread_id = t.id)
         FROM chat_threads t ORDER BY t.updated_at DESC",
    )?;
    let rows = st.query_map([], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?, r.get::<_, u32>(4)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (id, title, scope, updated_at, message_count) = row?;
        let scope_label = serde_json::from_str::<AiScope>(&scope).map(|s| scope_label(conn, &s)).unwrap_or_default();
        out.push(ChatThreadSummary { id, title, scope_label, message_count, updated_at });
    }
    Ok(out)
}

pub fn rename_thread(conn: &Connection, thread_id: &str, title: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!title.trim().is_empty(), "El título no puede estar vacío");
    conn.execute("UPDATE chat_threads SET title = ?2 WHERE id = ?1", params![thread_id, title.trim()])?;
    Ok(())
}

pub fn delete_thread(conn: &Connection, thread_id: &str) -> anyhow::Result<()> {
    conn.execute("DELETE FROM chat_threads WHERE id = ?1", params![thread_id])?;
    Ok(())
}
