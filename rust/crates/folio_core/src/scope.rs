//! Resolución de ámbitos (nota / notas / carpeta+subcarpetas / biblioteca) y construcción de
//! expresiones FTS5 seguras. Compartido por la búsqueda textual (folio_core) y el RAG (folio_ai)
//! para que ambos respeten EXACTAMENTE el mismo ámbito.

use rusqlite::{params, Connection, OptionalExtension};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScopeSpec {
    Note(String),
    Notes(Vec<String>),
    /// Carpeta y todas sus subcarpetas (no borradas).
    Folder(String),
    Library,
}

/// Ids de la carpeta y de todo su subárbol (excluye carpetas en la papelera).
pub fn folder_subtree(conn: &Connection, folder_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare_cached(
        "WITH RECURSIVE sub(id) AS (
             SELECT id FROM folders WHERE id = ?1 AND deleted_at IS NULL
             UNION ALL
             SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id WHERE f.deleted_at IS NULL
         )
         SELECT id FROM sub",
    )?;
    let ids = stmt.query_map(params![folder_id], |r| r.get::<_, String>(0))?.collect();
    ids
}

/// Ids de notas NO borradas dentro del ámbito, en orden estable (updated_at desc).
pub fn note_ids_in_scope(conn: &Connection, scope: &ScopeSpec) -> rusqlite::Result<Vec<String>> {
    match scope {
        ScopeSpec::Library => {
            let mut s = conn.prepare_cached(
                "SELECT id FROM notes WHERE deleted_at IS NULL ORDER BY updated_at DESC",
            )?;
            let v = s.query_map([], |r| r.get(0))?.collect();
            v
        }
        ScopeSpec::Note(id) => {
            let found: Option<String> = conn
                .query_row(
                    "SELECT id FROM notes WHERE id = ?1 AND deleted_at IS NULL",
                    params![id],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(found.into_iter().collect())
        }
        ScopeSpec::Notes(ids) => {
            let mut out = Vec::with_capacity(ids.len());
            let mut s =
                conn.prepare_cached("SELECT id FROM notes WHERE id = ?1 AND deleted_at IS NULL")?;
            for id in ids {
                if let Some(found) = s.query_row(params![id], |r| r.get::<_, String>(0)).optional()? {
                    if !out.contains(&found) {
                        out.push(found);
                    }
                }
            }
            Ok(out)
        }
        ScopeSpec::Folder(folder_id) => {
            let mut s = conn.prepare_cached(
                "WITH RECURSIVE sub(id) AS (
                     SELECT id FROM folders WHERE id = ?1 AND deleted_at IS NULL
                     UNION ALL
                     SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id WHERE f.deleted_at IS NULL
                 )
                 SELECT n.id FROM notes n JOIN sub ON n.folder_id = sub.id
                 WHERE n.deleted_at IS NULL ORDER BY n.updated_at DESC",
            )?;
            let v = s.query_map(params![folder_id], |r| r.get(0))?.collect();
            v
        }
    }
}

/// Nombres de carpetas desde la raíz hasta `folder_id` (incluida). Vacío si None.
pub fn folder_location(conn: &Connection, folder_id: Option<&str>) -> rusqlite::Result<Vec<String>> {
    let Some(mut current) = folder_id.map(str::to_string) else {
        return Ok(Vec::new());
    };
    let mut names = Vec::new();
    let mut s = conn.prepare_cached("SELECT name, parent_id FROM folders WHERE id = ?1")?;
    // Límite defensivo frente a ciclos corruptos.
    for _ in 0..64 {
        let row: Option<(String, Option<String>)> =
            s.query_row(params![current], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        let Some((name, parent)) = row else { break };
        names.push(name);
        match parent {
            Some(p) => current = p,
            None => break,
        }
    }
    names.reverse();
    Ok(names)
}

/// Términos de búsqueda normalizados: secuencias de letras/dígitos (Unicode), en minúsculas.
pub fn query_terms(query: &str) -> Vec<String> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase())
        .take(16)
        .collect()
}

/// Expresión MATCH para búsqueda incremental: todos los términos (AND), el último como prefijo.
/// Devuelve None si la consulta no tiene términos útiles. Cada término va entre comillas, por lo
/// que la sintaxis FTS5 del usuario (`NEAR`, `-`, `*`, `:`…) nunca se interpreta.
pub fn fts_match_all(query: &str) -> Option<String> {
    let terms = query_terms(query);
    if terms.is_empty() {
        return None;
    }
    let ends_with_space = query.ends_with(char::is_whitespace);
    let last = terms.len() - 1;
    Some(
        terms
            .iter()
            .enumerate()
            .map(|(i, t)| {
                // Prefijo en el último término mientras se escribe; y en términos cortos siempre.
                if (i == last && !ends_with_space) || t.chars().count() <= 2 {
                    format!("\"{t}\"*")
                } else {
                    format!("\"{t}\"")
                }
            })
            .collect::<Vec<_>>()
            .join(" AND "),
    )
}

/// Expresión MATCH para recuperación (RAG): cualquier término (OR) salvo palabras vacías.
pub fn fts_match_any(query: &str, stopwords: &[&str]) -> Option<String> {
    let terms: Vec<String> = query_terms(query)
        .into_iter()
        .filter(|t| t.chars().count() > 1 && !stopwords.contains(&t.as_str()))
        .collect();
    if terms.is_empty() {
        return None;
    }
    Some(terms.iter().map(|t| format!("\"{t}\"*")).collect::<Vec<_>>().join(" OR "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    fn setup() -> (tempfile::TempDir, Db) {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("t.sqlite3")).unwrap();
        db.write()
            .execute_batch(
                "INSERT INTO folders(id,parent_id,name,created_at,updated_at) VALUES
                   ('fis',NULL,'Física',0,0),('t1','fis','Tema 1',0,0),('t2','t1','Ejercicios',0,0),
                   ('qui',NULL,'Química',0,0),('old','fis','Borrada',0,0);
                 UPDATE folders SET deleted_at = 5 WHERE id = 'old';
                 INSERT INTO notes(id,folder_id,kind,title,created_at,updated_at) VALUES
                   ('n1','fis','text','A',0,1),('n2','t2','text','B',0,2),('n3','qui','text','C',0,3),
                   ('n4',NULL,'text','D',0,4),('n5','old','text','E',0,5),('n6','t1','text','F',0,6);
                 UPDATE notes SET deleted_at = 9 WHERE id = 'n6';
                 UPDATE notes SET deleted_at = 5 WHERE id = 'n5'; -- trash_folder marca también sus notas",
            )
            .unwrap();
        (dir, db)
    }

    #[test]
    fn folder_scope_is_recursive_and_excludes_deleted() {
        let (_d, db) = setup();
        let c = db.read();
        let mut ids = note_ids_in_scope(&c, &ScopeSpec::Folder("fis".into())).unwrap();
        ids.sort();
        assert_eq!(ids, vec!["n1", "n2"]); // n5 en carpeta borrada, n6 borrada
        assert_eq!(note_ids_in_scope(&c, &ScopeSpec::Library).unwrap().len(), 4);
        assert_eq!(note_ids_in_scope(&c, &ScopeSpec::Note("n6".into())).unwrap().len(), 0);
        assert_eq!(
            note_ids_in_scope(&c, &ScopeSpec::Notes(vec!["n3".into(), "n3".into(), "zz".into()])).unwrap(),
            vec!["n3"]
        );
        assert_eq!(folder_location(&c, Some("t2")).unwrap(), vec!["Física", "Tema 1", "Ejercicios"]);
        assert!(folder_location(&c, None).unwrap().is_empty());
    }

    #[test]
    fn fts_expressions_are_safe() {
        assert_eq!(fts_match_all("fís"), Some("\"fís\"*".into()));
        assert_eq!(fts_match_all("ley de Ohm"), Some("\"ley\" AND \"de\"* AND \"ohm\"*".into()));
        assert_eq!(fts_match_all("ley "), Some("\"ley\"".into()));
        assert_eq!(fts_match_all("\"; DROP -- NEAR(*)"), Some("\"drop\" AND \"near\"*".into()));
        assert_eq!(fts_match_all("  ¿? "), None);
        assert_eq!(fts_match_any("qué es la energía", &["qué", "es", "la"]), Some("\"energía\"*".into()));
    }

    #[test]
    fn match_expression_runs_in_fts5() {
        let (_d, db) = setup();
        let c = db.write();
        c.execute("INSERT INTO search_fts(rowid,title,body) VALUES (1,'Física','La energía cinética')", [])
            .unwrap();
        let q = fts_match_all("energia cine").unwrap();
        let n: i64 = c
            .query_row("SELECT count(*) FROM search_fts WHERE search_fts MATCH ?1", [q], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "unicode61 remove_diacritics debe ignorar tildes");
    }
}
