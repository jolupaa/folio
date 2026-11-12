# Folio · Arquitectura

Notas al estilo Apple Notes + herramientas de estudio inspiradas en NotebookLM, con IA 100 % local.

## Capas

```
┌──────────────────────────── Flutter / Dart (UI) ────────────────────────────┐
│ features/library · notes (flutter_quill) · search · trash · settings        │
│ features/capture · attachments · board · ai · study · models                │
│ core/ (providers Riverpod, navegación go_router, formato)  app/ (tema)      │
├──────────── flutter_rust_bridge 2.13 (FFI, async, StreamSink) ──────────────┤
│ rust/src/api/*  (capa fina: DTOs + validación)                               │
│ ├─ folio_core: SQLite (rusqlite, WAL, migraciones), carpetas, notas,        │
│ │              papelera, adjuntos, PDF, imágenes, pizarras, búsqueda FTS5    │
│ └─ folio_ai:   indexador en 2º plano, fragmentación, embeddings,            │
│                recuperación híbrida (BM25 + vectores, RRF), llama.cpp,      │
│                conversación con citas, estudio, gestor de modelos           │
├──────────── MethodChannel 'folio/native' (plugin packages/folio_native) ────┤
│ iOS (Swift): Apple Vision OCR · PDFKit · VisionKit (escáner)                │
│ Android (Kotlin): ML Kit Text Recognition v2 (bundled) · PdfRenderer        │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Por qué flutter_rust_bridge**: es el puente Flutter↔Rust más maduro y mantenido, con soporte
oficial para iOS y Android y generación de código tipado en los dos lados. Funciones asíncronas
que no bloquean la UI, `StreamSink` para emitir tokens y progreso, y errores `anyhow` que llegan
como excepciones Dart. Las versiones están fijadas exactamente (codegen, crate y paquete 2.13.0).
Usa el backend cargokit, que es el que viene por defecto y está probado; el backend native-assets
queda como migración futura.

## Decisiones verificadas (detalle y fuentes en docs/DECISIONES.md)

| Área | Decisión |
|------|----------|
| LLM | «Qwen3.0 6B» **no existe**. Recomendado: **Qwen3.5-4B Q4_K_M** (2,74 GB, Apache-2.0). Ligero: **Qwen3.5-2B Q4_K_M** (1,28 GB) |
| Motor | llama.cpp vía crate `llama-cpp-2 = 0.1.161` (llama.cpp con soporte `qwen35`). CPU en Android, Metal en iOS |
| Embeddings | **Qwen3-Embedding-0.6B Q8_0** (639 MB, Apache-2.0), pooling last-token, 1024 dims |
| OCR iOS | Apple Vision `VNRecognizeTextRequest` (.accurate, es-ES/en-US), en el dispositivo |
| OCR Android | ML Kit Text Recognition v2 **bundled** (~4 MB/ABI, sin descarga en tiempo de ejecución, Latin: es/en) |
| PDF | Texto con Rust; render de páginas escaneadas con PDFKit / PdfRenderer → OCR |
| Editor | flutter_quill 11.6.0, convertido a nuestro formato de bloques (docs/CONTRATOS.md §1) |
| Estado / rutas | Riverpod 3.5 · go_router 18 |

## Datos

SQLite en `<Application Support>/folio.sqlite3`, versionado con `PRAGMA user_version` y migraciones
SQL en `rust/crates/folio_core/migrations/`. Tablas: `folders` (árbol), `notes` (texto y pizarra;
borrado lógico), `attachments` + `attachment_pages` (texto por página y vínculo con la imagen
original), `boards`, `search_docs` + `search_fts` (FTS5), `chunks` + `chunks_fts` +
`chunk_embeddings` + `index_state` (RAG), `study_items`, `quiz_attempts`, `chat_threads`/`messages`,
`models`, `settings`.

## Flujos clave

1. **Captura**: cámara/galería/escáner → revisión (girar/recortar) → OCR nativo → texto editable →
   `create_note_from_scan` / `append_scan_to_note` (Rust copia las imágenes y crea los bloques con
   `source_page_id`) → índice de búsqueda inmediato e indexación IA en segundo plano.
2. **Búsqueda**: FTS5 con prefijos y sin diacríticos; el ámbito (biblioteca / carpeta recursiva /
   nota) se resuelve en SQL (`folio_core::scope`).
3. **IA**: el indexador escucha la `ChangeSignal`, fragmenta las notas marcadas como sucias,
   reutiliza los fragmentos que no han cambiado (hash) y calcula embeddings si el modelo está
   instalado. Cada pregunta recupera fragmentos en modo híbrido dentro del ámbito, los numera [n]
   en el prompt, genera con llama.cpp en streaming y valida las citas. Si no hay evidencia
   suficiente, lo indica sin inventar.
4. **Sin modelo**: notas, carpetas, búsqueda, OCR y pizarra funcionan igual. La IA muestra el
   estado «modelo no instalado» o «dispositivo no compatible».
