# Folio · Contratos de datos entre capas

Fuente de verdad de los formatos que cruzan Dart ⇄ Rust ⇄ nativo. Rust valida; la UI produce/consume.
Los DTOs de la API están en `rust/src/api/types.rs` (bindings generados en `lib/src/rust/api/`).

## 1. Cuerpo de nota de texto (`notes.body`, `Note.body_json`)

Array JSON de bloques en orden de documento. Implementación de referencia: `rust/crates/folio_core/src/blocks.rs`.

```json
[
  {"id": "c1f…", "type": "heading1", "text": "Tema 2 · Cinemática"},
  {"id": "9ab…", "type": "paragraph", "text": "La velocidad es…"},
  {"id": "77e…", "type": "bullet", "text": "Posición", "indent": 0},
  {"id": "e02…", "type": "numbered", "text": "Primer paso", "indent": 1},
  {"id": "d4c…", "type": "todo", "text": "Repasar ejercicios", "checked": true},
  {"id": "aa1…", "type": "quote", "text": "Cita"},
  {"id": "b3b…", "type": "divider"},
  {"id": "f10…", "type": "image", "attachment_id": "<uuid>"},
  {"id": "f11…", "type": "pdf", "attachment_id": "<uuid>"},
  {"id": "f12…", "type": "board_link", "note_id": "<uuid de pizarra>"},
  {"id": "0c9…", "type": "paragraph", "text": "Texto de OCR corregido", "source_page_id": "<uuid página>"}
]
```

- `type` ∈ `heading1|heading2|heading3|paragraph|bullet|numbered|todo|quote|divider|image|pdf|board_link`.
  Tipos desconocidos se conservan y se ignoran (compatibilidad futura).
- `id` único dentro de la nota (UUID v4 generado por la UI). Obligatorio.
- `text` puede contener `\n` (saltos suaves). Sin formato en línea en v1.
- `indent` 0..3 solo para listas. `checked` solo para `todo`.
- `image`/`pdf` requieren `attachment_id` de un adjunto de la MISMA nota.
- `source_page_id` enlaza el texto con la página/imagen original de OCR (referencias y navegación).
- Los campos opcionales se omiten cuando valen su valor por defecto. Rust guarda la cadena tal cual.

Texto plano derivado (búsqueda e IA): encabezados y párrafos tal cual; `• ` viñetas; `1. ` numeradas
(contador por nivel); `☐ `/`☑ ` tareas; adjuntos no aportan texto (sus páginas se indexan aparte).

## 2. Escena de pizarra (`boards.scene`, `Board.scene_json`)

```json
{
  "version": 1,
  "background": "plain",
  "viewport": {"x": 0, "y": 0, "scale": 1.0},
  "elements": [
    {"id": "s1", "type": "stroke", "tool": "pen", "color": "#1C1B19FF", "width": 3.0,
     "points": [10.0, 20.0, 0.5,  11.0, 21.5, 0.55]},
    {"id": "s2", "type": "stroke", "tool": "highlighter", "color": "#F6E7A880", "width": 18.0, "points": […]},
    {"id": "r1", "type": "shape", "shape": "rect", "x": 100, "y": 80, "w": 200, "h": 120,
     "color": "#2F6F5EFF", "width": 2.0, "fill": null, "rotation": 0},
    {"id": "t1", "type": "text", "x": 120, "y": 300, "w": 240, "text": "Idea principal",
     "color": "#1C1B19FF", "size": 20.0},
    {"id": "i1", "type": "image", "x": 400, "y": 60, "w": 320, "h": 240, "attachment_id": "<uuid>"}
  ]
}
```

- Coordenadas en unidades de lienzo (independientes del zoom). `points` = tripletas planas `x, y, presión(0..1)`.
- `shape` ∈ `rect|ellipse|line|arrow`. Para `line`/`arrow`: (x,y) inicio y (x+w, y+h) fin (w/h pueden ser negativos).
- Orden del array = orden Z (último encima). Colores `#RRGGBBAA`.
- Imágenes: adjuntos de la propia pizarra (`import_image(note_id = id de la pizarra)`).
- Texto para búsqueda/IA: Rust concatena los `text` de los elementos `text` en orden de lectura
  (de arriba abajo, de izquierda a derecha). Los trazos NO se interpretan (no hay reconocimiento de
  escritura a mano ni de dibujos: requeriría un modelo de visión adicional verificado).

## 3. Contenido de materiales de estudio (`study_items.content`)

Todas las variantes incluyen `"citations": [Citation…]` (ver §4) con `n` únicos; el texto referencia `[n]`.

- `summary`, `outline`, `key_concepts`:
  ```json
  {"format": "markdown", "text": "## Ideas principales\n- La velocidad… [1]", "detail": "brief|detailed", "citations": […]}
  ```
- `flashcards`:
  ```json
  {"cards": [{"id": "c1", "front": "¿Qué es…?", "back": "Es… [2]", "citations": [2]}], "citations": […]}
  ```
- `quiz`:
  ```json
  {"questions": [
     {"id": "q1", "kind": "mcq", "question": "…", "options": ["A","B","C","D"], "answer_index": 2,
      "explanation": "… [1]", "citations": [1]},
     {"id": "q2", "kind": "open", "question": "…", "reference_answer": "…", "explanation": "…", "citations": [3]}
   ], "citations": […]}
  ```
- Intento de cuestionario (`quiz_attempts.answers`):
  `[{"question_id":"q1","response":"2","correct":true,"score":1.0,"feedback":"…"}]`

## 4. Citas

`Citation` (DTO) serializado en JSON con claves snake_case:
`{"n":1,"note_id":"…","note_title":"…","location":["Física"],"chunk_id":42,"block_id":"…|null",
"page_id":"…|null","attachment_name":"…|null","page_index":0|null,"snippet":"…","exists":true}`.
Reglas: solo se aceptan números [n] que correspondan a fragmentos realmente enviados al modelo; los
inexistentes se eliminan del texto. `exists` se recalcula al leer.

## 5. Fragmentos de búsqueda

`SearchHit.snippet` marca coincidencias con U+E000 (inicio) y U+E001 (fin). `…` indica recorte.

## 6. Canal nativo (Dart ⇄ Swift/Kotlin)

`MethodChannel('folio/native')`. Errores como `PlatformException(code, message)` con `code` ∈
`permission_denied|unsupported|io|ocr_failed|cancelled`.

| Método | Argumentos | Resultado |
|--------|------------|-----------|
| `ocr.recognize` | `{path: String, languages: ["es-ES","en-US"]}` | `{text, engine, confidence?: double, lines: [{text,x,y,w,h,confidence?}]}` (coords normalizadas 0..1, origen arriba-izquierda) |
| `ocr.info` | – | `{engine, languages: [String], handwriting: bool, available: bool}` |
| `pdf.pageCount` | `{path}` | `int` |
| `pdf.renderPage` | `{path, page: int, outPath, targetWidth: int}` | `{path, width, height}` (PNG) |
| `pdf.pageText` | `{path, page}` | `String` (iOS PDFKit; Android API 35+, si no `""`) |
| `scanner.scan` | – | `[String]` rutas JPEG (iOS VisionKit con corrección de perspectiva; Android: `unsupported`) |
| `files.excludeFromBackup` | `{path}` | `bool` (iOS: NSURLIsExcludedFromBackupKey; Android: no-op `true`) |
| `device.memory` | – | `{total, available}` bytes |

## 7. Ficheros

`<data_dir>/folio.sqlite3`, `<data_dir>/files/<attachment_id>/<nombre>`, `<data_dir>/files/<attachment_id>/pages/<n>.jpg`
(renders/escaneos), `<data_dir>/models/<fichero>.gguf` (+ `.part` durante la descarga), `<cache_dir>/tmp/`.
