# Técnicas de estudio (skills) · Diseño

Fecha: 2026-11-17 · Estado: aprobado en conversación (enfoque «catálogo interno»)

## Intención

Añadir a Folio, junto a los modelos Qwen locales, las mejores técnicas de estudio que circulan como
*Agent Skills* (SKILL.md), adaptadas para que funcionen **sin conexión y con modelos de 2B/4B**.
El usuario pidió buscar las mejores skills académicas y de resumen; la investigación mostró que no
se pueden cargar tal cual:

- Casi todas las «académicas» son para investigar o escribir artículos (búsqueda bibliográfica,
  LaTeX, revisión) y necesitan red, scripts de Python y herramientas.
- Ocupan 3–12 KB (≈1.000–3.000 tokens). Con `n_ctx` 8192 y un prellenado de 20–30 tok/s en
  Android (docs/DECISIONES.md), cargar una añadiría ~1 min por uso y quitaría sitio a las fuentes.
- Licencias: la más popular (Imbad0202/academic-research-skills) es CC BY-NC; varias no tienen
  licencia. Solo tomamos **ideas** de skills MIT y escribimos prompts propios.

## Objetivos

1. Tres técnicas nuevas que generan un material guardado (como un resumen), con citas [n]:
   - **Explícamelo fácil** (`feynman`) — de neurofoo/agent-skills `feynman` y mblode/agent-skills `eli5`.
   - **Notas Cornell** (`cornell`) — de wentorai/research-plugins `academic-study-methods`
     (Cornell + interrogación elaborativa: preguntas «¿por qué?/¿cómo?»).
   - **Chuleta de examen** (`cheatsheet`) — de Evan715823/cheatsheet-generator-skill.
2. Mejores flashcards y cuestionarios cambiando solo los prompts: una idea por tarjeta, tarjetas de
   completar huecos, preguntas de comprensión, distractores creíbles. Fuente: las «20 reglas para
   formular conocimiento» de SuperMemo (principio de información mínima, *cloze*) y
   `academic-study-methods`. *(Corrección: `assessment-design-guide` resultó ser de psicometría —
   IRT, fiabilidad— y no aporta a la redacción de preguntas.)*
3. Que añadir una técnica en el futuro sea **añadir una entrada a un catálogo en Rust**, sin
   migraciones de BD ni cambios de enum en Dart.

## No objetivos

- Instalar/importar SKILL.md por el usuario (los modelos pequeños siguen mal instrucciones largas).
- Tutor socrático en el chat (fase 2, tras probar en un móvil real).
- Modo repaso interactivo de las notas Cornell (tapar respuestas): v1 es Markdown.
- Técnicas con salida JSON en el catálogo (v1 solo admite Markdown).
- Skills de investigación (bibliografía, LaTeX, revisión de artículos).

## Anti-objetivos (sería un fracaso aunque funcione)

- Que algo necesite red.
- Que el modelo añada datos que no están en las notas (la única licencia es la analogía, que no
  aporta datos).
- Que los modos existentes se vuelvan notablemente más lentos (+≤ 80 tokens de prompt cada uno).

## Enfoques considerados

| Enfoque | Pros | Contras |
|---------|------|---------|
| **A. Catálogo interno + un tipo genérico `skill`** *(elegido)* | Añadir técnicas = una entrada en Rust; una sola migración ahora | Algo más de trabajo inicial (API de catálogo, agrupación por técnica en Dart) |
| B. Un valor de `StudyKind` por técnica | Patrón actual, tipado | Cada técnica nueva: migración (CHECK de `study_items.kind`), regenerar FRB, tocar varios `switch` de Dart |
| C. Cargar SKILL.md en tiempo de ejecución | Extensible por el usuario | Demasiado largo para 8K de contexto y CPU móvil; 2B/4B no siguen instrucciones largas |

## Diseño

### Datos

- `StudyKind` gana la variante `Skill` (BD: `'skill'`) en `folio_ai::types`, en la API FRB
  (`rust/src/api/types.rs`) y, por generación, en Dart.
- `study_items` gana la columna `skill TEXT` (NULL salvo para `kind='skill'`).
- **Migración 0002**: reconstrucción de `study_items` (SQLite no permite cambiar un CHECK) con el
  procedimiento oficial de 12 pasos: tabla nueva con `CHECK (kind IN (…,'skill'))` y la columna
  `skill`, copia, `DROP`, `RENAME`. `study_items` no tiene índices ni triggers propios.
- **Cambio en `folio_core::db::migrate`**: con `foreign_keys=ON`, el `DROP TABLE study_items`
  borraría en cascada `study_item_sources` y `quiz_attempts`. Por eso `migrate` pone
  `PRAGMA foreign_keys=OFF` antes del bucle (no tiene efecto dentro de una transacción), ejecuta
  `PRAGMA foreign_key_check` dentro de cada transacción antes del commit (si devuelve filas, error y
  rollback) y restaura `foreign_keys=ON` al terminar, también si falla.
- Contenido (`docs/CONTRATOS.md` §3): igual que los textos —
  `{"format":"markdown","text":"…","citations":[…]}`. La técnica vive en la columna, no en el JSON.

### Catálogo (`rust/crates/folio_ai/src/skills.rs`)

```rust
pub struct StudySkill {
    pub id: &'static str,          // estable, se guarda en BD: "feynman" | "cornell" | "cheatsheet"
    pub name: &'static str,        // «Explícamelo fácil»
    pub section: &'static str,     // encabezado plural en la lista: «Explicaciones fáciles»
    pub description: &'static str, // subtítulo en la hoja del asistente
    pub icon: &'static str,        // nombre lógico; Dart lo traduce a IconData
    pub writing: &'static str,     // mensaje de progreso: «Preparando la explicación…»
    pub task: &'static str,        // instrucción para el modelo (corta: ≤ 700 caracteres)
    pub max_tokens: u32,
}
pub const SKILLS: &[StudySkill] = &[/* feynman, cornell, cheatsheet */];
pub fn find(id: &str) -> Option<&'static StudySkill>;
```

- `prompts::study_prompt`, `max_tokens`, `writing_message` y `build_content` reciben la técnica
  cuando `kind == Skill` (salida Markdown → misma ruta que resumen: `finalize_answer` + citas).
- `run_study`: si `kind == Skill` y `options.skill` falta o no existe en el catálogo → error
  «Técnica de estudio desconocida». Título por defecto «<name> · <ámbito>».
- `store`: `insert_study_item` guarda `skill`; `list/get` lo devuelven; `validate_content` trata
  `Skill` como texto; `item_count` = 0.
- Un `skill` guardado que ya no esté en el catálogo (versiones futuras) se muestra como texto con la
  etiqueta genérica «Material».

### Prompts v1 (borrador; se ajustan con el modelo real)

Todos van con `STUDY_SYSTEM` (solo fuentes, citas [n], idioma de las fuentes).

- **feynman** (`max_tokens` 900): «Explica el contenido de las fuentes como si se lo contaras a
  alguien de 12 años que no sabe nada del tema. Usa palabras cotidianas; si necesitas un término
  técnico, defínelo en una frase. No uses relleno como "simplemente" u "obviamente". Escribe en
  Markdown con estas secciones: `## La idea en una frase`, `## Explicación sencilla` (con citas),
  `## Una analogía` (puede ser tuya, pero sin añadir datos), `## Palabras clave`
  («- **término**: definición sencilla [n]»), `## Comprueba que lo entiendes` (3 preguntas).»
- **cornell** (`max_tokens` 1100): «Crea apuntes con el método Cornell en Markdown. Para cada tema
  importante escribe un encabezado `### ¿…?` con una pregunta clave —usa "¿por qué…?" o "¿cómo…?"
  cuando se pueda— y debajo viñetas breves que la respondan, con su cita [n]. Escribe entre 4 y 8
  preguntas. Termina con `## Resumen`: tres o cuatro frases con lo esencial.»
- **cheatsheet** (`max_tokens` 1100): «Crea una CHULETA DE EXAMEN en Markdown: lo imprescindible
  para repasar justo antes del examen, lo más densa posible. Agrupa por tema con `##`. Solo viñetas
  cortas, sin frases de relleno: definiciones («**término**: definición»), fórmulas, fechas, cifras,
  listas y pasos. Copia fórmulas y datos exactamente como aparecen en las fuentes. Cita cada viñeta [n].»
- **Flashcards** (añadido): «Cada tarjeta pregunta UNA sola idea. Mezcla definiciones con preguntas
  de "¿por qué?" o "¿cómo?". Puedes incluir tarjetas de completar: en front la frase con un hueco
  "____" y en back la palabra que falta.» (El esquema JSON y la gramática no cambian.)
- **Cuestionario** (añadido): «Las opciones incorrectas deben ser creíbles y del mismo tema; no uses
  "todas las anteriores" ni "ninguna de las anteriores". Incluye preguntas que exijan comprender o
  aplicar, no solo recordar.»

### API FRB

- `StudyOptions.skill: Option<String>`; `StudyItemSummary.skill` y `StudyItem.skill: Option<String>`.
- Nueva `list_study_skills() -> Vec<StudySkillInfo { id, name, section, description, icon }>`
  en `rust/src/api/study.rs`. Regenerar bindings con `flutter_rust_bridge_codegen generate` (2.13.0).

### Flutter

- `studySkillsProvider` (FutureProvider) sobre `listStudySkills()`, en `study_gateway.dart`
  (sustituible en tests vía el gateway).
- `ai_actions_sheet.dart`: tras los modos actuales, subtítulo «Técnicas de estudio» y un
  `_ActionTile` por técnica (icono, nombre, descripción) → `StudyRequest(kind: StudyKind.skill,
  options: …skill: id, label: name)`.
- `study_list_screen.dart`: tras los tipos fijos, una sección por técnica (encabezado `section`).
- `study_labels.dart`: etiquetas e iconos que reciben también el `skill` y el catálogo;
  `skillIcon(String)` traduce `lightbulb`/`cornell`/`cheatsheet` y usa un icono genérico si no conoce el nombre.
- `study_models.dart`: `StudyKind.skill` → `TextContent` (mismo visor y editor Markdown).
- `generation_sheet.dart`: sin cambios de lógica (no es estructurado).

### Documentación

`docs/CONTRATOS.md` §3 (tipo `skill` y columna), `docs/ARQUITECTURA.md` (catálogo),
`docs/ESTADO.md` (funciones y verificación), `docs/DECISIONES.md` (nueva sección con la
investigación de skills, licencias y créditos a los repos MIT de origen).

## Verificación

- Rust (`cargo test --workspace`): invariantes del catálogo (ids únicos, ASCII, `task` ≤ 700
  caracteres); prompts de técnica; `build_content` de técnica; round-trip de `skill` en `store`;
  **migración de una BD v1 con materiales, fuentes e intentos**: se conservan todas las filas y la
  cascada sigue funcionando; flujo con el motor simulado (`tests/flow.rs`).
- Dart (`flutter analyze`, `flutter test`): parseo de `skill` como texto, etiquetas e iconos con
  técnica desconocida, agrupación en la lista, hoja del asistente con el catálogo.
- **Modelo real en el host** (`examples/e2e.rs`, Qwen3.5-2B en `~/.cache/folio-test-models`): cada
  técnica y las flashcards/cuestionario nuevos. Criterio: aparecen las secciones pedidas, hay citas
  válidas, no hay datos ajenos a las fuentes. Se anotan tiempos. Si falla, se ajusta el prompt.
- Compilación Android debug (`flutter build apk --debug`) para comprobar el puente regenerado.

## Queda a criterio de quien implemente

Textos exactos de la interfaz, iconos concretos, orden de las secciones, redacción final de los
prompts tras probarlos con el modelo real (sin salirse de las secciones y límites de arriba).
