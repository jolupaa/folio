//! Catálogo de técnicas de estudio («skills»).
//!
//! Cada técnica condensa en un prompt corto una *Agent Skill* pública (ver docs/DECISIONES.md):
//! las originales ocupan miles de tokens y no caben en el contexto de un modelo móvil. Todas
//! producen Markdown con citas [n] y siguen la ruta de los resúmenes. Para añadir una técnica,
//! basta con una entrada nueva en [`SKILLS`]; su `id` se guarda en la BD y no debe cambiar.

use crate::types::StudyKind;

#[derive(Debug)]
pub struct StudySkill {
    /// Id estable (se guarda en `study_items.skill`).
    pub id: &'static str,
    /// Nombre visible y título por defecto «<name> · <ámbito>».
    pub name: &'static str,
    /// Encabezado plural en la lista de materiales.
    pub section: &'static str,
    /// Subtítulo en la hoja del asistente.
    pub description: &'static str,
    /// Nombre lógico del icono (Dart lo traduce).
    pub icon: &'static str,
    /// Mensaje de progreso mientras escribe.
    pub writing: &'static str,
    /// Instrucción para el modelo (≤ 700 caracteres: cada token cuenta en un móvil).
    pub task: &'static str,
    pub max_tokens: u32,
}

/// Técnicas disponibles, en el orden en que se muestran.
pub const SKILLS: &[StudySkill] = &[
    // neurofoo/agent-skills «feynman» + mblode/agent-skills «eli5» (MIT).
    StudySkill {
        id: "feynman",
        name: "Explícamelo fácil",
        section: "Explicaciones fáciles",
        description: "Con palabras sencillas, una analogía y preguntas para comprobarlo",
        icon: "lightbulb",
        writing: "Preparando la explicación…",
        task: "Explica el contenido de las fuentes como si se lo contaras a alguien de 12 años que no sabe nada del tema. Usa palabras cotidianas; si necesitas un término técnico, defínelo en una frase. No uses relleno como «simplemente» u «obviamente». Escribe en Markdown con estas secciones, en este orden:\n## La idea en una frase\n## Explicación sencilla\n## Una analogía\n## Palabras clave\n## Comprueba que lo entiendes\nEn «Una analogía» compara con algo cotidiano que funcione igual que lo que dicen las fuentes, sin añadir datos. En «Palabras clave» usa el formato «- **término**: definición sencilla [n]». En «Comprueba que lo entiendes» escribe 3 preguntas que se respondan con las fuentes.",
        max_tokens: 900,
    },
    // wentorai/research-plugins «academic-study-methods» (MIT): Cornell + interrogación elaborativa.
    StudySkill {
        id: "cornell",
        name: "Notas Cornell",
        section: "Notas Cornell",
        description: "Preguntas clave con sus respuestas y un resumen para repasar de memoria",
        icon: "cornell",
        writing: "Escribiendo las notas Cornell…",
        task: "Crea apuntes con el método Cornell en Markdown. Para cada tema importante escribe un encabezado «### ¿…?» con una pregunta clave (usa «¿por qué…?» o «¿cómo…?» cuando se pueda) y debajo viñetas breves que la respondan, cada una con su cita [n]. Escribe entre 4 y 8 preguntas. Usa solo lo que dicen las fuentes. Termina con una línea «## Resumen» (solo dos #) y debajo tres o cuatro frases con lo esencial.",
        max_tokens: 1100,
    },
    // Evan715823/cheatsheet-generator-skill (MIT), sin LaTeX.
    StudySkill {
        id: "cheatsheet",
        name: "Chuleta de examen",
        section: "Chuletas de examen",
        description: "Lo imprescindible en una página: definiciones, fórmulas y datos",
        icon: "cheatsheet",
        writing: "Preparando la chuleta…",
        task: "Crea una CHULETA DE EXAMEN en Markdown: lo imprescindible para repasar justo antes del examen, lo más densa posible. Usa SOLO lo que dicen las fuentes: no añadas fórmulas, unidades ni datos que no aparezcan en ellas. Agrupa por tema con encabezados ##. Usa solo viñetas cortas, sin tablas ni frases de relleno: definiciones («- **término**: definición»), fórmulas, fechas, cifras, listas y pasos. Escribe las fórmulas como texto normal (F = m·a), sin LaTeX ni signos $. Cita cada viñeta con [n].",
        max_tokens: 1100,
    },
];

pub fn find(id: &str) -> Option<&'static StudySkill> {
    SKILLS.iter().find(|s| s.id == id)
}

/// Técnica de una petición: `None` si no es una técnica; error si falta o no existe.
pub fn resolve(kind: StudyKind, skill: Option<&str>) -> anyhow::Result<Option<&'static StudySkill>> {
    if kind != StudyKind::Skill {
        return Ok(None);
    }
    skill.and_then(find).map(Some).ok_or_else(|| anyhow::anyhow!("Técnica de estudio desconocida"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::StudyKind;
    use std::collections::BTreeSet;

    #[test]
    fn catalog_ids_are_unique_ascii_and_tasks_short() {
        let ids: Vec<&str> = SKILLS.iter().map(|s| s.id).collect();
        assert_eq!(ids, ["feynman", "cornell", "cheatsheet"]);
        assert_eq!(ids.iter().collect::<BTreeSet<_>>().len(), ids.len(), "ids únicos");
        for s in SKILLS {
            assert!(s.id.chars().all(|c| c.is_ascii_lowercase() || c == '_'), "{}", s.id);
            for f in [s.name, s.section, s.description, s.icon, s.writing, s.task] {
                assert!(!f.trim().is_empty(), "{}: campo vacío", s.id);
            }
            assert!(s.task.chars().count() <= 700, "{}: task de {} caracteres", s.id, s.task.chars().count());
            assert!(s.max_tokens >= 400, "{}", s.id);
        }
    }

    #[test]
    fn resolve_requires_known_skill() {
        assert!(resolve(StudyKind::Summary, None).unwrap().is_none());
        assert!(resolve(StudyKind::Summary, Some("cornell")).unwrap().is_none());
        for bad in [None, Some("x")] {
            let e = resolve(StudyKind::Skill, bad).unwrap_err().to_string();
            assert!(e.contains("Técnica de estudio desconocida"), "{e}");
        }
        assert_eq!(resolve(StudyKind::Skill, Some("cornell")).unwrap().unwrap().id, "cornell");
        assert_eq!(find("cheatsheet").unwrap().name, "Chuleta de examen");
        assert!(find("nope").is_none());
    }
}
