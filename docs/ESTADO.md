# Folio · Estado de implementación y verificación

Fecha: 2026-11-17 (técnicas de estudio; el resto, 2026-11-12). Distingue **compilación**, **pruebas automatizadas** y **validación en dispositivo**.

## Qué se ha verificado y cómo

| Nivel | Qué | Resultado |
|-------|-----|-----------|
| Compilación | APK Android debug x86_64 (Flutter + Rust + llama.cpp + ML Kit) | Compila |
| Compilación | `libfolio_bridge.so` arm64-v8a release (cargo-ndk) | Compila, 16,8 MB, sin `libc++_shared` |
| Compilación | iOS | **No compilado** (no hay Xcode en Linux) |
| Tests Rust | `cargo test --workspace` | 79 pasan (núcleo 37, IA 42) |
| Tests Dart | `flutter test` | 55 pasan (códec de bloques, barra de búsqueda, formato, técnicas de estudio) |
| Análisis | `flutter analyze` | 0 errores, 0 avisos (20 sugerencias de estilo previas) |
| Host, modelo real | `cargo run --release -p folio_ai --example e2e` | Pasa con Qwen3.5-2B + Qwen3-Embedding, incluidas las 3 técnicas de estudio |
| Emulador Android 17 (x86_64, 8 GB) | `integration_test/app_test.dart` | 2 tests pasan |
| Emulador, IA real | `integration_test/ai_device_test.dart` | Pasa, incluido modo avión |
| Dispositivo físico | — | **Sin validar** (ni Android ni iOS) |

### Cubierto por pruebas automatizadas

- **Persistencia tras reiniciar**: carpetas, notas, fijadas, adjuntos (fichero en disco), pizarra con
  su vista; el mantenimiento de arranque no borra adjuntos referenciados.
- **Ámbito de búsqueda**: biblioteca, carpeta con subcarpetas, nota; sin tildes y por prefijo.
- **Índices tras editar, mover, borrar y restaurar**: búsqueda textual e índice de IA.
- **Papelera**: carpeta con su contenido, restauración de ancestros, borrado definitivo, purga a 30 días.
- **Captura y OCR real** (emulador, ML Kit): imagen con texto → OCR (fiabilidad 0,89) → corrección →
  nota; se conserva la relación texto ↔ imagen y la nota se encuentra por su texto.
- **PDF**: capa de texto extraída, páginas sin texto marcadas para OCR, fichero no válido rechazado.
- **IA**: respeto estricto del ámbito, citas solo de fragmentos enviados (las inventadas se eliminan),
  «información insuficiente», cancelación, resumen por partes para ámbitos grandes, JSON de
  flashcards y cuestionarios, corrección de respuestas abiertas.
- **Técnicas de estudio**: catálogo, generación y guardado con su técnica, técnica desconocida o
  ausente (error claro, nada guardado), fuentes sin datos, edición, id retirado del catálogo,
  fórmulas LaTeX convertidas en texto.
- **Migración 2** desde una BD v1 con materiales, fuentes e intentos: no se pierde nada y la cascada
  sigue funcionando; una referencia rota antigua no bloquea la actualización.
- **Modelos**: descarga, pausa, reanudación con Range, cancelación, SHA-256 incorrecto, espacio
  insuficiente, servidor caído; modelo ausente → mensaje claro.
- **Modo avión** (emulador): tras descargar los modelos desde la app, pregunta y resumen sin red.
- Regresión de concurrencia: guardar mientras el indexador escribe (antes daba «database is locked»).

### Mediciones (no son de un móvil real)

| Entorno | Carga + respuesta corta | Flashcards (4–5) | Resumen breve |
|---------|-------------------------|------------------|---------------|
| Host x86_64, 32 hilos, Qwen3.5-2B | 4,1 s | 7,2 s | 7,6 s |
| Emulador Android, 6 núcleos, Qwen3.5-2B | ~10 s (9,2 s hasta el primer texto, incluye carga) | 19,5 s | 16,6 s |

Técnicas de estudio en el host (Qwen3.5-2B, 2 notas de Física): Explícamelo fácil 11,7 s, Notas Cornell
15,0 s, Chuleta de examen 9,2 s; flashcards (5) 12,1 s y cuestionario (4) 16,2 s con las reglas nuevas.

Descarga en el emulador: embeddings 639 MB en 39 s, LLM 1,28 GB en 78 s (con verificación).
El rendimiento, la memoria y el comportamiento térmico en móviles arm64 **no están medidos**.

## Funciones conectadas

Notas y carpetas (crear, editar con guardado automático, mover, fijar, papelera) · editor con títulos,
listas, tareas, citas y adjuntos · búsqueda inferior por ámbito con fragmentos y ubicación ·
captura (cámara, galería; escáner en iOS) → revisión (girar, recortar, repetir) → OCR con progreso y
cancelación → texto editable → nota nueva o existente · adjuntos de imagen y PDF con visor y texto por
página · asistente (preguntar, resúmenes, esquema, conceptos, flashcards, cuestionarios) con citas
navegables · técnicas de estudio (Explícamelo fácil, Notas Cornell, Chuleta de examen) · materiales
guardados y editables · gestor de modelos · pizarra con guardado automático.

## Pendiente y limitaciones conocidas

1. **iOS sin compilar ni probar.** El código Swift (Vision, PDFKit, VisionKit) está escrito pero no ha
   pasado por Xcode. Es el mayor riesgo abierto. Metal tampoco está probado.
2. **Sin validación en dispositivos físicos**: cámara real, lápiz y rechazo de palma, memoria y
   temperatura con el modelo cargado, teclados reales en el editor.
3. **Interfaz probada solo en parte de forma automática**: biblioteca, búsqueda y apertura de nota.
   Captura, visor de adjuntos, pizarra, chat, estudio y modelos compilan y están conectados, pero no
   tienen prueba de interfaz en dispositivo. La pizarra no tiene tests propios.
4. **Calidad del modelo Ligero (2B)**: a veces responde sin el dato concreto u omite las citas; en ese
   caso se atribuyen por coincidencia con las fuentes enviadas (nunca se inventan). El modelo
   Recomendado (4B) no se ha ejecutado.
5. **OCR**: orientado a texto impreso; manuscrito, fórmulas y diagramas no se garantizan. En Android,
   ML Kit envía métricas de uso a Google (declarado en Ajustes).
6. **PDF**: la extracción de texto es en Rust; el render de páginas para OCR usa el adaptador nativo.
   No se ha probado con PDF reales escaneados en dispositivo.
7. Búsqueda dentro de la nota: resalta la coincidencia actual, no todas a la vez.
8. Solo se generó APK de depuración; falta firma y configuración de publicación.
9. **Técnicas de estudio**: probadas con el modelo 2B en el host, no en un móvil. Con el 2B, las
   analogías de «Explícamelo fácil» a veces son imprecisas y las notas Cornell alternan `### ¿…?` y
   `**¿…?**`. La hoja del asistente no tiene prueba de interfaz. Pendiente: tutor socrático (fase 2)
   y repaso interactivo de las notas Cornell.
