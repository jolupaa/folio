# Folio

Notas para iOS y Android con la organización de Apple Notes y herramientas de estudio inspiradas en
NotebookLM: OCR de apuntes, resúmenes, preguntas con referencias, flashcards, cuestionarios y pizarra.
Todo se procesa en el dispositivo: tras descargar los modelos, la app funciona en modo avión.

- Arquitectura: [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md)
- Decisiones técnicas verificadas (modelo, motor, OCR, puente): [docs/DECISIONES.md](docs/DECISIONES.md)
- Contratos de datos: [docs/CONTRATOS.md](docs/CONTRATOS.md) · Diseño: [docs/DESIGN.md](docs/DESIGN.md)
- Estado de implementación y verificación: [docs/ESTADO.md](docs/ESTADO.md)

## Requisitos

| Herramienta | Versión usada |
|-------------|---------------|
| Flutter / Dart | 3.47.9 / 3.13.7 (stable) |
| Rust (rustup) | 1.99.1 + targets `aarch64-linux-android armv7-linux-androideabi x86_64-linux-android aarch64-apple-ios aarch64-apple-ios-sim` |
| flutter_rust_bridge_codegen | 2.13.0 (`cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked`) |
| Android | SDK 37 (compileSdk), NDK 27.1, JDK 17, AGP 9.1, minSdk 26 |
| iOS | Xcode 26+, iOS 16+ (deployment target) |
| Otros | CMake ≥ 3.22 y libclang (compilación de llama.cpp y bindgen) |

## Compilar

```bash
flutter pub get
# Solo si cambia la API de rust/src/api: regenerar los bindings
flutter_rust_bridge_codegen generate

# Android (la compilación de Rust/llama.cpp la hace cargokit automáticamente)
flutter build apk --release            # o: flutter run
# iOS (en macOS con Xcode)
cd ios && pod install --repo-update; cd ..   # solo si Flutter usa CocoaPods para algún plugin
flutter build ios --release                  # o abre ios/Runner.xcworkspace
```

Pruebas:

```bash
(cd rust && cargo test --workspace)          # núcleo y RAG (motor simulado)
flutter test                                  # Dart: códecs, modelos y widgets
flutter test integration_test -d <emulador>   # recorrido completo en dispositivo/emulador
```

## Modelos de IA

Se descargan desde la propia app (**Ajustes › Modelos de IA**). Ahí se ve el tamaño, la licencia,
el estado y el progreso, y se pueden pausar, reanudar, cancelar o eliminar. Cada fichero se verifica
con su SHA-256 antes de activarlo. Catálogo (revisiones de Hugging Face fijadas en
`rust/crates/folio_ai/src/catalog.rs`):

| Modelo | Uso | Tamaño | Licencia |
|--------|-----|--------|----------|
| Qwen3.5-4B Q4_K_M | Generación · Recomendado (≥ 8 GB RAM) | 2,74 GB | Apache-2.0 |
| Qwen3.5-2B Q4_K_M | Generación · Ligero (≥ 6 GB RAM) | 1,28 GB | Apache-2.0 |
| Qwen3-Embedding-0.6B Q8_0 | Búsqueda semántica | 639 MB | Apache-2.0 |

Notas, carpetas, búsqueda, OCR y pizarra funcionan sin ningún modelo instalado.

## Privacidad

Las notas, las imágenes y las consultas no salen del dispositivo. En Android, el OCR usa Google ML Kit
(modelo incluido en la app); la librería puede enviar métricas de uso anónimas a Google, pero nunca
las imágenes ni el texto. En iOS se usa Apple Vision.
