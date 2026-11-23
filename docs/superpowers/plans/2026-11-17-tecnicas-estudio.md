# Técnicas de estudio (skills) · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Añadir tres técnicas de estudio (Explícamelo fácil, Notas Cornell, Chuleta de examen) desde un catálogo interno en Rust, y mejorar los prompts de flashcards y cuestionarios.

**Architecture:** Un tipo genérico `StudyKind::Skill` + columna `study_items.skill` identifican la técnica; el catálogo `folio_ai::skills` aporta nombre, icono y prompt. La salida es Markdown y reutiliza la ruta de los resúmenes (citas validadas). Flutter lee el catálogo por FRB y agrupa/etiqueta los materiales por técnica.

**Tech Stack:** Rust (rusqlite, llama-cpp-2), flutter_rust_bridge 2.13.0, Flutter 3.47 / Riverpod 3.5.

**Spec:** `docs/superpowers/specs/2026-11-17-tecnicas-estudio-design.md`

## Global Constraints

- Todo funciona sin red. Textos de interfaz y prompts en español.
- `flutter_rust_bridge_codegen` 2.13.0 exacto. Flutter en `~/development/flutter/bin/flutter`.
- No editar `0001_init.sql`: migración nueva `0002`.
- Ids de técnica estables y ASCII: `feynman`, `cornell`, `cheatsheet`. `task` ≤ 700 caracteres.
- Lo añadido a los prompts de flashcards y cuestionario ≤ 350 caracteres cada uno.
- La técnica vive en la columna `skill`, no dentro del JSON de contenido.
- Rama `tecnicas-estudio`, commits locales, sin push.

## Review Focus

1. Actualizar una instalación con materiales, fuentes e intentos de cuestionario: nada se pierde y la cascada al borrar sigue funcionando (test en Task 1).
2. Un `skill` guardado que el catálogo ya no conoce: el material se lista, se abre y se edita con etiqueta «Material» (tests en Task 3 y Task 6).
3. Generar con `kind = Skill` y técnica ausente o desconocida: error «Técnica de estudio desconocida» y nada guardado (test en Task 3).
4. Editar un material de técnica conserva su `skill` y se valida como texto (test en Task 3).
5. Fuentes sin datos (`NO_CONSTA`) en una técnica: mismo error que el resumen, nada guardado (test en Task 3).

---

### Task 1: Migración 0002 y migraciones con claves foráneas desactivadas

**Files:**
- Create: `rust/crates/folio_core/migrations/0002_study_skills.sql`
- Modify: `rust/crates/folio_core/src/db.rs` (`MIGRATIONS`, `migrate`, tests)

**Interfaces:**
- Produces: tabla `study_items(id, kind, skill, title, scope, content, model_id, created_at, updated_at)` con `CHECK (kind IN ('summary','outline','key_concepts','flashcards','quiz','skill'))` y `CHECK ((kind = 'skill') = (skill IS NOT NULL))`. `SCHEMA_VERSION == 2`.

- [ ] **Step 1: Test que falla** — en `db.rs` `mod tests`: `migration_2_keeps_study_data_and_cascades`:
  crear una BD v1 a mano (`Connection::open`, `PRAGMA foreign_keys=ON`, `execute_batch(0001)`, `user_version=1`); insertar 1 `study_items` (`kind='quiz'`), 1 `study_item_sources`, 1 `quiz_attempts`; llamar `migrate(&mut conn)`. Asserts: devuelve 2; las 3 filas siguen; `skill` es NULL; `PRAGMA foreign_keys` = 1; insertar `kind='skill', skill='feynman'` funciona y `kind='skill', skill=NULL` falla; borrar el material borra su fuente y su intento.
- [ ] **Step 2:** `cd rust && cargo test -p folio_core migration_2` → FAIL (versión 1 / columna inexistente).
- [ ] **Step 3:** SQL de reconstrucción (tabla `study_items_new`, `INSERT … SELECT` con `NULL` para `skill`, `DROP`, `ALTER … RENAME`). En `migrate`: `PRAGMA foreign_keys=OFF` antes del bucle; dentro de cada transacción, antes del commit, `PRAGMA foreign_key_check` y error «migración N: claves foráneas rotas» si devuelve filas; restaurar `foreign_keys=ON` siempre (también si hay error). Añadir `(2, include_str!("../migrations/0002_study_skills.sql"))`.
- [ ] **Step 4:** `cargo test -p folio_core` → PASS (incluido `migrates_fresh_db_and_is_idempotent`).
- [ ] **Step 5:** Commit `BD: migración 0002 (técnicas de estudio) con claves foráneas desactivadas durante la migración`.

### Task 2: Catálogo de técnicas y prompts

**Files:**
- Create: `rust/crates/folio_ai/src/skills.rs` (+ `pub mod skills;` en `lib.rs`)
- Modify: `rust/crates/folio_ai/src/types.rs` (`StudyKind::Skill`, `StudyOptions.skill`, `StudyItemSummary.skill`, `StudyItem.skill`)
- Modify: `rust/crates/folio_ai/src/prompts.rs`

**Interfaces:**
- Produces:
  - `pub struct StudySkill { pub id, name, section, description, icon, writing, task: &'static str, pub max_tokens: u32 }`
  - `pub const SKILLS: &[StudySkill]` (orden: feynman, cornell, cheatsheet), `pub fn find(id: &str) -> Option<&'static StudySkill>`
  - `pub fn resolve(kind: StudyKind, skill: Option<&str>) -> anyhow::Result<Option<&'static StudySkill>>`: `Ok(None)` si `kind != Skill`; error «Técnica de estudio desconocida» si falta o no existe.
  - `StudyKind::Skill` (`as_db` "skill", `display_name` "Material", `is_text` true). `skill: Option<String>` en `StudyOptions`, `StudyItemSummary`, `StudyItem`.
  - `prompts::writing_message(kind, skill: Option<&StudySkill>) -> &'static str`, `prompts::max_tokens(kind, detail, count, skill: Option<&StudySkill>) -> u32`, `prompts::study_prompt(kind, options, count, material, skill: Option<&StudySkill>) -> String`. Con `Skill` y `None` se comportan como resumen breve (no debe ocurrir). `grammar(Skill, _)` = None; `build_content(Skill, …)` = rama de texto.
- Valores del catálogo (`name` / `section` / `description` / `icon` / `writing` / `max_tokens`):
  - feynman: «Explícamelo fácil» / «Explicaciones fáciles» / «Con palabras sencillas, una analogía y preguntas para comprobarlo» / `lightbulb` / «Preparando la explicación…» / 900
  - cornell: «Notas Cornell» / «Notas Cornell» / «Preguntas clave con sus respuestas y un resumen para repasar de memoria» / `cornell` / «Escribiendo las notas Cornell…» / 1100
  - cheatsheet: «Chuleta de examen» / «Chuletas de examen» / «Lo imprescindible en una página: definiciones, fórmulas y datos» / `cheatsheet` / «Preparando la chuleta…» / 1100
  - `task`: los textos de la sección «Prompts v1» del spec.

- [ ] **Step 1: Tests que fallan** — en `skills.rs`: `catalog_ids_are_unique_ascii_and_tasks_short` (ids únicos, `[a-z_]+`, todos los campos no vacíos, `task.len() <= 700`); `resolve_requires_known_skill` (`resolve(Summary, None)` = `Ok(None)`; `resolve(Skill, None)` y `resolve(Skill, Some("x"))` = error con «Técnica de estudio desconocida»; `resolve(Skill, Some("cornell"))` = Some). En `prompts.rs`: `skill_prompt_uses_catalog_task` (el prompt de `cornell` contiene su `task` y «FUENTES:»; `max_tokens(Skill, …, Some(cornell))` = 1100; `grammar(Skill, Mixed)` es None).
- [ ] **Step 2:** `cargo test -p folio_ai --lib` → no compila / FAIL.
- [ ] **Step 3:** Implementar; actualizar los usos de las funciones cambiadas en `lib.rs` (`run_study`) pasando `None` provisionalmente y los `StudyOptions { … }` de `tests/flow.rs` y `examples/e2e.rs` con `skill: None`.
- [ ] **Step 4:** `cargo test -p folio_ai` → PASS.
- [ ] **Step 5:** Commit `IA: catálogo de técnicas de estudio y prompts`.

### Task 3: Guardado y generación de materiales de técnica

**Files:**
- Modify: `rust/crates/folio_ai/src/store.rs` (`insert_study_item`, `list_study_items`, `get_study_item`, `validate_content`)
- Modify: `rust/crates/folio_ai/src/lib.rs` (`run_study`)
- Test: `rust/crates/folio_ai/tests/flow.rs`

**Interfaces:**
- Consumes: Task 2 (`skills::resolve`, prompts con `skill`).
- Produces: `store::insert_study_item(conn, kind, skill: Option<&str>, title, scope, content, model_id, source_note_ids) -> Result<String>`; `list/get` rellenan `skill`.

- [ ] **Step 1: Tests que fallan** en `flow.rs`:
  - `skill_materials_are_generated_saved_and_listed`: para cada id de `SKILLS`, `generate_study(StudyKind::Skill, scope_folder, opts con skill)` → `Done`; `item.kind == Skill`, `item.skill == Some(id)`, título empieza por el `name` de la técnica y contiene «Física», `v["format"] == "markdown"`, texto con «[1]» y sin «[99]», `validate_content(Skill, …)` OK; el último prompt del motor (`stats.last_prompt`) contiene el `task`. `list_study_items` devuelve 3 con su `skill`.
  - `skill_generation_rejects_unknown_skill_and_insufficient_sources`: `skill: None` y `skill: Some("nope")` → evento `Error` con «Técnica de estudio desconocida» y 0 materiales; fuente con `[[sin-datos]]` → `Error` «no contienen información suficiente», 0 materiales.
  - `skill_material_survives_edit_and_unknown_catalog_id`: editar con `update_study_item` conserva `skill`; tras `UPDATE study_items SET skill='retirada'` el material se lista y se abre con `kind == Skill`.
- [ ] **Step 2:** `cargo test -p folio_ai --test flow skill_` → FAIL.
- [ ] **Step 3:** En `run_study`, `skills::resolve(kind, options.skill.as_deref())?` antes de leer fuentes; pasar la técnica a los prompts; título por defecto `"{name} · {ámbito}"`; guardar `skill`.
- [ ] **Step 4:** `cargo test --workspace` → PASS.
- [ ] **Step 5:** Commit `IA: generar y guardar materiales de técnicas de estudio`.

### Task 4: Flashcards y cuestionarios mejores

**Files:**
- Modify: `rust/crates/folio_ai/src/prompts.rs` (`study_prompt`, ramas `Flashcards` y `Quiz`)

- [ ] **Step 1: Test que falla** — `flashcard_and_quiz_prompts_carry_item_writing_rules`: el prompt de flashcards contiene «UNA sola idea» y «____»; el de cuestionario contiene «todas las anteriores» y «comprender o aplicar»; cada añadido ≤ 350 caracteres (comparar longitud con/sin).
- [ ] **Step 2:** `cargo test -p folio_ai --lib flashcard_and_quiz` → FAIL.
- [ ] **Step 3:** Añadir los textos del spec («Flashcards (añadido)» y «Cuestionario (añadido)»). El esquema JSON, la gramática y `build_content` no cambian.
- [ ] **Step 4:** `cargo test -p folio_ai` → PASS.
- [ ] **Step 5:** Commit `IA: reglas de redacción en flashcards y cuestionarios`.

### Task 5: API FRB y bindings

**Files:**
- Modify: `rust/src/api/types.rs`, `rust/src/convert.rs`, `rust/src/api/study.rs`
- Regenerate: `rust/src/frb_generated.rs`, `lib/src/rust/**`

**Interfaces:**
- Produces (Dart): `StudyKind.skill`; `StudyOptions(skill: String?)`; `StudyItemSummary.skill`, `StudyItem.skill` (`String?`); `class StudySkillInfo { String id, name, section, description, icon }`; `List<StudySkillInfo> listStudySkills()` (síncrona, `#[flutter_rust_bridge::frb(sync)]`).

- [ ] **Step 1:** Añadir variante, campos, `StudySkillInfo`, conversiones y `list_study_skills()` (mapea `skills::SKILLS` en orden).
- [ ] **Step 2:** `flutter_rust_bridge_codegen generate` → sin errores; `git diff --stat lib/src/rust` muestra los cambios esperados.
- [ ] **Step 3:** `cd rust && cargo build && cargo test --workspace` → PASS.
- [ ] **Step 4:** Commit `Puente: técnicas de estudio en la API`.

### Task 6: Flutter — modelos, etiquetas y catálogo

**Files:**
- Modify: `lib/features/study/study_labels.dart`, `study_models.dart`, `study_gateway.dart`
- Create: `test/features/study/study_labels_test.dart`, `test/features/study/study_models_test.dart`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  - `StudyGateway.listSkills() -> List<StudySkillInfo>`; `final studySkillsProvider = Provider<List<StudySkillInfo>>`.
  - `IconData skillIcon(String name)`: `lightbulb` → `Icons.lightbulb_outline_rounded`, `cornell` → `Icons.view_agenda_outlined`, `cheatsheet` → `Icons.receipt_long_outlined`, otro → `Icons.auto_awesome_outlined`.
  - `({String label, String section, IconData icon}) studyDisplay(StudyKind kind, String? skill, List<StudySkillInfo> skills)`: tipos fijos → funciones actuales; técnica conocida → `name`/`section`/`skillIcon(icon)`; desconocida → «Material» / «Otras técnicas» / `Icons.auto_awesome_outlined`.
  - `List<({String header, List<StudyItemSummary> items})> groupStudyItems(List<StudyItemSummary> items, List<StudySkillInfo> skills)`: tipos fijos en el orden actual, luego técnicas en el orden del catálogo, luego «Otras técnicas»; cada lista por `updatedAt` descendente; sin secciones vacías.
  - `StudyContent.parse(StudyKind.skill, …)` → `TextContent`.

- [ ] **Step 1: Tests que fallan** — `studyDisplay` con técnica conocida, desconocida y tipo fijo; `groupStudyItems` con un resumen, dos `cornell` (orden por fecha), un `feynman` y uno `retirada` → cabeceras `['Resúmenes', 'Explicaciones fáciles', 'Notas Cornell', 'Otras técnicas']`; `StudyContent.parse(StudyKind.skill, '{"format":"markdown","text":"Hola [1]","citations":[]}')` es `TextContent` con texto «Hola [1]».
- [ ] **Step 2:** `flutter test test/features/study` → FAIL.
- [ ] **Step 3:** Implementar; añadir el caso `StudyKind.skill` a los `switch` existentes.
- [ ] **Step 4:** `flutter test` → PASS.
- [ ] **Step 5:** Commit `App: catálogo y etiquetas de técnicas de estudio`.

### Task 7: Flutter — hoja del asistente, lista y visor

**Files:**
- Modify: `lib/features/ai/ai_actions_sheet.dart`, `lib/features/study/study_list_screen.dart`, `study_common.dart` (`StudyMetaLine` → `ConsumerWidget`), `study_item_screen.dart`

- [ ] **Step 1:** Hoja: `_generate(…, {String? skill})`; tras «Cuestionario», cabecera «Técnicas de estudio» y un `_ActionTile` por técnica (`skillIcon`, `name`, `description`) que lanza `StudyKind.skill` con `skill: id` y `label: name`.
- [ ] **Step 2:** Lista con `groupStudyItems`; filas, `StudyMetaLine` y título del visor con `studyDisplay`.
- [ ] **Step 3:** `flutter analyze` → 0 errores, 0 avisos; `flutter test` → PASS.
- [ ] **Step 4:** Commit `App: técnicas de estudio en el asistente y en Estudio`.

### Task 8: Prueba con el modelo real y ajuste de prompts

**Files:**
- Modify: `rust/crates/folio_ai/examples/e2e.rs`; si hace falta, `skills.rs` / `prompts.rs`

- [ ] **Step 1:** En `e2e.rs`, tras los materiales actuales, generar las 3 técnicas sobre «Física» e imprimir el Markdown, citas y tiempo; comprobar con `ensure!` que sale `Done`, que aparece al menos un encabezado `##`/`###` esperado de cada técnica y al menos una cita.
- [ ] **Step 2:** `FOLIO_TEST_MODELS_DIR=~/.cache/folio-test-models cargo run --release -p folio_ai --example e2e` → PASS.
- [ ] **Step 3:** Revisar a mano: secciones pedidas, citas válidas, sin datos ajenos a las fuentes, flashcards de una idea y distractores creíbles. Si falla, ajustar el prompt (sin pasar los límites) y repetir; anotar tiempos.
- [ ] **Step 4:** Commit `IA: prueba real de las técnicas de estudio con Qwen3.5-2B`.

### Task 9: Documentación y verificación final

**Files:**
- Modify: `docs/CONTRATOS.md` §3, `docs/ARQUITECTURA.md`, `docs/ESTADO.md`, `docs/DECISIONES.md`, `README.md` (línea de funciones si procede)

- [ ] **Step 1:** Documentar: tipo `skill` y columna; catálogo; tiempos medidos; sección en DECISIONES con la investigación, licencias (CC BY-NC descartada, repos sin licencia solo como idea) y créditos a neurofoo/agent-skills, mblode/agent-skills, wentorai/research-plugins, Evan715823/cheatsheet-generator-skill (MIT) y SuperMemo.
- [ ] **Step 2:** `cd rust && cargo test --workspace`; `flutter analyze`; `flutter test`; `flutter build apk --debug` → todo pasa.
- [ ] **Step 3:** Commit `Docs: técnicas de estudio`.
