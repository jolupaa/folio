> **Nota del integrador (decisiones adoptadas en la implementación)**. Este registro recoge la investigación
> y verificación adversarial (13 agentes, fuentes enlazadas). Donde la implementación final difiere, manda esto:
>
> - **Puente**: se usa el backend **cargokit** (por defecto en FRB 2.13.0), ya validado compilando el APK
>   Android con AGP 9.1. El backend native-assets (§4) queda como migración futura cuando sea el
>   predeterminado; en iOS, cargokit funciona vía CocoaPods (Flutter avisa de que no es compatible con SwiftPM).
> - **minSdk de Android: 26** (no 30): las funciones de notas/OCR no requieren más; la IA se habilita o no
>   según RAM y CPU (dotprod) comprobadas en tiempo de ejecución.
> - **Modelo**: sustitución explícita de «Qwen3.0 6B» (inexistente) por Qwen3.5-4B (Recomendado) y
>   Qwen3.5-2B (Ligero). Puedes cambiarla: el catálogo está en `rust/crates/folio_ai/src/catalog.rs`.
> - Las cifras de rendimiento de este documento son de terceros o estimaciones; las mediciones propias
>   (host y emulador) están en docs/ESTADO.md. **No hay mediciones en dispositivos físicos.**

# Registro de decisiones técnicas: app de notas con IA local

- **Fecha:** 2026-11-11
- **Estado:** PROPUESTO. Falta (1) que el usuario confirme el modelo y (2) hacer los spikes en dispositivo real (§7.2). **Aún no hay ninguna medición propia en dispositivo.** Todas las cifras de rendimiento son de terceros o estimaciones.
- **Alcance:** Flutter (UI) + Rust (lógica, SQLite, índices y coordinación de la IA) en iOS y Android. La IA es 100 % local una vez descargados los modelos. Se desarrolla en Linux, sin Xcode.

**Leyenda de evidencia**
- **(a)**: verificado en fuente oficial (org del autor en HF, GitHub del proyecto, crates.io/docs.rs, pub.dev, Apple, Google).
- **(b)**: dato de terceros (blogs, foros, repos comunitarios, papers).
- **(c)**: estimación o cálculo propio.
- **NV**: el verificador no pudo confirmarlo.
- **Corregido**: la afirmación inicial se refutó y aquí figura ya corregida.

## 0. Resumen

| Área | Decisión | Estado |
|---|---|---|
| "Qwen3.0 6B" | No existe. Se sustituye por Qwen3.5-4B y Qwen3.5-2B | Pendiente de confirmar con el usuario |
| LLM Recomendado | Qwen3.5-4B Q4_K_M (unsloth), solo si pasa la comprobación de memoria | Provisional (S1, S2) |
| LLM Ligero | Qwen3.5-2B Q4_K_M (unsloth). Se usa por defecto en 6 GB y si el 4B no cabe | Provisional |
| Motor | llama.cpp vía `llama-cpp-2 =0.1.161`, que trae llama.cpp v0.6.0 | Firme. Revisar cuando salga 0.1.162+ |
| Embeddings | Qwen3-Embedding-0.6B Q8_0 oficial, 1024 dimensiones | Firme |
| Búsqueda | FTS5 + vectores por fuerza bruta en Rust + RRF k=60 | Firme |
| Puente | flutter_rust_bridge 2.13.0 con backend native-assets | Provisional (S3) |
| OCR iOS | Apple Vision revision3 + VisionKit | Firme, con mitigación para iOS 27 |
| OCR Android | ML Kit Text Recognition v2 bundled 16.0.1 | Firme, con aviso de telemetría |
| Plataformas | Flutter 3.47.9; Android minSdk 30 y targetSdk 36; iOS 16.0 | Provisional |

---

## 1. Modelo

### 1.1 Denominación exacta y "Qwen3.0 6B"

- **"Qwen3.0 6B" no existe.** La org Qwen en HF tiene 469 repos y ninguno tiene "6B" como tamaño; los únicos "6bit" son sufijos MLX. Tampoco hay series Qwen3.7 ni Qwen4 ([a](https://huggingface.co/api/models?author=Qwen&limit=1000&sort=createdAt&direction=-1)).
- Lecturas posibles:
  1. **Qwen3-0.6B** (la más probable, (c)): Apache-2.0, 28 capas, contexto de 32.768 y modo thinking activado por defecto ([a](https://huggingface.co/Qwen/Qwen3-0.6B)). Hay un repo comunitario, `Phettae/Qwen3.0_6B`, que es un fine-tune de Qwen3-0.6B: el nombre "Qwen3.0_6B" circula como alias ([b](https://huggingface.co/Phettae/Qwen3.0_6B)).
  2. **Un modelo de unos 6B:** no hay ningún denso de 6B. Los más cercanos son Qwen3.5-4B y Qwen3.5-9B ([a](https://huggingface.co/Qwen/Qwen3.5-4B)).
  3. **Qwen3.8-Flash-Next:** su card dice "125B with 6B activated, plus 51B n-gram embedding and 4B MTP". Son unos 180B en total, arquitectura qwen4_exp y licencia qwen-community-1.0. No se puede ejecutar en un móvil ([a](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)).
  4. **Qwen3-Embedding-0.6B:** es un modelo de embeddings, no de generación. Lo usamos en §3 ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)).
- **La generación vigente de 9B o menos es Qwen3.5 small:** 0.8B, 2B, 4B y 9B, publicados el 2026-03-02. Licencia Apache-2.0, multimodales, arquitectura híbrida Gated DeltaNet/Attention en proporción 3:1, vocabulario de 248.320 tokens y contexto nativo de 262.144 ([a](https://huggingface.co/Qwen/Qwen3.5-4B)). Qwen3.6 y Qwen3.8 no tienen modelos de propósito general de 9B o menos ([a](https://github.com/QwenLM/Qwen3.8)). Qwen-Drive-1.0-4B existe, pero está especializado en conducción ([a](https://huggingface.co/Qwen/Qwen-Drive-1.0-4B)).
- **SUSTITUCIÓN:** "Qwen3.0 6B" → **Qwen3.5-4B (Recomendado)** y **Qwen3.5-2B (Ligero)**. Qwen3-0.6B y Qwen3.5-0.8B quedan solo como opción mínima experimental, porque son demasiado pequeños para generar texto de calidad (c). Hay que confirmarlo con el usuario.

### 1.2 Modelos candidatos

Los bytes salen de la API de HF.

| Modelo | Repo (@commit) | Fichero GGUF | Cuant. | Bytes | Licencia | Contexto nativo | Ev. |
|---|---|---|---|---|---|---|---|
| Qwen3.5-4B | unsloth/Qwen3.5-4B-GGUF @e87f1764 | Qwen3.5-4B-Q4_K_M.gguf | Q4_K_M | 2.740.937.888 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-4B-GGUF/tree/main) |
| Qwen3.5-4B | idem | Qwen3.5-4B-Q4_0.gguf | Q4_0 | 2.583.221.408 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-4B-GGUF/tree/main) |
| Qwen3.5-4B (visión) | idem | mmproj-F16.gguf | F16 | 672.423.616 | Apache-2.0 | — | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-4B-GGUF/tree/main) |
| Qwen3.5-2B | unsloth/Qwen3.5-2B-GGUF | Qwen3.5-2B-Q4_K_M.gguf | Q4_K_M | 1.280.835.840 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-2B-GGUF/tree/main) |
| Qwen3.5-2B | idem | Qwen3.5-2B-Q4_0.gguf | Q4_0 | 1.214.873.856 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-2B-GGUF/tree/main) |
| Qwen3.5-0.8B | unsloth/Qwen3.5-0.8B-GGUF | Qwen3.5-0.8B-Q4_K_M.gguf | Q4_K_M | 532.517.120 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-0.8B-GGUF/tree/main) |
| Qwen3.5-0.8B | ggml-org/Qwen3.5-0.8B-GGUF | Qwen3.5-0.8B-Q4_0.gguf | Q4_0 | 563.036.064 | Apache-2.0 | 262.144 | [a](https://huggingface.co/api/models?author=ggml-org&search=Qwen3.5) |
| Qwen3.5-9B | unsloth/Qwen3.5-9B-GGUF @3885219b | Qwen3.5-9B-Q4_K_M.gguf / -IQ4_XS.gguf | Q4_K_M / IQ4_XS | 5.680.522.464 / 5.168.653.536 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3.5-9B-GGUF/tree/main) |
| Qwen3-4B (plan B) | **Qwen/Qwen3-4B-GGUF** @bc640142 | Qwen3-4B-Q4_K_M.gguf | Q4_K_M | 2.497.280.256 | Apache-2.0 | 32.768 (131.072 con YaRN) | [a](https://huggingface.co/api/models/Qwen/Qwen3-4B-GGUF/tree/main) |
| Qwen3-4B-Instruct-2507 | unsloth/Qwen3-4B-Instruct-2507-GGUF | Qwen3-4B-Instruct-2507-Q4_K_M.gguf | Q4_K_M | 2.497.281.120 | Apache-2.0 | 262.144 | [b](https://huggingface.co/api/models/unsloth/Qwen3-4B-Instruct-2507-GGUF/tree/main) |
| Qwen3-1.7B (plan B ligero) | ggml-org/Qwen3-1.7B-GGUF | Qwen3-1.7B-Q4_K_M.gguf | Q4_K_M | 1.282.439.264 | Apache-2.0 | 32.768 | [a](https://huggingface.co/api/models/ggml-org/Qwen3-1.7B-GGUF/tree/main) |
| Qwen3-0.6B | Qwen/Qwen3-0.6B-GGUF | Qwen3-0.6B-Q8_0.gguf | Q8_0 | 639.446.688 | Apache-2.0 | 32.768 | [a](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF) |
| Qwen3-0.6B | ggml-org/Qwen3-0.6B-GGUF | Qwen3-0.6B-Q4_0.gguf | Q4_0 | 428.970.080 | Apache-2.0 | 32.768 | [a](https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF) |

Notas sobre la tabla:
- **Qwen no publica GGUF oficiales de Qwen3.5 small** ni de Qwen3-4B-Instruct-2507. Dependemos de terceros ([a](https://huggingface.co/api/models?author=ggml-org&search=Qwen3.5)).
- **Licencias y contexto** según las cards oficiales: Qwen3.5 ([a](https://huggingface.co/Qwen/Qwen3.5-2B)), Qwen3 ([a](https://huggingface.co/Qwen/Qwen3-4B)) y 2507 ([a](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)). La cabecera del GGUF de unsloth también declara `general.license apache-2.0` ([a](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf)).
- **No se deben mezclar quantizers.** Los de bartowski pesan unos 272 MB más (por ejemplo, 4B Q4_K_M = 3.013.027.808 B). Unos 94 MB corresponden a capas MTP (block_count 33, nextn) y el resto a otra receta de cuantización. *Corregido*: no todo el exceso es MTP ([a](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf)).

### 1.3 Elección

**RECOMENDADO: Qwen3.5-4B Q4_K_M**
- Descarga, fijada a commit: `https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf` ([b](https://huggingface.co/api/models/unsloth/Qwen3.5-4B-GGUF/tree/main)).
- 2.740.937.888 B. sha256 `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`. Coincide con `x-linked-etag`, que sirve para comprobarlo antes de descargar (b).
- Uso: **solo** en dispositivos de 8 GB o más que pasen la comprobación de memoria en runtime (§2.6). *Corregido por la verificación:* no se activa por defecto en iPhone de 8 GB sin esa comprobación. Con otro runtime (LiteRT-LM), el 4B alcanza picos de 4,4 a 5,7 GB ([b](https://huggingface.co/litert-community/Qwen3.5-4B)).
- Variante para Android, pendiente del benchmark S1: `Qwen3.5-4B-Q4_0.gguf` (2.583.221.408 B). KleidiAI solo acelera Q4_0 y Q8_0 (§2.2). Su sha256 hay que fijarlo a partir de `x-linked-etag`.

**LIGERO: Qwen3.5-2B Q4_K_M**
- Descarga: `https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf` ([b](https://huggingface.co/api/models/unsloth/Qwen3.5-2B-GGUF/tree/main)). **Pendiente:** sustituir `main` por el commit (cabecera `x-repo-commit`) antes de publicar.
- 1.280.835.840 B. sha256 `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223`.
- Uso: modelo por defecto en dispositivos de 6 GB y alternativa cuando el Recomendado no cabe. Variante para Android: Q4_0 (1.214.873.856 B).

**Plan B (conservador): Qwen/Qwen3-4B-GGUF Q4_K_M**
- Descarga oficial: `https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf`.
- sha256 `7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5` ([a](https://huggingface.co/api/models/Qwen/Qwen3-4B-GGUF/tree/main)).
- *Corregido:* se temía que GATED_DELTA_NET cayera a CPU en Metal, pero estaba exagerado. En `Metal.csv` solo falta head_size=16, y Qwen3.5 usa 128, que sí está soportado ([a](https://github.com/ggml-org/llama.cpp/blob/master/docs/ops/Metal.csv)). El plan B se mantiene porque es un GGUF oficial con arquitectura clásica. Su coste: KV de 144 KiB por token frente a 32 KiB (§2.3).
- Plan B ligero: ggml-org Qwen3-1.7B Q4_K_M (1.282.439.264 B), mejor que el Q8_0 oficial de 1.834.426.016 B ([a](https://huggingface.co/api/models/ggml-org/Qwen3-1.7B-GGUF/tree/main)).

**Premium, fuera de v1:** Qwen3.5-9B IQ4_XS o Q4_K_M, solo en Android de 12 GB o más (c).

### 1.4 Reglas de uso

- **Modo non-thinking, con la plantilla fijada en el código Rust.** Así no dependemos de la plantilla que traiga el GGUF:
  - Oficial: la 4B y la 9B arrancan en thinking; la 0.8B y la 2B, en non-thinking. El soft switch `/think` no está soportado ([a](https://huggingface.co/Qwen/Qwen3.5-4B/blob/main/chat_template.jinja)).
  - *Corregido:* la plantilla incrustada en los GGUF de unsloth (4B y 9B) **es non-thinking por defecto** y cambia el render de `tool_call.arguments`. La de bartowski es igual a la oficial ([a](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf)).
  - llama-cpp-2 no interpreta Jinja: `apply_chat_template` usa el motor simple de libllama y no admite `enable_thinking` ([a](https://github.com/utilityai/llama-cpp-rs/blob/0.1.161/llama-cpp-2/src/model.rs)). Hay que renderizar con minijinja o añadir a mano `<think>\n\n</think>\n\n` después de `<|im_start|>assistant\n`.
  - La 0.8B y la 2B tienden a entrar en bucle en modo thinking ([a](https://huggingface.co/Qwen/Qwen3.5-2B)).
- **Integridad de las descargas:** URL con `/resolve/<commit>/`, sha256 comprobado y espejo propio (c).
- **MTP desactivado** (PR #22673, [a](https://github.com/ggml-org/llama.cpp/pull/22673)). La issue #25618 sigue abierta: la salida greedy diverge en modelos cuantizados ([a](https://github.com/ggml-org/llama.cpp/issues/25618)).
- **Visión (mmproj) desactivada en v1.** La issue #30742 informa de calidad inferior a transformers con qwen35 ([a](https://github.com/ggml-org/llama.cpp/issues/30742)).
- **Español:** Qwen3 lo incluye expresamente entre sus 119 idiomas ([a](https://qwenlm.github.io/blog/qwen3/)). Qwen3.5 dice "201 languages", pero no hay lista que confirme el español (**NV**, [a](https://github.com/QwenLM/Qwen3.8)). Hace falta una evaluación propia (S4).
- **Catálogo de modelos configurable** (manifiesto descargable). Qwen publicó 3.5, 3.6 y 3.8 en 2026 (c).

---

## 2. Motor de inferencia

### 2.1 Elección y versión

- **llama.cpp vía `llama-cpp-2 = "=0.1.161"`** (publicado el 2026-11-03, MIT OR Apache-2.0) ([a](https://crates.io/crates/llama-cpp-2)).
- `llama-cpp-sys-2 0.1.161` trae **llama.cpp v0.6.0** (commit `d81235049384534c167caea52b85a694f6103d14`, 2026-10-05) ([a](https://github.com/utilityai/llama-cpp-rs/tree/0.1.161/llama-cpp-sys-2)).
  - Esa versión incluye la arquitectura `qwen35`, que requiere la build b7990 o posterior (PR #19468, 2026-02-10) ([a](https://github.com/ggml-org/llama.cpp/pull/19468)).
  - *Corregido:* el requisito real es ≥ b7990, no la v0.9.0 de upstream (2026-11-04) ([a](https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0)).
  - La rama main de llama-cpp-rs ya apunta a v0.9.0 (commit d94c594) ([a](https://github.com/utilityai/llama-cpp-rs/commits/main/llama-cpp-sys-2/llama.cpp)) y trae bindings pregenerados que eliminan libclang (PR #1111) ([a](https://github.com/utilityai/llama-cpp-rs/pull/1111)). Plan: pasar a 0.1.162+ cuando se publique (c).
- **Por qué este motor:**
  - GGUF de Qwen3 y Qwen3.5, embeddings con pooling Last y Rank, sampler completo con gramáticas GBNF ([a](https://docs.rs/llama-cpp-2/0.1.161/llama_cpp_2/sampling/struct.LlamaSampler.html)), Metal en iOS y KleidiAI en Android.
  - NobodyWho lo usa en producción con Flutter + Rust ([b](https://github.com/nobodywho-ooo/nobodywho/blob/main/nobodywho/core/Cargo.toml)). Matiz: usan un fork con llama.cpp v0.8.0 y publican OpenCL y Vulkan en Android.
- **Requisitos de build:**
  - bindgen 0.72.1 necesita libclang ([a](https://github.com/utilityai/llama-cpp-rs/pull/1111)). En local ya están libclang 23.1 y cmake 4.4.5.
  - Faltan rustup, el target `aarch64-linux-android` y cargo-ndk ([a](https://crates.io/crates/llama-cpp-sys-2)).
- **Plan B de motor:** MNN 3.6.2 (2026-10-29). Soporta Qwen3 y Qwen3.5 con NPU Hexagon, OpenCL y Metal, pero no tiene binding Rust para LLM y exige convertir a `.mnn` ([a](https://github.com/alibaba/MNN/releases/tag/3.6.2)).
- **Descartados:**
  - MLC-LLM: sin releases desde v0.1.dev0 ([a](https://github.com/mlc-ai/mlc-llm)).
  - ExecuTorch: hay que exportar cada modelo desde Python y el crate Rust es de terceros ([a](https://github.com/pytorch/executorch/tree/main/examples/models/qwen3)).
  - mistral.rs y candle: sin GPU en Android y con bugs en iOS ([a](https://github.com/EricLBuehler/mistral.rs/issues/1903)).
  - Cactus: el plugin está archivado ([a](https://github.com/cactus-compute/cactus-flutter)).

### 2.2 Configuración por plataforma

| Parámetro | Android (aarch64-linux-android) | iOS (aarch64-apple-ios) |
|---|---|---|
| Features de Cargo | `default-features=false`, `["common","android-shared-stdcxx"]` | `default-features=false`, `["common"]`. Metal se activa solo; la feature `metal` no tiene efecto ([a](https://github.com/utilityai/llama-cpp-rs/blob/0.1.161/llama-cpp-sys-2/build.rs)) |
| Backend | CPU, `n_gpu_layers=0` (c) | Metal, con `n_gpu_layers` por defecto = -1, es decir, todas las capas (`999` sobra) ([a](https://github.com/ggml-org/llama.cpp/blob/v0.6.0/src/llama-context.cpp)). En el simulador, 0 |
| Cuantización | Q4_0 o Q4_K_M según S1. KleidiAI solo acelera Q4_0 y Q8_0 ([a](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-cpu/kleidiai/kleidiai.cpp)) | Q4_K_M |
| Hilos | `n_threads=4` para decode y `n_threads_batch` = núcleos grandes (4-6), sin núcleos de eficiencia (c). El ejemplo oficial usa clamp(nproc−2, 2, 4) ([a](https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.android/lib/src/main/cpp/ai_chat.cpp)) | clamp(núcleos−2, 1, 8) ([a](https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.swiftui)) |
| `n_ctx` | 8192 con Qwen3.5 (KV pequeño, §2.3) | 8192 |
| Presupuesto de prompt RAG | ≤1.500 tokens; el TTFT es la métrica principal (c) | ≤4.000 tokens (c) |
| `n_batch` / `n_ubatch` | 512 (256 en gama media) | 512 |
| Tipo de KV | f16 con Qwen3.5; q8_0 con el plan B Qwen3 (V cuantizada obliga a usar flash-attn) ([a](https://github.com/ggml-org/llama.cpp/blob/v0.6.0/src/llama-context.cpp)) | f16 |
| mmap | Sí | Sí, más el entitlement `extended-virtual-addressing` ([a](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.extended-virtual-addressing)) |
| Memoria | — | Entitlement `increased-memory-limit` (solo funciona en algunos modelos; la app debe funcionar sin él) ([a](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)) |

**Android: variantes de compilación de la CPU**

- Base obligatoria: `GGML_CPU_KLEIDIAI=ON`. Durante la build descarga KleidiAI v1.24.0, así que la CI necesita red ([a](https://github.com/utilityai/llama-cpp-rs/blob/0.1.161/llama-cpp-sys-2/build.rs)). Nadie ha validado públicamente esta opción a través del crate (a: no hay issues ni PRs al respecto).
- **Variante B (inicial):** una sola `.so`, compatible con native-assets (§4).
  - `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16` ([a](https://github.com/utilityai/llama-cpp-rs/pull/1067)), y en runtime comprobar `HWCAP_ASIMDDP` con `getauxval`. Sin dotprod, la IA generativa se desactiva (c).
  - Por qué: el `-march=armv8-a` por defecto es "several times slower", y compilar con `+i8mm` en una CPU sin i8mm provoca SIGILL ([a](https://github.com/utilityai/llama-cpp-rs/pull/1067)).
- **Variante A (la que recomienda la verificación):** feature `dynamic-backends` (GGML_BACKEND_DL + CPU_ALL_VARIANTS), que despacha dotprod, i8mm, SVE o SME en runtime, igual que el ejemplo oficial llama.android ([a](https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.android/lib/build.gradle.kts)).
  - Implica `dynamic-link`: varias `.so` más `libc++_shared.so`, que hay que empaquetar a mano en jniLibs ([a](https://developer.android.com/ndk/guides/cpp-support)).
  - Es incompatible con `GGML_CPU_ARM_ARCH`.
  - El backend native-assets solo empaqueta el cdylib de Rust ([b](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/manual/integrate/03-native-assets.md)).
  - Se decide en S1.
- **Opciones que no se pueden cambiar por entorno:**
  - `GGML_NATIVE`, `GGML_LLAMAFILE` y `GGML_OPENMP` se fijan después de reenviar las variables `GGML_*`.
  - Las `LLAMA_*` no se reenvían, así que `LLAMA_OPENSSL` no se puede desactivar sin parchear ([a](https://github.com/utilityai/llama-cpp-rs/blob/0.1.161/llama-cpp-sys-2/build.rs)).
- **GPU en Android (fuera de v1):**
  - OpenCL está verificado en Adreno 750, 810, 830 y 840 ([a](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md)). Si se usa, debe ir como backend dinámico con `<uses-native-library android:name="libOpenCL.so" android:required="false"/>` ([a](https://developer.android.com/guide/topics/manifest/uses-native-library-element)).
  - No usar Vulkan: hay bugs abiertos en Adreno 840 ([a](https://github.com/ggml-org/llama.cpp/issues/30654)), Adreno 830 ([a](https://github.com/ggml-org/llama.cpp/issues/28635)) y Mali-G710 ([a](https://github.com/ggml-org/llama.cpp/issues/30920)).
  - No usar Hexagon: con HTP v73, GATED_DELTA_NET y FLASH_ATTN fallan y producen texto basura ([a](https://github.com/ggml-org/llama.cpp/issues/29473)). Además, la NPU hace el prefill entre 1,27 y 1,62 veces más lento y gasta hasta un 51 % más de batería ([b](https://arxiv.org/abs/2605.27435)).

**iOS**
- Solo se puede compilar en macOS con Xcode (§4).
- `GGML_METAL_EMBED_LIBRARY` compila los shaders en runtime y la primera carga paga ese coste ([a](https://github.com/utilityai/llama-cpp-rs/blob/0.1.161/llama-cpp-sys-2/build.rs)). Conviene un precalentamiento al arrancar (c).
- **Reutilizar el modelo cargado en vez de recargarlo:** tras liberarlo, `phys_footprint` se queda unos 525 MB por encima, y hasta 850 MB tras varias recargas (#30556, abierta) ([a](https://github.com/ggml-org/llama.cpp/issues/30556)).

**Común**
- **Cancelación:**
  - La versión 0.1.161 no expone el abort callback (#1180; el PR #1181 sigue abierto). Cuando se exponga, en Metal solo actuará antes de enviar trabajo a la GPU ([a](https://github.com/utilityai/llama-cpp-rs/issues/1180)).
  - Mientras tanto, un `AtomicBool` comprobado en cada token y el prefill troceado en bloques de `n_batch`.
- **Fallos nativos:** un `abort()` o `GGML_ASSERT` de C++ mata el proceso y `catch_unwind` no lo captura. La inferencia va en un hilo dedicado (§4) (c).

### 2.3 Memoria (cálculo de la KV cache)

**Fórmula (c):**
- KV por token = 2 (K y V) × capas de atención completa × cabezas KV × head_dim × bytes por elemento.
- Datos de los config.json oficiales: Qwen3.5-4B ([a](https://huggingface.co/Qwen/Qwen3.5-4B/blob/main/config.json)), Qwen3.5-9B ([a](https://huggingface.co/Qwen/Qwen3.5-9B/blob/main/config.json)) y Qwen3-4B ([a](https://huggingface.co/Qwen/Qwen3-4B/blob/main/config.json)).

| Modelo | Capas de atención × cabezas KV × dim | KV f16 por token | KV a 8K | Estado recurrente | Pesos | Total estimado a 8K (c)* |
|---|---|---|---|---|---|---|
| Qwen3.5-4B | 8 (de 32) × 4 × 256 | 32.768 B | 256 MiB | ~48 MiB (24 capas × 32 × 128 × 128 × 4 B) + ~2,3 MiB de conv | 2,74 GB | ≈3,1 GB |
| Qwen3.5-9B | 8 (de 32) × 4 × 256 | 32.768 B | 256 MiB | ~48 MiB | 5,68 GB | ≈6,0 GB |
| Qwen3.5-2B | (según informe) | ~12 KiB | ~96 MiB | ~18 MiB | 1,28 GB | ≈1,4 GB |
| Qwen3-4B (plan B) | 36 × 8 × 128 | 147.456 B | 1.152 MiB (q8_0: 612) | — | 2,50 GB | ≈3,7 GB con f16 / ≈3,1 GB con q8_0 |
| Qwen3-1.7B y 0.6B | 28 × 8 × 128 | 114.688 B | 896 MiB (q8_0: 476) | — | 1,28 / 0,43 GB | — |

\* No incluye los buffers de cómputo de llama.cpp, que no se han medido; con `n_ubatch` 512 se estiman en "cientos de MiB" (c).

Otros componentes y factores:
- **Otros modelos residentes:** embedder Q8_0, 0,64 GB (§3); reranker, 0,64 GB (§3).
- **CPU_REPACK:** reempaqueta en RAM anónima, fuera del mmap, los pesos Q4_0, Q4_K, Q5_K, Q6_K, Q8_0, IQ4_NL y MXFP4. *Corregido:* no solo Q4_0 ([a](https://github.com/ggml-org/llama.cpp/blob/v0.6.0/ggml/src/ggml-cpu/repack.cpp)). En CPU, los pesos cuentan para el LMK de Android y el jetsam de iOS. `GGML_CPU_REPACK=OFF` conserva el mmap a costa de velocidad. KleidiAI también reempaqueta Q4_0 y Q8_0 ([b](https://github.com/ggml-org/llama.cpp/discussions/22791)).
- **Contraste con medidas de terceros:** Qwen3.5-2B en llama.cpp con un iPhone 17 Pro alcanza un pico de 1.479 MB, coherente con la estimación ([b](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42)). Qwen3.5-4B con LiteRT-LM tiene picos de 4,43 a 5,74 GB ([b](https://huggingface.co/litert-community/Qwen3.5-4B)): la estimación para llama.cpp podría ser optimista.

### 2.4 Rendimiento: estimado frente a medido

> **No hay mediciones propias.** Todas las cifras son de terceros (b), con otros runtimes, modelos o cuantizaciones, o son extrapolaciones propias (c). El rendimiento real se medirá en S1 y S2 (pp512/tg128, en frío y en caliente, y TTFT).

| Dispositivo | Runtime / backend | Modelo | Prefill (t/s) | Decode (t/s) | Pico RAM | Ev. |
|---|---|---|---|---|---|---|
| iPhone 17 Pro (A19 Pro) | llama.cpp Metal | Qwen3.5-2B, ~4 bits | — | 39,1 | 1.479 MB | [b](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42) |
| iPhone 17 Pro | MLX-Swift | Qwen3.5-2B | — | 61,2 | 1.279 MB | [b](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42) |
| iPhone 17 Pro | LiteRT-LM Metal (int8 / mixed-int4) | Qwen3.5-4B | — | 9,3 / 11,4 | 4,98 / 5,74 GB | [b](https://huggingface.co/litert-community/Qwen3.5-4B) |
| Pixel 8a (8 GB) | LiteRT-LM CPU int4 | Qwen3.5-4B | — | 6,3 | 4,43 GB | [b](https://huggingface.co/litert-community/Qwen3.5-4B) |
| Galaxy S26 | LiteRT-LM CPU int8 | Qwen3.5-4B | — | 8,93 | — | [b](https://huggingface.co/litert-community/Qwen3.5-4B) |
| Galaxy S23 (8 Gen 2) | llama.cpp b9071 CPU, 6 hilos | Qwen3.5-2B Q4_K_M | 25,60 | 14,63 | — | [b](https://github.com/ggml-org/llama.cpp/discussions/22791) |
| Galaxy S23 | OpenCL (Adreno 740, sin soporte oficial) / HTP | idem | 42,75 / 39,22 | 10,77 / 4,73 | — | [b](https://github.com/ggml-org/llama.cpp/discussions/22791) |
| Pixel 7 Pro | llama-cpp-rs CPU con dotprod | Ministral-3B Q4_K_M | ~23 (1,4k tokens en ~61 s; ~175 s sin dotprod) | ×1,3–1,7 frente a sin dotprod | — | [b](https://github.com/utilityai/llama-cpp-rs/pull/1067) |
| Snapdragon 8 Elite Gen 5 | Qualcomm GENIEX_LLAMACPP q4_0 | Qwen3-4B | — | 19,9–21,7 (ctx 512) / 5,8–12,5 (ctx 4096) | — | [b](https://huggingface.co/qualcomm/Qwen3-4B) |
| A19 Pro | llama.cpp Metal | Phi-2 Q4_0 / Mistral-7B Q4_0 | 690 / 258,8 | 36,0 / 12,7 | — | [b](https://github.com/ggml-org/llama.cpp/discussions/4508) |

Notas sobre las mediciones de terceros:
- La prueba del S23 se hizo con `--mmap 0`, Q4_K_M y un Adreno 740 sin soporte oficial de OpenCL. *Corregido:* no permite concluir que "la CPU es siempre la más rápida" ([b](https://github.com/ggml-org/llama.cpp/discussions/22791)).

Extrapolaciones propias:
- **Decode (c, NV):** Qwen3-4B Q4_0 en llama.cpp Metal daría unos 14 t/s en A16, 15-16 en A17 Pro y unos 18 en A18 Pro. Prefill de 100 a 170 t/s en A17 y A18 ([NV](https://github.com/ggml-org/llama.cpp/discussions/4508)).
- **TTFT en Android con CPU (c):** con un prefill de 20 a 30 t/s, un prompt de 1.500 tokens tardaría entre 50 y 75 s. Por eso el presupuesto de contexto es corto y conviene reutilizar el KV entre turnos.

### 2.5 Térmica

- **Android:**
  - `PowerManager.getThermalHeadroom` está disponible desde API 30 y `AThermal_getThermalHeadroom` (NDK) desde API 31.
  - No hay que llamarlas más de una vez cada 10 s; si no, devuelven NaN.
  - Orientación: ≥0,85 ≈ LIGHT, ≥0,95 ≈ MODERATE y >1,0 ≈ SEVERE ([a](https://developer.android.com/games/optimize/adpf/thermal)).
- **iOS:** `ProcessInfo.thermalState` ([a](https://developer.apple.com/documentation/foundation/processinfo/thermalstate)).
- **Medidas de terceros:**
  - En un Xiaomi 14 Pro (8 Gen 3) con llama.cpp en CPU, el núcleo prime baja casi a la mitad de frecuencia en sesiones largas. En un iPad M1 se llega al estado "serious" ([b, NV](https://arxiv.org/abs/2410.03613)).
  - Los benchmarks publicados suelen medirse en frío, así que sobreestiman el rendimiento sostenido (c).
- **Política (c):**
  - Headroom ≥0,85 o estado `.serious`: bajar `n_threads` a 2 y pausar la indexación.
  - Headroom >1,0 o estado `.critical`: detener la generación tras el token en curso y avisar.
  - La indexación masiva y los embeddings solo se hacen con el móvil cargando y en reposo.

### 2.6 Dispositivos soportados

**Requisitos base:**
- **Android:** API 30 o superior (decisión de §4), arm64-v8a y CPU con dotprod (armv8.2-a) para la IA generativa (c, por la variante B).
- **iOS:** 16.0 o superior (§5). Familia de GPU Apple7 (A14 o posterior), necesaria para el matmul simdgroup de Metal ([a](https://github.com/ggml-org/llama.cpp/issues/30556)).

**Comprobación en runtime:**
- En iOS, `os_proc_available_memory()` devuelve el límite menos el footprint de la app. Es orientativo y no hay que cachearlo ([a](https://developer.apple.com/documentation/os/os_proc_available_memory)).
- Apple no publica el límite de memoria por app ([a](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)).
- En Android, la API de memoria disponible se concretará en S1.

| Perfil | RAM total (c) | Memoria libre exigida antes de cargar (c, a calibrar en S1/S2) | LLM | Embeddings / reranker | OCR y FTS5 |
|---|---|---|---|---|---|
| Sin IA generativa | < 6 GB | — | Ninguno (opción experimental: Qwen3.5-0.8B Q4_K_M, 532 MB) | Qwen3-Embedding si cabe; si no, solo FTS5 | Sí. El escáner de ML Kit exige ≥1,7 GB ([a](https://developers.google.com/ml-kit/vision/doc-scanner/android)) |
| Ligero | 6 GB | ≥ 2,5 GB (≈1,4 GB del LLM + 0,64 del embedder + buffers) | Qwen3.5-2B | Embedder sí; reranker no | Sí |
| Recomendado | ≥ 8 GB | ≥ 4,0 GB (≈3,1 GB del LLM + buffers; el embedder se descarga si no cabe) | Qwen3.5-4B; si no pasa la comprobación, Ligero | Embedder; reranker bajo demanda | Sí |
| Premium (fuera de v1) | Android ≥ 12 GB | ≥ 7 GB | Qwen3.5-9B | Ídem | Sí |

---

## 3. Embeddings y estrategia RAG local

### 3.1 Modelo de embeddings

| Modelo | Fichero / bytes | Licencia | Dim. / contexto | Con llama-cpp-2 0.1.161 | Decisión |
|---|---|---|---|---|---|
| **Qwen3-Embedding-0.6B** | `Qwen/Qwen3-Embedding-0.6B-GGUF` @370f27d7, `Qwen3-Embedding-0.6B-Q8_0.gguf`, 639.150.592 B (609,5 MiB) ([a](https://huggingface.co/api/models/Qwen/Qwen3-Embedding-0.6B-GGUF/tree/main)) | Apache-2.0 | 1024 (MRL de 32 a 1024) / 32.768 ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)) | Carga (arch qwen3, `pooling_type=3` LAST, `add_eos_token=True`) | **ELEGIDO** |
| Qwen3-Reranker-0.6B | `ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF` @a02f48bb, 639.153.184 B ([a](https://huggingface.co/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF)) | Apache-2.0 | — / 40.960 (pooling RANK) | Carga | Opcional, desactivado por defecto |
| granite-embedding-97m-multilingual-r2 | Conversión propia con `convert_hf_to_gguf.py`. Terceros: ~111-115 MB en Q8_0 | Apache-2.0 | 384 / 32.768 ([a](https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2)) | Carga: modern-bert y el pre-tokenizer granite-embed-multi-97m ya están en v0.6.0 (a) | Candidato para un perfil ultraligero; hay que validar la paridad (S4) |
| EmbeddingGemma 2 | `ggml-org/embeddinggemma-2-GGUF`, Q8_0 de 309.855.456 B ([a](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/tree/main)) | Apache-2.0 | 768 / 8.192 (el GGUF declara 262.144) | **NO carga**: la arch gemma-embedding2 llegó con el PR #30054, después de v0.6.0 ([a](https://github.com/ggml-org/llama.cpp/pull/30054)) | Reevaluar cuando el crate traiga v0.9.0 (c) |
| EmbeddingGemma-300m | 333.590.944 B | Gemma, con acceso restringido | 768 / 2K ([a](https://ai.google.dev/gemma/docs/embeddinggemma/model_card)) | — | Descartado por la licencia |
| multilingual-e5-small / bge-m3 | — / 634.553.760 B en Q8_0 | MIT | 384 con 512 tokens / 1024 ([a](https://huggingface.co/intfloat/multilingual-e5-small), [a](https://huggingface.co/BAAI/bge-m3)) | — | Descartados (peor calidad, o el mismo peso con menos calidad) |

Notas sobre la tabla:
- **Calidad publicada por Qwen** ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)):
  - Qwen3-Embedding-0.6B: MMTEB Mean(Task) 64,33 y Retrieval 64,64.
  - BGE-M3 en la misma tabla: 59,56.
- **Otros fabricantes:** EmbeddingGemma 2 da 61,36 ([a](https://huggingface.co/google/embeddinggemma-2)); Granite-97m da 60,3 en ML Retrieval(18) ([a](https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2)).
- Las suites no son idénticas, así que la comparación es aproximada (c).
- *Corregido:* 609,8 MiB es el tamaño del LLM Qwen3-0.6B; el embedder pesa 609,5 MiB.
- **Descarga:** `https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf`, sha256 `06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439` ([a](https://huggingface.co/api/models/Qwen/Qwen3-Embedding-0.6B-GGUF/tree/main)).
- **Cuantización:** se mantiene Q8_0, que es el único cuantizado oficial además de f16. Nadie ha medido Q4_K_M en este modelo; el único estudio es de Jina, sobre otro modelo y con mean pooling ([b](https://jina.ai/news/optimizing-ggufs-for-decoder-only-embedding-models/)).

### 3.2 Integración en Rust

- **Contexto:** `with_embeddings(true)` y `with_pooling_type(LlamaPoolingType::Last)`.
  - Fijar `n_ctx` a mano (1.024–2.048, (c)).
  - `n_ubatch` ≥ tokens del fragmento ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF)).
  - Normalizar L2 en Rust ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B/blob/main/1_Pooling/config.json)).
- **Tokenización:** `tokenize(&[u8], add_special=true, parse_special=false)` ([a](https://docs.rs/llama-cpp-2/0.1.161/llama_cpp_2/vocab/struct.LlamaVocab.html)).
  - `parse_special=false` impide que el texto de las notas inyecte tokens especiales (c).
  - Comprobar con un **assert** que el último token es 151643 (`<|endoftext|>`); si falta, los embeddings se degradan sin dar error (#14234) ([a](https://github.com/ggml-org/llama.cpp/issues/14234)).
- **Consultas:** se antepone `Instruct: Given a search query in Spanish or English, retrieve passages from the user's personal notes that answer the query\nQuery:{q}`.
  - El formato va fijo y sin espacio tras `Query:`, porque el README de Qwen es incoherente en ese punto.
  - Los documentos van sin instrucción. Omitir la instrucción en la consulta resta entre un 1 % y un 5 % ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B/blob/main/config_sentence_transformers.json)).
- **Almacenamiento:**
  - Vectores de 1024 dimensiones normalizados, guardados como BLOB f16: 2 KB por fragmento, unos 20 MB por cada 10.000 (c).
  - Junto a cada vector, `model_id`, revisión y dimensión.
  - No truncar con MRL: Qwen no publica la pérdida de calidad a 512 o 256 dimensiones ([a](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)).
- **Reranker:**
  - El prompt se construye a mano, porque la plantilla incrustada trae fija la instrucción "web search".
  - Usa eos 151645 ([a](https://huggingface.co/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF)).
  - En dispositivos de 6 GB o menos nunca se carga a la vez que el LLM (c).

### 3.3 Estrategia RAG

1. **Fragmentación:** fragmentos de 200 a 400 tokens con algo de solapamiento y el título de la nota delante (c). Solo se re-embeben las notas modificadas, en un worker en segundo plano.
2. **SQLite:** `rusqlite 0.42.0` con la feature `bundled`, que trae SQLite 3.54.1 y compila FTS5; no existe una feature `fts5` ([a](https://crates.io/crates/libsqlite3-sys/0.40.0)). Se publicó el mismo 2026-11-11; la alternativa es 0.41.1, del 2026-10-28 ([a](https://crates.io/crates/rusqlite/versions)).
3. **Índice léxico:** tabla `chunks_fts` como FTS5 de contenido externo con `tokenize='unicode61 remove_diacritics 2'`. No se usa `porter`, que es solo para inglés. Una segunda tabla `trigram` es opcional, para subcadenas ([a](https://sqlite.org/fts5.html)).
4. **Índice vectorial:** tabla `chunk_vec(chunk_id, model, dim, emb BLOB)` y producto escalar por fuerza bruta en Rust. Los filtros se aplican antes de puntuar y la recall es exacta. Con 10.000 × 1024 serían unos pocos ms (c, sin medir).
   - No se usa sqlite-vec. *Corregido:* la 0.1.10-alpha ya trae ANN (DiskANN/IVF), pero sigue siendo pre-v1 ([a](https://github.com/asg017/sqlite-vec/releases/tag/v0.1.10-alpha.1)).
   - Tampoco vec1 v0.8 (ANN IVFADC) ([a](https://sqlite.org/vec1/doc/trunk/doc/vec1intro.md)).
   - Se reconsideraría por encima de ~10⁵ vectores (c).
5. **Consulta:** top-50 por BM25 + top-50 vectorial, fusionados con **RRF k=60** y pesos 1,0/1,0 ([b, NV](http://cormack.uwaterloo.ca/cormack/cormacksigir09-rrf.pdf); patrón de [b](https://alexgarcia.xyz/blog/2024/sqlite-vec-hybrid-search/index.html)). Después:
   - rerank opcional del top-20;
   - como máximo 2 o 3 fragmentos por nota;
   - de 5 a 8 fragmentos al LLM, dentro del presupuesto de §2.2 (c).
6. **Modelo de embeddings:** cambiarlo obliga a re-embeber todo el corpus, así que el índice va versionado.
7. **Coste de indexación:** sin cifra oficial. Indexar 1,3 M tokens en una CPU de gama media podría llevar decenas de minutos (c, NV). Se mide en S1.

---

## 4. Puente Flutter-Rust

### 4.1 Elección

**flutter_rust_bridge 2.13.0.** Crate, paquete Dart, codegen y `flutter_rust_bridge_hooks` publicados el 2026-08-23 ([a](https://crates.io/api/v1/crates/flutter_rust_bridge)).
- Ofrece llamadas tipadas async, `StreamSink` y `RustAutoOpaque`. Es Flutter Favorite, tiene 160/160 puntos y 597.463 descargas en 30 días ([a](https://pub.dev/packages/flutter_rust_bridge/score)).
- Alternativas descartadas:
  - rinf 8.11.0: busca mantenedor y funciona por mensajes, no por llamadas ([a](https://github.com/cunarist/rinf)).
  - uniffi-dart: experimental, no está en crates.io y va por uniffi 0.31.2 ([a](https://github.com/Uniffi-Dart/uniffi-dart)).
  - ffigen manual: habría que escribir a mano async y streams ([a](https://docs.flutter.dev/platform-integration/bind-native-code)).

**Backend native-assets:** `flutter_rust_bridge_codegen integrate --integration-backend native-assets --rust-crate-dir rust` ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/manual/integrate/03-native-assets.md)).
- Motivo: CargoKit (CocoaPods) es incompatible con SwiftPM, que viene activo por defecto desde Flutter 3.44, y Flutter avisa de que eso acabará siendo un error ([a](https://github.com/fzyzcjy/flutter_rust_bridge/issues/3202)).
- Además, el registro de CocoaPods pasa a solo lectura el 2026-12-02 ([a](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)).

### 4.2 Condiciones (la verificación dio por no sólida la combinación inicial)

- **native-assets falla con minSdk 24:**
  - `native_toolchain_rust 1.0.7` fija `apiTarget = '35'` para clang y el linker de Android. Las relocalizaciones RELR provocan SIGSEGV en API < 30 (#113, abierta; el fix, PR #122, es del 2026-11-11 y no está fusionado) ([a](https://github.com/GregoryConrad/native_toolchain_rust/issues/113)).
  - **Decisión: minSdk 30.** Además, se fija `native_toolchain_rust` con `dependency_overrides` y se valida en S3 con API 30-34. Compilar contra las cabeceras de API 35 podría introducir símbolos que no existen en esas versiones (c, NV).
  - Si S3 falla: CargoKit en Android, que sí respeta minSdk.
- **Alineación a 16 KB:**
  - El hook usa el NDK de `flutter config android-ndk`, `ANDROID_NDK_HOME`, `ANDROID_NDK_PATH`, `ANDROID_NDK_ROOT` o, en último lugar, el más reciente instalado. **No usa el `ndkVersion` de Gradle** ([a](https://github.com/flutter/flutter/blob/3.47.9/packages/flutter_tools/lib/src/android/android_sdk.dart)).
  - Medidas: `flutter config --android-ndk ~/Android/Sdk/ndk/28.2.13676358`, o `-C link-arg=-Wl,-z,max-page-size=16384` en `.cargo/config.toml`. Verificar con `zipalign -c -P 16` ([a](https://developer.android.com/guide/practices/page-sizes)).
- **`rust-toolchain.toml`:** partir del que genera `integrate`, que incluye `x86_64-apple-ios`; el validador da error si falta un target. Solo se cambia `channel = "1.99.1"` ([a](https://static.rust-lang.org/dist/channel-rust-stable.toml)). También `crate-type = ["staticlib","cdylib"]` ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/manual/integrate/03-native-assets.md)).
- **Versiones fijadas exactas:**
  - codegen (`cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked`), `flutter_rust_bridge = "=2.13.0"` en Cargo, `flutter_rust_bridge: 2.13.0` en pubspec y `flutter_rust_bridge_hooks: 2.13.0`.
  - `native_toolchain_rust` también, porque `flutter_rust_bridge_hooks` pide `^1.0.4`.
  - Si no coinciden, salta un StateError en runtime ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/frb_dart/lib/src/main_components/entrypoint.dart)).
- **Riesgo de enlazado:** ya se ha visto un error de enlazado en iOS con llama-cpp-2 (`cpp-httplib not found`) ([b](https://github.com/fzyzcjy/flutter_rust_bridge/issues/3331)).

### 4.3 Diseño del puente

- **Objetos opacos separados:** `Store` (SQLite e índices) y `Engine` (LLM y embeddings), con métodos `&self` y sincronización interna. `RustAutoOpaque` usa un `tokio::sync::RwLock`, y un método `&mut self` bloquea el objeto entero mientras dura ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/guides/types/arbitrary/rust-auto-opaque/overview.md)).
- **Inferencia en un hilo o actor dedicado.** El pool por defecto de FRB tiene un hilo por CPU y competiría con los hilos de llama.cpp (c, deducido del código).
- **Tokens y progreso por `StreamSink<T>`.** Se comprueba el `Result` de `sink.add()` para detectar que Dart ha cerrado el stream ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/v2.13.0/frb_rust/src/for_generated/boilerplate.rs)).
- **Cancelación con token propio** (`Arc<AtomicBool>` o `CancellationToken`) ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/guides/how-to/cancel.md)).
  - No hacer `await` de `StreamSubscription.cancel()` en streams inactivos: se cuelga. Usar `unawaited(sub.cancel())` (#3473, abierta) ([a](https://github.com/fzyzcjy/flutter_rust_bridge/issues/3473)).
  - El fix #3366 solo está en 2.14.0-beta.2 ([a](https://github.com/fzyzcjy/flutter_rust_bridge/pull/3366)).
- **Panics:** `panic = "unwind"`, para que lleguen a Dart como `PanicException` ([a](https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/guides/types/translatable/return.md)).

### 4.4 Descarga de modelos

*Corregido:* la vía principal pasa a ser la del sistema operativo.
- **iOS:** `URLSession` en segundo plano ("These tasks continue to run even when your app is suspended") ([a](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)).
- **Android:** UIDT en API 34+ (permiso `RUN_USER_INITIATED_JOBS` y notificación obligatoria) y WorkManager con servicio en primer plano por debajo de 34 ([a](https://developer.android.com/develop/background-work/background-tasks/uidt)).
- Se hace con un plugin propio basado en Pigeon. Rust comprueba el sha256 (`sha2 0.11.1`, [a](https://crates.io/crates/sha2/0.11.1)) y el tamaño, e instala el fichero de forma atómica.
- **Alternativa dentro del proceso:** `ureq 3.5.1` (rustls + ring + webpki-roots, sin JNI) con reanudación por Range ([a](https://docs.rs/crate/ureq/3.5.1/features)).
- **No usar `reqwest` 0.13:** su verificador de plataforma exige inicializar JNI en Android ([a](https://github.com/rustls/rustls-platform-verifier)).

### 4.5 Toolchain

| Pieza | Versión | Ev. |
|---|---|---|
| Flutter / Dart | 3.47.9 estable (2026-10-29) / Dart 3.13.7. No usar la beta 3.50 | [a](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json) |
| Rust | 1.99.1 (hay que instalar rustup y los targets de Android e iOS) | [a](https://static.rust-lang.org/dist/channel-rust-stable.toml) |
| AGP / Gradle / KGP / JDK | 9.1.0 / 9.3.1 / 2.4.0 / 17 | [a](https://github.com/flutter/flutter/blob/3.47.9/packages/flutter_tools/lib/src/android/gradle_utils.dart) |
| compileSdk / targetSdk | 36 / 36 (Play exige 36 desde el 2026-08-31) | [a](https://developer.android.com/google/play/requirements/target-sdk) |
| minSdk | **30** (decisión; la plantilla trae 24) | (c) |
| NDK | 28.2.13676358 (alinea a 16 KB por defecto; obligatorio desde el 2027-02-01) | [a](https://developer.android.com/guide/practices/page-sizes) |
| iOS | Deployment target **16.0** (decisión; la plantilla trae 15.0). Flutter soporta de iOS 15 a 27 | [a](https://docs.flutter.dev/reference/supported-platforms) |
| Xcode | 26+, obligatorio para App Store desde el 2026-04-28. Solo existe en macOS | [a](https://developer.apple.com/news/upcoming-requirements/) |
| CI de iOS | GitHub Actions `macos-26` (arm64, 3 CPU M1, 7 GB): compilar llama.cpp será lento | [a](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) |

---

## 5. OCR en iOS y Android, y PDF

### 5.1 Comparativa

| | **iOS: Apple Vision (elegido)** | **Android: ML Kit v2 bundled (elegido)** | PP-OCRv6 en ONNX (plan B, aplazado) |
|---|---|---|---|
| API / versión | `VNRecognizeTextRequest` revision3 (iOS 16+, no deprecada) ([a](https://developer.apple.com/documentation/vision/vnrecognizetextrequestrevision3)). Opcionales: `RecognizeTextRequest` (iOS 18+) ([a](https://developer.apple.com/documentation/vision/recognizetextrequest)) y `RecognizeDocumentsRequest` (iOS 26+) ([a](https://developer.apple.com/videos/play/wwdc2025/272/)) | `com.google.mlkit:text-recognition:16.0.1` ([a](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)) | PaddleOCR v3.7.0 ([a](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html)) |
| Tamaño | 0, viene con el sistema | Unos 4 MB de descarga por script y ABI ([a](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)); unos 12,5 MB instalados por ABI (c, medido en el [AAR](https://dl.google.com/dl/android/maven2/com/google/mlkit/text-recognition-bundled-common/17.0.0/)) | Pesos: tiny 6,2 MB / small 31 MB ([a](https://huggingface.co/PaddlePaddle/PP-OCRv6_tiny_rec_onnx)). Runtime ORT: 34,2 MB instalado en arm64 (~12,9 MB con gzip) (c, [AAR](https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.31.1/)) |
| Licencia | Framework del sistema (SDK de Apple) | Términos de ML Kit: código cerrado, prohíbe la ingeniería inversa ([a](https://developers.google.com/ml-kit/terms)) | Apache-2.0 |
| Idiomas | es-ES y en-US en modo accurate desde iOS 14 ([b](https://zenn.dev/shu223/articles/textrecognition)). Apple no publica la lista: consultar `supportedRecognitionLanguages()` en runtime ([a](https://developer.apple.com/videos/play/wwdc2021/10041/)). La lista de Live Text no equivale a la de Vision (caso del sueco) ([b](https://developer.apple.com/forums/thread/765905)) | `es` con nivel Supported entre 31 idiomas latinos ([a](https://developers.google.com/ml-kit/vision/text-recognition/v2/languages)) | 46 idiomas latinos, incluidos español, catalán, euskera y gallego. *Corregido* ([a](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv6/PP-OCRv6.md)). Al diccionario le falta `¡` (c) |
| Impreso | Sí | Sí. Caracteres de ≥16×16 px; por encima de 24 px no se gana precisión ([a](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)) | Sí |
| Manuscrito | Sin soporte declarado (ninguna mención en docs ni WWDC); en foros varía entre revisiones ([b](https://developer.apple.com/forums/thread/707594)) | Sin soporte declarado. Digital Ink no sirve para fotos ([a](https://developers.google.com/ml-kit/vision/digital-ink-recognition)) | tiny 39,3 / small 61,1 en manuscrito EN (benchmark interno) ([a](https://huggingface.co/PaddlePaddle/PP-OCRv6_tiny_rec_onnx)) |
| Descarga necesaria | Ninguna; todo on-device ([a](https://developer.apple.com/documentation/vision/recognizing-text-in-images)) | Ninguna tras instalar. La variante unbundled falla hasta que descarga el modelo ([a](https://developers.google.com/ml-kit/tips/installation-paths)) | Pesos descargables. El runtime nativo tiene que ir en el binario (c, NV) |
| Privacidad | On-device | Las imágenes no salen, pero **se envían métricas y un identificador por instalación** ([a](https://developers.google.com/ml-kit/android-data-disclosure)) | Sin telemetría |

### 5.2 iOS

- **Configuración:** `.accurate`, `recognitionLanguages` = `["es-ES","en-US"]` en el orden del idioma del usuario (en accurate, el primer idioma decide el modelo) ([a](https://developer.apple.com/videos/play/wwdc2021/10041/)), `usesLanguageCorrection = true` y `customWords` con el vocabulario del usuario.
- **Regresión en iOS 27, modo accurate:** pierde líneas, devuelve texto invertido y mezcla homoglifos cirílicos. Un desarrollador mide un 65 % de acierto frente al 99,7 % de iOS 26 ([b](https://developer.apple.com/forums/thread/851862)).
  - El modo **`.fast` no está afectado** ([b](https://developer.apple.com/forums/thread/851862)).
  - Live Text también falla ([b](https://developer.apple.com/forums/thread/845452)).
  - No hay respuesta de Apple ni arreglo confirmado (NV).
  - **Mitigación (c):** heurísticas de calidad (líneas vacías, cirílico dentro de texto latino, poca cobertura) que repiten con `.fast`. Se guarda la versión del SO con cada resultado de OCR para poder repetirlo más adelante.
- **Confianza:** `confidence` va de 0 a 1 ([a](https://developer.apple.com/documentation/vision/vnrecognizedtext/confidence)), pero en accurate sale cuantizada en 0,3 / 0,5 / 1,0 ([b](https://developer.apple.com/forums/thread/695693)). No sirve para ordenar resultados.
- **Escáner:** `VNDocumentCameraViewController` (iOS 13+). Recorta, corrige la perspectiva y la iluminación, y funciona on-device ([a](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller)).
- **Integración:** plugin propio con Pigeon. **No** `google_mlkit_text_recognition`, que en iOS usa ML Kit y no Vision ([b](https://github.com/flutter-ml/google_ml_kit_flutter/tree/master/packages/google_mlkit_text_recognition)).

### 5.3 Android

- **Motor:** ML Kit bundled 16.0.1, con páginas de 16 KB soportadas desde 2024-08 ([a](https://developers.google.com/ml-kit/release-notes)).
  - La documentación da como minSdk 23 en el cuerpo y 21 en el resumen; con minSdk 30 da igual ([a](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)).
  - Hay que declararlo en **Data safety** y matizar el mensaje de "100 % local" ([a](https://developers.google.com/ml-kit/android-data-disclosure)).
  - El POM depende de play-services-base y basement ([a](https://dl.google.com/dl/android/maven2/com/google/mlkit/text-recognition/16.0.1/text-recognition-16.0.1.pom)). No está documentado si funciona sin GMS (NV): probarlo en un emulador AOSP desde Linux.
- **Escáner:** ML Kit Document Scanner `play-services-mlkit-document-scanner:16.0.0`. Requisitos: GMS, descarga de un módulo y ≥1,7 GB de RAM ([a](https://developers.google.com/ml-kit/vision/doc-scanner/android)).
  - Se preinstala con `ModuleInstallClient` durante el onboarding ([a](https://developers.google.com/android/guides/module-install-apis)); `GmsDocumentScanner` extiende `OptionalModuleApi` ([a](https://developers.google.com/android/reference/com/google/mlkit/vision/documentscanner/GmsDocumentScanner)).
  - No está documentado que funcione sin conexión una vez instalado (NV).
  - En Flutter: `cunning_document_scanner 3.1.0`, que usa VisionKit en iOS y ML Kit en Android, con recorte manual si no hay GMS ([b](https://github.com/vicajilau/cunning_document_scanner)).

### 5.4 Plan B con PP-OCRv6 (no entra en v1)

- **El runtime ORT tiene que ir en el binario.** Lo pagarían todos los usuarios (c).
- **Conflicto de versiones:** `oar-ocr 0.10.2` fija `ort =2.0.0-rc.13` (ORT 1.28) y no puede convivir con otra versión de `ort` por `links = "onnxruntime"`. *Corregido* ([a](https://crates.io/api/v1/crates/oar-ocr/0.10.2/dependencies)).
- **Si se activa:** ort directamente con un pipeline propio (detección DB y decodificación CTC), o rten/tract (NV).
- **No usar** `PP-OCRv5_mobile_rec`, que no tiene Ñ, Ú, ¿ ni ¡; sí sirve `latin_PP-OCRv5_mobile_rec` (c).
- **Latencia de referencia:** en un M4 con ORT, tiny tarda 0,35 s por imagen y small 1,29 s ([a](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv6/PP-OCRv6.en.md)). La demo de Android tarda 420 ms en una imagen de 5 líneas ([a](https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/cross_platform/android_deployment.html)).
- **Tesseract 5.5.4 descartado:** necesita ~300 ppp y preprocesado, y no reconoce manuscrito ([a](https://tesseract-ocr.github.io/tessdoc/ImproveQuality.html)).
- **Manuscrito:** si resulta clave, la vía es un VLM local, fuera de v1. Opciones: Qwen3-VL-2B o 4B en GGUF oficial con mmproj (2B Q4_K_M de 1.107.409.952 B + mmproj Q8_0 de 445.053.216 B) ([a](https://huggingface.co/api/models/Qwen/Qwen3-VL-4B-Instruct-GGUF/tree/main)), o el mmproj de Qwen3.5, con la issue #30742 pendiente ([a](https://github.com/ggml-org/llama.cpp/issues/30742)).

### 5.5 PDF

1. **Capa de texto, con API nativa:**
   - iOS: `PDFPage.string` (iOS 11+) ([a](https://developer.apple.com/documentation/pdfkit/pdfpage)).
   - Android: `PdfRenderer.Page.getTextContents()` (API 35), o `PdfRendererPreV` en Android 11-14 con S Extensions 13 ([a](https://developer.android.com/reference/android/graphics/pdf/PdfRendererPreV)).
   - Alternativa en Rust: `lopdf 0.47.0` (`extract_text`) dentro de `catch_unwind` ([a](https://crates.io/crates/pdf-extract/0.12.1)).
2. **Páginas sin texto (escaneadas):**
   - Rasterizar a ~300 ppp (c) con `PDFPage.thumbnail(of:for:)` en iOS o con `PdfRenderer.Page.render` en Android (bitmap ARGB_8888, una sola página abierta a la vez) ([a](https://developer.android.com/reference/android/graphics/pdf/PdfRenderer.Page)).
   - La imagen pasa después al OCR nativo.
3. **No usar `pdf-extract 0.12.1`:** duplica lopdf (depende de ^0.42) y tiene panics abiertos ([b](https://github.com/jrmuizel/pdf-extract/issues?q=is%3Aissue+is%3Aopen+panic)).

---

## 6. Librerías Flutter

Todas compilan en Flutter 3.47.9; la build de APK debug está verificada en local ([a](https://pub.dev/packages/flutter_quill/versions)). iOS no se ha compilado porque no hay Xcode.

| Uso | Paquete | Versión | Licencia | Notas |
|---|---|---|---|---|
| Editor | `flutter_quill` | 11.6.0 (Flutter ≥3.44) | MIT | Delta en JSON, guardado en SQLite por Rust. `EmbedBuilder` propios con IDs de Rust ([a](https://pub.dev/packages/flutter_quill)) |
| Puente | `flutter_rust_bridge` + `flutter_rust_bridge_hooks` | 2.13.0 | MIT | §4 |
| OCR, PDF y descargas nativas | plugin propio con `pigeon` | 30.0.2 | n/d | [a](https://pub.dev/packages/pigeon) |
| Escáner | `cunning_document_scanner` | 3.1.0 (minSdk 24, iOS 13) | n/d | [b](https://github.com/vicajilau/cunning_document_scanner) |
| Fotos y cámara del sistema | `image_picker` | 1.2.4 | n/d | Photo Picker en Android 13+; `retrieveLostData()` ([a](https://pub.dev/packages/image_picker)) |
| Ficheros | `file_picker` | 13.3.3 (iOS 14+) | MIT | API estática `pickFile`/`pickFiles` ([a](https://pub.dev/packages/file_picker)) |
| Rutas | `path_provider` | 2.1.6 | n/d | [a](https://pub.dev/packages/path_provider) |
| Compartir | `share_plus` | 13.3.1 | BSD-3 | `SharePlus.instance.share(ShareParams(...))`; `sharePositionOrigin` en iPad ([a](https://pub.dev/packages/share_plus)) |
| Recorte | `crop_your_image` (UI) + crate `image` en Rust | 2.0.1 | Apache-2.0 | [a](https://pub.dev/packages/crop_your_image). Alternativa: `image_cropper` 13.0.0 (BSD-3, Flutter ≥3.47, requiere `UCropActivity` en el manifiesto) ([a](https://pub.dev/packages/image_cropper)) |
| Estado | `flutter_riverpod`, `riverpod_annotation`, `riverpod_generator` | 3.5.0 / 4.0.8 / 4.0.10 | MIT | [a](https://pub.dev/packages/flutter_riverpod) |
| Modelos inmutables | `freezed`, `freezed_annotation`, `build_runner` | 4.0.3 / 3.1.0 / 2.17.1 | n/d | freezed 4.0.3 exige Dart 3.13 ([a](https://pub.dev/packages/flutter_riverpod)) |
| Navegación | `go_router` | 18.1.4 | BSD-3 | Declarado "feature-complete" ([a](https://pub.dev/packages/go_router/changelog)) |
| Pizarra | `perfect_freehand` + `Listener` + `CustomPainter` propios | 2.5.2+1 | MIT | [a](https://pub.dev/packages/perfect_freehand) |
| Doble toque del Pencil (opcional) | `apple_pencil_double_tap` | 2.0.0 (Flutter ≥3.47) | n/d | [b](https://pub.dev/packages/apple_pencil_double_tap) |
| Permisos | Ninguno en v1. Si hiciera falta: `permission_handler` 12.0.3 (compileSdk 36) | — | MIT | La 13.0.2 obliga a compileSdk 37 y cambia el comportamiento de `permanentlyDenied` ([a](https://github.com/Baseflow/flutter-permission-handler/blob/main/permission_handler/CHANGELOG.md)) |

**Editor: precauciones**
- *Corregido:* en iOS, el backspace no quita la viñeta o la casilla si el bloque vacío es la **primera línea** del documento (#2334, abierta) ([a](https://github.com/singerdmx/flutter-quill/issues/2334)). Mitigación (c): título obligatorio delante del cuerpo y botón "quitar formato".
- Otros bugs abiertos: #2774, regresión de selección en iOS en 11.6.0 ([a](https://github.com/singerdmx/flutter-quill/issues/2774)), y #2344, casillas pequeñas en móvil. Ampliar el área táctil con un builder propio.
- Para el Apple Pencil, activar `QuillEditorConfig.enableScribble`. No hay soporte de Scribe en Android ([a](https://github.com/singerdmx/flutter-quill/blob/master/lib/src/editor/config/editor_config.dart)).
- Flutter 3.44 rompió los tres editores al cambiar la API de entrada de texto. flutter_quill lo arregló en 2 días. Hay que **fijar la versión de Flutter en la CI** y probar el editor antes de cada actualización ([a](https://github.com/singerdmx/flutter-quill/blob/master/CHANGELOG.md)).

**Pizarra**
- Presión: `p / pressureMax`, porque en iOS `pressureMin` = 0 y la fuerza llega sin normalizar. Hay que proteger el caso `pressureMax <= pressureMin` ([a](https://api.flutter.dev/flutter/gestures/PointerEvent/pressure.html)).
- Modo "solo stylus" en cuanto aparece un `PointerDeviceKind.stylus`; `invertedStylus` hace de goma; los dedos sirven para desplazar y hacer zoom.
- Un trazo se descarta si llega `PointerCancelEvent`, porque Flutter no expone `FLAG_CANCELED` de Android ([a](https://developer.android.com/develop/adaptive-apps/cookbook/stylus-palm-rejection)).
- iOS no entrega `coalescedTouches`, así que hay que suavizar el trazo ([a](https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil)).
- Los trazos se guardan como puntos vectoriales en Rust.

**Permisos y manifiestos**
- **Info.plist:** `NSCameraUsageDescription` y `NSPhotoLibraryUsageDescription` ([a](https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription)).
- **AndroidManifest sin `CAMERA`:** si se declara y no está concedido, `ACTION_IMAGE_CAPTURE` lanza `SecurityException` ([a](https://developer.android.com/reference/android/provider/MediaStore#ACTION_IMAGE_CAPTURE)). Hay que revisar el manifiesto fusionado.
- **Sin el paquete `camera` (cámara en vivo) en v1.**

**Descartados**
- `appflowy_editor 6.2.0`: no compila en Flutter ≥3.44 ([a](https://github.com/AppFlowy-IO/appflowy-editor/issues/1204)) y su licencia es MPL-2.0/AGPL-3.0 ([a](https://pub.dev/api/packages/appflowy_editor/score)).
- `super_editor`: la 0.2.7 no compila; la 0.3.0-dev.52 es incompatible con quill y `super_keyboard` fija compileSdk 34 ([a](https://pub.dev/packages/super_editor/versions)).
- `scribble`: parado desde 2024 y en conflicto con freezed 3/4 ([a](https://pub.dev/packages/scribble)).
- `flutter_drawing_board`: no lee la presión real ([a](https://github.com/fluttercandies/flutter_drawing_board/blob/master/lib/src/painter.dart)).
- `google_mlkit_text_recognition` en iOS (ver §5.2).

**Versión mínima de Flutter:** 3.47, la exigen freezed 4.0.3, material_ui, image_cropper 13 y apple_pencil_double_tap (a).

---

## 7. Riesgos y preguntas abiertas

### 7.1 Riesgos

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Desde Linux no se puede compilar, firmar ni perfilar iOS (Metal, Vision, PDFKit, Pencil) ([a](https://docs.flutter.dev/platform-integration/ios/setup)) | CI en macOS (`macos-26`) y un iPhone físico para S2 |
| R2 | Memoria: Apple no publica el límite por app; LiteRT ve picos de 4,4 a 5,7 GB con el 4B; CPU_REPACK copia los pesos a RAM; en iOS queda memoria retenida al liberar el modelo (#30556) | Comprobación en runtime (§2.6), reutilizar el modelo, cargar por fases, Ligero por defecto |
| R3 | El prefill en CPU Android ronda 20-30 t/s y alarga mucho el TTFT | Presupuesto de ≤1.500 tokens, reutilizar el KV, medir el TTFT en S1 |
| R4 | `native_toolchain_rust` compila con API 35 y da SIGSEGV en API < 30 ([a](https://github.com/GregoryConrad/native_toolchain_rust/issues/113)) | minSdk 30, versión fijada, spike S3; si falla, CargoKit en Android |
| R5 | La alineación a 16 KB depende del NDK que encuentre Flutter, no del de Gradle | Forzar NDK r28 y verificar con `zipalign -P 16` |
| R6 | Dependemos de GGUF de terceros (unsloth), que pueden volver a subirse | Commit fijado, sha256 y espejo propio |
| R7 | El modo thinking por defecto cambia según el quantizer | Plantilla fijada en el código (§1.4) |
| R8 | Regresión del OCR de Vision en iOS 27, sin respuesta de Apple | Reintento con `.fast`, heurísticas, corpus de pruebas en CI |
| R9 | La telemetría de ML Kit choca con el mensaje de "100 % local" | Declararla; valorar PP-OCRv6 como motor principal en Android (Q6) |
| R10 | llama-cpp-2 sigue en 0.1.x y cambia mucho; trae llama.cpp v0.6.0, que no carga EmbeddingGemma 2 | Versión exacta fijada; subida planificada a 0.1.162+ |
| R11 | Los backends de GPU en Android tienen bugs (Vulkan, Hexagon) | CPU por defecto; OpenCL solo con lista blanca tras S1 |
| R12 | Cancelación limitada; un abort de C++ mata el proceso | Token por cada token generado, prefill troceado, hilo dedicado |
| R13 | Enlazado: `links="llama"` choca con otros crates que traen ggml; mezclar libc++ estático y compartido rompe la ODR ([a](https://developer.android.com/ndk/guides/cpp-support)); error de enlazado en iOS ([b](https://github.com/fzyzcjy/flutter_rust_bridge/issues/3331)) | Una sola copia de ggml; política única de libc++; S3 |
| R14 | KleidiAI no está validado a través del crate y necesita red durante la build | S1; caché o espejo para la CI |
| R15 | FRB depende de un mantenedor principal; la 2.14 sigue en beta; bug de cancelación de streams | Versiones fijadas; `unawaited(cancel())` |
| R16 | Calidad en español de Qwen3.5 sin verificar | Set de evaluación propio (S4) |
| R17 | Throttling térmico en sesiones largas | Política de §2.5 |
| R18 | Qwen publica con mucha frecuencia y la elección puede quedar obsoleta | Catálogo de modelos configurable |
| R19 | rusqlite 0.42.0 se publicó el mismo día | Usar 0.41.1 si da problemas |
| R20 | Bugs de IME y backspace en flutter_quill | Pruebas en dispositivo (S6) |
| R21 | Descarga pesada: LLM de 1,3 a 2,7 GB + embedder de 0,64 GB (+ reranker de 0,64 GB) | Descarga del sistema reanudable, comprobación de espacio y hash |

### 7.2 Validaciones (spikes) antes de cerrar las decisiones

- **S1 (Android):** compilar llama-cpp-2 0.1.161 con KleidiAI y native-assets, en un emulador API 30 y en uno con páginas de 16 KB. Medir pp512, tg128, TTFT y RAM, en frío y en caliente, de Qwen3.5-2B y 4B en Q4_0 frente a Q4_K_M, con las variantes A y B. Medir también la indexación con el embedder.
- **S2 (iOS, CI macOS + iPhone físico):** tok/s en Metal, `phys_footprint`, `os_proc_available_memory()` con y sin el entitlement, y precalentamiento de shaders.
- **S3:** FRB native-assets de extremo a extremo en ambas plataformas con las dependencias C++ (llama.cpp), en API 30-34.
- **S4:** evaluación en español e inglés. Generación con Qwen3.5-2B, Qwen3.5-4B y Qwen3-4B-2507. Recall@10 del embedder (1024 frente a 512 dimensiones; Qwen frente a Granite-97m).
- **S5:** corpus de OCR con notas impresas y manuscritas en español. Vision accurate frente a fast en iOS 26 y 27, y ML Kit.
- **S6:** IME en dispositivos reales: Gboard, Samsung Keyboard, SwiftKey e IME japonés y coreano de iOS.

### 7.3 Preguntas abiertas

1. ¿Qué quería decir el usuario con "Qwen3.0 6B": Qwen3-0.6B, un modelo de unos 6B o los "6B activados" de Qwen3.8-Flash-Next?
2. ¿Cuáles son los dispositivos mínimos objetivo (RAM y SoC)? ¿Se aceptan minSdk 30 e iOS 16?
3. ¿Habrá un Mac propio o una CI de macOS para compilar y firmar iOS?
4. ¿El OCR de manuscrito es una función principal? Si lo es, hace falta un VLM local (§5.4).
5. ¿Se admiten dispositivos Android sin GMS?
6. ¿Es aceptable la telemetría de ML Kit con el mensaje de "100 % local"?
7. ¿Son aceptables los tamaños de descarga, unos 2 a 3,4 GB en total?
8. Formato canónico de las notas: ¿Delta de Quill o un modelo de bloques propio?
9. ¿Se necesita cámara en vivo para el OCR? Afecta a los permisos (§6).
10. ¿Qué tamaño de corpus se espera, miles o decenas de miles de fragmentos?
11. ¿Compensa MTP en móvil (+94 MB) una vez resuelta la #25618?
12. iOS: ¿cuentan las páginas mmap limpias para `phys_footprint` cuando Metal usa buffers no-copy? (NV)
13. Fechas pendientes: FRB 2.14 estable, fusión del PR #122 de `native_toolchain_rust`, salida de llama-cpp-2 con llama.cpp v0.9.0 y fusión del PR #1181 (abort callback).