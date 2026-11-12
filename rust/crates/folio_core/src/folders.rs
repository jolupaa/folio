//! Carpetas: árbol con borrado lógico, contadores y detección de ciclos.

use crate::model::{Folder, LibraryCounts};
use crate::search_index;
use crate::text_find::fold;
use crate::util::{now_ms, single_line};
use crate::Core;
use anyhow::{anyhow, bail};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;

/// Longitud máxima del nombre de una carpeta.
pub const MAX_FOLDER_NAME_CHARS: usize = 120;

pub(crate) fn validate_folder_name(name: &str) -> anyhow::Result<String> {
    let n = single_line(name, MAX_FOLDER_NAME_CHARS);
    if n.is_empty() {
        bail!("El nombre de la carpeta no puede estar vacío");
    }
    Ok(n)
}

/// Comprueba que la carpeta existe y no está en la papelera (None = bandeja «Notas», válida).
pub(crate) fn ensure_folder_usable(conn: &Connection, folder_id: Option<&str>) -> anyhow::Result<()> {
    let Some(id) = folder_id else { return Ok(()) };
    match folder_deleted_state(conn, id)? {
        None => bail!("La carpeta no existe"),
        Some(Some(_)) => bail!("La carpeta está en la papelera"),
        Some(None) => Ok(()),
    }
}

/// None = no existe; Some(None) = activa; Some(Some(t)) = en la papelera desde t.
pub(crate) fn folder_deleted_state(conn: &Connection, id: &str) -> rusqlite::Result<Option<Option<i64>>> {
    conn.prepare_cached("SELECT deleted_at FROM folders WHERE id = ?1")?
        .query_row(params![id], |r| r.get(0))
        .optional()
}

/// Ids de la carpeta y TODOS sus descendientes (borrados o no).
pub(crate) fn subtree_all(conn: &Connection, folder_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut s = conn.prepare_cached(
        "WITH RECURSIVE sub(id, depth) AS (
             SELECT id, 0 FROM folders WHERE id = ?1
             UNION
             SELECT f.id, sub.depth + 1 FROM folders f JOIN sub ON f.parent_id = sub.id
             WHERE sub.depth < 256
         )
         SELECT DISTINCT id FROM sub",
    )?;
    let v = s.query_map(params![folder_id], |r| r.get(0))?.collect();
    v
}

/// Ancestros de una carpeta (desde el padre hacia la raíz), con su `deleted_at`.
pub(crate) fn ancestors(
    conn: &Connection,
    folder_id: &str,
) -> rusqlite::Result<Vec<(String, Option<i64>)>> {
    let mut out = Vec::new();
    let mut s = conn.prepare_cached("SELECT parent_id FROM folders WHERE id = ?1")?;
    let mut d = conn.prepare_cached("SELECT deleted_at FROM folders WHERE id = ?1")?;
    let mut current = folder_id.to_string();
    for _ in 0..256 {
        let parent: Option<Option<String>> =
            s.query_row(params![current], |r| r.get(0)).optional()?;
        let Some(Some(p)) = parent else { break };
        if p == folder_id || out.iter().any(|(id, _)| id == &p) {
            break; // ciclo corrupto
        }
        let del: Option<i64> = d.query_row(params![p], |r| r.get(0)).optional()?.flatten();
        out.push((p.clone(), del));
        current = p;
    }
    Ok(out)
}

struct FolderRow {
    id: String,
    parent_id: Option<String>,
    name: String,
    sort_order: i64,
    created_at: i64,
    updated_at: i64,
    direct: u32,
}

/// Todas las carpetas no borradas con contadores, ordenadas por (padre, sort_order, nombre).
pub(crate) fn load_active_folders(conn: &Connection) -> anyhow::Result<Vec<Folder>> {
    let mut s = conn.prepare_cached(
        "SELECT f.id, f.parent_id, f.name, f.sort_order, f.created_at, f.updated_at,
                (SELECT count(*) FROM notes n WHERE n.folder_id = f.id AND n.deleted_at IS NULL)
         FROM folders f WHERE f.deleted_at IS NULL",
    )?;
    let rows: Vec<FolderRow> = s
        .query_map([], |r| {
            Ok(FolderRow {
                id: r.get(0)?,
                parent_id: r.get(1)?,
                name: r.get(2)?,
                sort_order: r.get(3)?,
                created_at: r.get(4)?,
                updated_at: r.get(5)?,
                direct: r.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;

    let index: HashMap<&str, usize> = rows.iter().enumerate().map(|(i, r)| (r.id.as_str(), i)).collect();
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); rows.len()];
    for (i, r) in rows.iter().enumerate() {
        if let Some(&p) = r.parent_id.as_deref().and_then(|p| index.get(p)) {
            children[p].push(i);
        }
    }
    // Totales recursivos (DFS iterativo en postorden, robusto ante ciclos corruptos).
    let n = rows.len();
    let mut state = vec![0u8; n]; // 0 = pendiente, 1 = en curso, 2 = calculado
    let mut totals = vec![0u32; n];
    for start in 0..n {
        if state[start] != 0 {
            continue;
        }
        let mut stack = vec![(start, false)];
        while let Some((i, expanded)) = stack.pop() {
            if expanded {
                let sub: u32 =
                    children[i].iter().filter(|&&c| state[c] == 2).map(|&c| totals[c]).sum();
                totals[i] = rows[i].direct + sub;
                state[i] = 2;
                continue;
            }
            if state[i] != 0 {
                continue;
            }
            state[i] = 1;
            stack.push((i, true));
            for &c in &children[i] {
                if state[c] == 0 {
                    stack.push((c, false));
                }
            }
        }
    }
    let mut out: Vec<(Folder, String)> = rows
        .iter()
        .enumerate()
        .map(|(i, r)| {
            (
                Folder {
                    id: r.id.clone(),
                    parent_id: r.parent_id.clone(),
                    name: r.name.clone(),
                    sort_order: r.sort_order,
                    note_count: r.direct,
                    total_note_count: totals[i],
                    child_count: children[i].len() as u32,
                    created_at: r.created_at,
                    updated_at: r.updated_at,
                },
                fold(&r.name),
            )
        })
        .collect();
    out.sort_by(|(a, ka), (b, kb)| {
        a.parent_id
            .cmp(&b.parent_id)
            .then(a.sort_order.cmp(&b.sort_order))
            .then_with(|| ka.cmp(kb))
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.id.cmp(&b.id))
    });
    Ok(out.into_iter().map(|(f, _)| f).collect())
}

/// Una carpeta (borrada o no) con contadores calculados sobre su subárbol no borrado.
pub(crate) fn load_folder(conn: &Connection, id: &str) -> anyhow::Result<Folder> {
    let row = conn
        .prepare_cached(
            "SELECT id, parent_id, name, sort_order, created_at, updated_at FROM folders WHERE id = ?1",
        )?
        .query_row(params![id], |r| {
            Ok(Folder {
                id: r.get(0)?,
                parent_id: r.get(1)?,
                name: r.get(2)?,
                sort_order: r.get(3)?,
                note_count: 0,
                total_note_count: 0,
                child_count: 0,
                created_at: r.get(4)?,
                updated_at: r.get(5)?,
            })
        })
        .optional()?;
    let mut f = row.ok_or_else(|| anyhow!("La carpeta no existe"))?;
    f.note_count = conn
        .prepare_cached("SELECT count(*) FROM notes WHERE folder_id = ?1 AND deleted_at IS NULL")?
        .query_row(params![id], |r| r.get(0))?;
    f.child_count = conn
        .prepare_cached("SELECT count(*) FROM folders WHERE parent_id = ?1 AND deleted_at IS NULL")?
        .query_row(params![id], |r| r.get(0))?;
    f.total_note_count = conn
        .prepare_cached(
            "WITH RECURSIVE sub(id, depth) AS (
                 SELECT ?1, 0
                 UNION
                 SELECT c.id, sub.depth + 1 FROM folders c JOIN sub ON c.parent_id = sub.id
                 WHERE c.deleted_at IS NULL AND sub.depth < 256
             )
             SELECT count(*) FROM notes WHERE deleted_at IS NULL
               AND folder_id IN (SELECT id FROM sub)",
        )?
        .query_row(params![id], |r| r.get(0))?;
    Ok(f)
}

fn next_sort_order(conn: &Connection, parent_id: Option<&str>) -> rusqlite::Result<i64> {
    conn.prepare_cached(
        "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM folders
         WHERE parent_id IS ?1 AND deleted_at IS NULL",
    )?
    .query_row(params![parent_id], |r| r.get(0))
}

fn active_note_ids_in(conn: &Connection, folder_ids: &[String]) -> rusqlite::Result<Vec<String>> {
    let mut s = conn
        .prepare_cached("SELECT id FROM notes WHERE folder_id = ?1 AND deleted_at IS NULL")?;
    let mut out = Vec::new();
    for f in folder_ids {
        for id in s.query_map(params![f], |r| r.get::<_, String>(0))? {
            out.push(id?);
        }
    }
    Ok(out)
}

impl Core {
    /// Todas las carpetas no borradas, ordenadas por (parent_id, sort_order, nombre).
    pub fn list_folders(&self) -> anyhow::Result<Vec<Folder>> {
        load_active_folders(&self.db.read())
    }

    pub fn get_folder(&self, id: &str) -> anyhow::Result<Folder> {
        load_folder(&self.db.read(), id)
    }

    pub fn create_folder(&self, parent_id: Option<&str>, name: &str) -> anyhow::Result<Folder> {
        let name = validate_folder_name(name)?;
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if let Some(p) = parent_id {
            match folder_deleted_state(&tx, p)? {
                None => bail!("La carpeta superior no existe"),
                Some(Some(_)) => bail!("La carpeta superior está en la papelera"),
                Some(None) => {}
            }
        }
        let id = crate::util::new_id();
        let now = now_ms();
        let order = next_sort_order(&tx, parent_id)?;
        tx.execute(
            "INSERT INTO folders(id, parent_id, name, sort_order, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![id, parent_id, name, order, now],
        )?;
        tx.commit()?;
        load_folder(&conn, &id)
    }

    pub fn rename_folder(&self, id: &str, name: &str) -> anyhow::Result<Folder> {
        let name = validate_folder_name(name)?;
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_folder_usable(&tx, Some(id))?;
        tx.execute(
            "UPDATE folders SET name = ?2, updated_at = ?3 WHERE id = ?1",
            params![id, name, now_ms()],
        )?;
        tx.commit()?;
        load_folder(&conn, id)
    }

    /// Mueve la carpeta bajo `new_parent_id` (None = primer nivel). Error si el destino es la
    /// propia carpeta o una descendiente. Marca sus notas para reindexar (cambia el ámbito).
    pub fn move_folder(&self, id: &str, new_parent_id: Option<&str>) -> anyhow::Result<Folder> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_folder_usable(&tx, Some(id))?;
        let current_parent: Option<String> =
            tx.query_row("SELECT parent_id FROM folders WHERE id = ?1", params![id], |r| r.get(0))?;
        if current_parent.as_deref() == new_parent_id {
            drop(tx);
            return load_folder(&conn, id);
        }
        if let Some(p) = new_parent_id {
            if p == id {
                bail!("No se puede mover una carpeta dentro de sí misma");
            }
            let subtree = subtree_all(&tx, id)?;
            if subtree.iter().any(|f| f == p) {
                bail!("No se puede mover una carpeta dentro de una de sus subcarpetas");
            }
            match folder_deleted_state(&tx, p)? {
                None => bail!("La carpeta de destino no existe"),
                Some(Some(_)) => bail!("La carpeta de destino está en la papelera"),
                Some(None) => {}
            }
        }
        let order = next_sort_order(&tx, new_parent_id)?;
        tx.execute(
            "UPDATE folders SET parent_id = ?2, sort_order = ?3, updated_at = ?4 WHERE id = ?1",
            params![id, new_parent_id, order, now_ms()],
        )?;
        let subtree = subtree_all(&tx, id)?;
        let notes = active_note_ids_in(&tx, &subtree)?;
        search_index::mark_dirty(&tx, &notes)?;
        tx.commit()?;
        let folder = load_folder(&conn, id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(folder)
    }

    /// Mueve a la papelera la carpeta, su subárbol y sus notas con el MISMO `deleted_at`.
    /// Lo ya borrado conserva su fecha. Devuelve el número de notas afectadas.
    pub fn trash_folder(&self, id: &str) -> anyhow::Result<u32> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        match folder_deleted_state(&tx, id)? {
            None => bail!("La carpeta no existe"),
            Some(Some(_)) => return Ok(0),
            Some(None) => {}
        }
        let now = now_ms();
        let subtree = subtree_all(&tx, id)?;
        let notes = active_note_ids_in(&tx, &subtree)?;
        {
            let mut f = tx.prepare_cached(
                "UPDATE folders SET deleted_at = ?2 WHERE id = ?1 AND deleted_at IS NULL",
            )?;
            for fid in &subtree {
                f.execute(params![fid, now])?;
            }
            let mut n = tx.prepare_cached(
                "UPDATE notes SET deleted_at = ?2 WHERE id = ?1 AND deleted_at IS NULL",
            )?;
            for nid in &notes {
                n.execute(params![nid, now])?;
                search_index::remove_note_docs(&tx, nid)?;
            }
        }
        search_index::mark_dirty(&tx, &notes)?;
        tx.commit()?;
        drop(conn);
        self.db.signal().bump();
        Ok(notes.len() as u32)
    }

    /// Ruta de carpetas desde la raíz hasta `folder_id` (incluida). Vacía si None.
    pub fn folder_path(&self, folder_id: Option<&str>) -> anyhow::Result<Vec<Folder>> {
        let Some(id) = folder_id else { return Ok(Vec::new()) };
        let conn = self.db.read();
        let mut chain: Vec<String> =
            ancestors(&conn, id)?.into_iter().map(|(a, _)| a).collect();
        chain.reverse();
        chain.push(id.to_string());
        chain.iter().map(|f| load_folder(&conn, f)).collect()
    }

    pub fn library_counts(&self) -> anyhow::Result<LibraryCounts> {
        let conn = self.db.read();
        let counts = conn.query_row(
            "SELECT
               (SELECT count(*) FROM notes WHERE deleted_at IS NULL AND folder_id IS NULL),
               (SELECT count(*) FROM notes WHERE deleted_at IS NULL),
               (SELECT count(*) FROM notes WHERE deleted_at IS NULL AND pinned = 1),
               (SELECT count(*) FROM folders f WHERE f.deleted_at IS NOT NULL AND NOT EXISTS
                   (SELECT 1 FROM folders p WHERE p.id = f.parent_id AND p.deleted_at IS NOT NULL))
               + (SELECT count(*) FROM notes n WHERE n.deleted_at IS NOT NULL AND NOT EXISTS
                   (SELECT 1 FROM folders p WHERE p.id = n.folder_id AND p.deleted_at IS NOT NULL)),
               (SELECT count(*) FROM study_items)",
            [],
            |r| {
                Ok(LibraryCounts {
                    inbox: r.get(0)?,
                    all: r.get(1)?,
                    pinned: r.get(2)?,
                    trash: r.get(3)?,
                    study_items: r.get(4)?,
                })
            },
        )?;
        Ok(counts)
    }
}
