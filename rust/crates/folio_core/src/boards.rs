//! Pizarras: escena JSON (docs/CONTRATOS.md §2). Rust valida la estructura mínima, guarda la
//! cadena tal cual y deriva el texto plano de los elementos `text` en orden de lectura.

use crate::model::{Board, NoteKind, EMPTY_SCENE};
use crate::notes::{ensure_attachments_owned, note_meta, MAX_TITLE_CHARS};
use crate::search_index;
use crate::util::{now_ms, single_line};
use crate::Core;
use anyhow::{anyhow, bail};
use rusqlite::{params, OptionalExtension};
use serde_json::Value;

/// Valida la escena: objeto con `version` entera ≥ 1 y `elements` array de objetos con `type`.
pub fn validate_scene(scene_json: &str) -> anyhow::Result<Value> {
    let v: Value =
        serde_json::from_str(scene_json).map_err(|e| anyhow!("Escena de pizarra no válida: {e}"))?;
    let obj = v.as_object().ok_or_else(|| anyhow!("Escena de pizarra no válida: no es un objeto"))?;
    match obj.get("version").and_then(Value::as_u64) {
        Some(n) if n >= 1 => {}
        _ => bail!("Escena de pizarra no válida: falta «version»"),
    }
    let elements = obj
        .get("elements")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("Escena de pizarra no válida: falta «elements»"))?;
    for (i, e) in elements.iter().enumerate() {
        if e.get("type").and_then(Value::as_str).is_none() {
            bail!("Escena de pizarra no válida: el elemento {i} no tiene «type»");
        }
    }
    Ok(v)
}

fn num(e: &Value, key: &str) -> f64 {
    e.get(key).and_then(Value::as_f64).filter(|v| v.is_finite()).unwrap_or(0.0)
}

/// Texto de los elementos `text` ordenados por (y, x): de arriba abajo, de izquierda a derecha.
pub fn scene_plain_text(scene: &Value) -> String {
    let Some(elements) = scene.get("elements").and_then(Value::as_array) else {
        return String::new();
    };
    let mut texts: Vec<(f64, f64, &str)> = elements
        .iter()
        .filter(|e| e.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|e| {
            let t = e.get("text").and_then(Value::as_str)?.trim();
            (!t.is_empty()).then(|| (num(e, "y"), num(e, "x"), t))
        })
        .collect();
    texts.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.total_cmp(&b.1)));
    texts.iter().map(|(_, _, t)| *t).collect::<Vec<_>>().join("\n")
}

/// Ids de adjuntos usados por elementos `image`.
pub fn scene_attachment_ids(scene: &Value) -> Vec<String> {
    scene
        .get("elements")
        .and_then(Value::as_array)
        .map(|els| {
            els.iter()
                .filter(|e| e.get("type").and_then(Value::as_str) == Some("image"))
                .filter_map(|e| e.get("attachment_id").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

impl Core {
    pub fn get_board(&self, note_id: &str) -> anyhow::Result<Board> {
        let conn = self.db.read();
        let meta = note_meta(&conn, note_id)?;
        if meta.kind != NoteKind::Board {
            bail!("La nota no es una pizarra");
        }
        let title: String =
            conn.query_row("SELECT title FROM notes WHERE id = ?1", params![note_id], |r| r.get(0))?;
        let scene: Option<(String, i64)> = conn
            .query_row(
                "SELECT scene, updated_at FROM boards WHERE note_id = ?1",
                params![note_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let (scene_json, updated_at) = scene.unwrap_or_else(|| (EMPTY_SCENE.to_string(), meta.updated_at));
        Ok(Board { note_id: note_id.to_string(), title, scene_json, updated_at })
    }

    /// Guarda la escena y el título, deriva el texto para búsqueda e IA. Devuelve `updated_at`.
    pub fn save_board(&self, note_id: &str, title: &str, scene_json: &str) -> anyhow::Result<i64> {
        let scene = validate_scene(scene_json)?;
        let title = single_line(title, MAX_TITLE_CHARS);
        let plain = scene_plain_text(&scene);

        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let meta = note_meta(&tx, note_id)?;
        if meta.kind != NoteKind::Board {
            bail!("La nota no es una pizarra");
        }
        let current: Option<(String, String)> = tx
            .query_row(
                "SELECT n.title, b.scene FROM notes n JOIN boards b ON b.note_id = n.id WHERE n.id = ?1",
                params![note_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((t, s)) = &current {
            if *t == title && s == scene_json {
                return Ok(meta.updated_at);
            }
        }
        ensure_attachments_owned(&tx, note_id, &scene_attachment_ids(&scene))?;
        let now = now_ms().max(meta.updated_at);
        tx.execute(
            "UPDATE notes SET title = ?2, plain_text = ?3, updated_at = ?4, revision = revision + 1
             WHERE id = ?1",
            params![note_id, title, plain, now],
        )?;
        tx.execute(
            "INSERT INTO boards(note_id, scene, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(note_id) DO UPDATE SET scene = excluded.scene, updated_at = excluded.updated_at",
            params![note_id, scene_json, now],
        )?;
        search_index::sync_note_doc(&tx, note_id)?;
        search_index::mark_dirty(&tx, &[note_id])?;
        tx.commit()?;
        drop(conn);
        self.db.signal().bump();
        Ok(now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_derives_text_in_reading_order() {
        assert!(validate_scene("[]").is_err());
        assert!(validate_scene(r#"{"elements":[]}"#).is_err());
        assert!(validate_scene(r#"{"version":1}"#).is_err());
        assert!(validate_scene(r#"{"version":1,"elements":[{"id":"x"}]}"#).is_err());
        assert!(validate_scene(EMPTY_SCENE).is_ok());
        let scene = validate_scene(
            r#"{"version":1,"elements":[
                {"id":"t3","type":"text","x":10,"y":300,"text":"Abajo"},
                {"id":"s1","type":"stroke","points":[1,2,0.5]},
                {"id":"t2","type":"text","x":200,"y":50,"text":"Arriba derecha"},
                {"id":"t1","type":"text","x":20,"y":50,"text":"Arriba izquierda"},
                {"id":"t0","type":"text","x":0,"y":0,"text":"   "},
                {"id":"i1","type":"image","x":0,"y":0,"w":1,"h":1,"attachment_id":"att-1"}
            ]}"#,
        )
        .unwrap();
        assert_eq!(scene_plain_text(&scene), "Arriba izquierda\nArriba derecha\nAbajo");
        assert_eq!(scene_attachment_ids(&scene), vec!["att-1".to_string()]);
    }
}
