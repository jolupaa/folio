# Folio · Guía de diseño

Experiencia tranquila, rápida y centrada en el contenido. Toma de Apple Notes la claridad de listas,
carpetas y acciones habituales, sin copiar su identidad visual. Un único acento discreto.

## 1. Tokens de color

| Token            | Claro      | Oscuro     | Uso |
|------------------|------------|------------|-----|
| `background`     | `#F4F3EF`  | `#121211`  | Fondo de pantallas (papel neutro cálido) |
| `surface`        | `#FFFFFF`  | `#1C1C1A`  | Tarjetas, grupos de lista, hojas |
| `surfaceAlt`     | `#ECEAE5`  | `#262624`  | Campos, barra de búsqueda, chips |
| `separator`      | `#E2DFD8`  | `#33322E`  | Divisores (0.5–1 px) |
| `textPrimary`    | `#1C1B19`  | `#ECEAE4`  | Texto principal |
| `textSecondary`  | `#67645E`  | `#A3A098`  | Metadatos, vistas previas (≥ 4.5:1 sobre surface) |
| `textTertiary`   | `#8E8A83`  | `#7A776F`  | Placeholders (solo texto no esencial) |
| `accent`         | `#2F6F5E`  | `#7FC4AE`  | Acento único: acciones primarias, selección, iconos activos |
| `onAccent`       | `#FFFFFF`  | `#0E2A22`  | Texto sobre acento |
| `accentSoft`     | `#2F6F5E1A`| `#7FC4AE24`| Fondos de selección/resaltado |
| `danger`         | `#B3261E`  | `#F2B8B5`  | Borrar, errores |
| `highlight`      | `#F6E7A8`  | `#5C4F1A`  | Coincidencias de búsqueda |

Contraste verificado (WCAG 2.1): accent claro sobre `surface` ≈ 5.9:1; accent oscuro sobre `surface` ≈ 8.3:1;
textSecondary ≥ 4.5:1 en ambos modos. El acento no se usa como único portador de información.

## 2. Tipografía

Fuente del sistema (SF Pro en iOS, Roboto en Android) para máxima legibilidad y soporte de Dynamic Type.
Escala (tamaño/peso/altura de línea):

- `largeTitle` 32/700/1.15 — título de carpeta en cabecera expandida
- `title` 22/650/1.25 — título de nota
- `headline` 17/600/1.3 — filas de lista (título), cabeceras de sección
- `body` 17/400/1.45 (iOS) · 16/400/1.5 (Android) — texto de notas
- `callout` 15/400/1.4 — vistas previas, mensajes
- `footnote` 13/400/1.35 — metadatos, fechas, ubicación de resultados
- `caption` 12/500/1.3 — etiquetas, contadores

Siempre se respeta `MediaQuery.textScaler`; nada de alturas fijas en filas con texto: usar `minHeight`.

## 3. Espaciado, forma y toque

- Rejilla de 4 pt. Márgenes laterales 16 (móvil) / 24 (tablet). Grupos de lista con radio 12.
- Hojas inferiores con radio 20. Botones con radio 12. Barra de búsqueda: píldora de alto 44 (radio 12).
- Áreas táctiles ≥ 48×48 dp (Android) / 44×44 pt (iOS); se usa 48 en ambos.
- Filas de lista: mín. 56 (una línea) / 68 (dos líneas). Separadores insetados a la altura del texto.

## 4. Iconografía y movimiento

- Una sola familia: `Icons.*_rounded` de Material (coherente en ambas plataformas). Tamaño 22–24.
- IA: icono `auto_awesome_rounded` — siempre el mismo para identificar acciones de IA.
- Animaciones 150–250 ms, `Curves.easeOutCubic`; transiciones de página nativas por plataforma
  (deslizamiento lateral con gesto atrás en iOS; zoom/fade de Material en Android).
- Si `MediaQuery.disableAnimations` es true, se eliminan animaciones no esenciales.

## 5. Adaptación por plataforma

- iOS: gesto de volver desde el borde, cabeceras con título grande que colapsa, `CupertinoContextMenu`
  en pulsación larga, diálogos `showAdaptiveDialog`, interruptores `Switch.adaptive`, hápticos ligeros.
- Android: botón atrás del sistema/gesto predictivo, menús emergentes Material, `SnackBar` para deshacer.
- Acciones de fila: deslizar para Fijar (inicio) y Borrar/Mover (fin) en ambas plataformas; las mismas
  acciones están siempre en el menú contextual (accesibilidad: no depender de gestos).

## 6. Estructura de pantallas

1. **Biblioteca (raíz)**: título grande «Folio»; grupo «Notas» (bandeja), «Todas las notas», «Fijadas»;
   grupo «Carpetas» (árbol con subcarpetas desplegables y contador); grupo «Estudio» y «Papelera».
   Barra inferior: búsqueda «Buscar en todas las notas» + botón nueva nota/carpeta.
2. **Carpeta**: título grande con el nombre; subcarpetas; sección «Fijadas»; notas por fecha.
   Barra inferior: «Buscar en Física» + chip «Toda la biblioteca» al enfocar; botón componer (nota, pizarra,
   escanear apuntes, importar PDF/imagen). Acción de IA compacta en la cabecera: «Preguntar sobre esta carpeta».
3. **Nota**: título + bloques. Modo lectura: barra inferior «Buscar en esta nota». Modo edición (teclado):
   la barra se sustituye por la barra de formato (Título, Lista, Tareas, Adjuntar, Escanear, ✦ IA).
4. **Captura**: cámara/galería → revisión de imagen (girar, recortar, repetir, añadir página) → OCR con
   progreso cancelable → revisión del texto (imagen arriba con líneas reconocidas resaltables; texto editable
   abajo; confianza baja marcada) → «Guardar como nota nueva» / «Añadir a nota existente».
5. **Asistente (hoja)**: ámbito visible arriba («Esta nota», «3 fuentes», «Física»); acciones: Preguntar,
   Resumen breve, Resumen detallado, Esquema, Conceptos clave, Flashcards, Cuestionario.
6. **Conversación**: mensajes con referencias numeradas [1] tocables → abren la nota/página resaltando el
   fragmento. Aviso explícito cuando las fuentes no contienen información suficiente.
7. **Estudio**: lista de materiales; visor/editor de resumen; tarjetas con volteo y edición; cuestionario
   (opción múltiple y respuesta abierta) con corrección, explicación y referencias.
8. **Pizarra**: lienzo a pantalla completa; barra de herramientas flotante (lápiz, marcador, borrador,
   selección, texto, formas, imagen, color, grosor, deshacer/rehacer).
9. **Modelos de IA** (Ajustes): estado del dispositivo (RAM, almacenamiento libre), modelos con tamaño,
   licencia, estado, progreso, pausar/cancelar/eliminar.

## 7. Barra de búsqueda inferior

- Siempre visible en vistas de navegación y consulta; el teclado solo se abre al tocarla.
- Placeholder = ámbito: «Buscar en todas las notas», «Buscar en {carpeta}», «Buscar en esta nota».
- Al enfocar: la lista de resultados aparece sobre la barra, que sube con el teclado (`viewInsets`).
  Chip «Toda la biblioteca» para ampliar el ámbito; se recuerda mientras dure la búsqueda.
- Resultados: título, fragmento con coincidencias resaltadas y ubicación («Física › Tema 2 · Página 3 del PDF»).
- Respeta áreas seguras y se oculta en edición/pizarra para no tapar herramientas.

## 8. Estados

Todas las pantallas definen: vacío (icono en círculo suave + título + una línea + acción principal), carga
(esqueletos discretos, nunca spinners a pantalla completa > 300 ms), error (mensaje humano + reintentar),
permiso denegado (explicación + «Abrir Ajustes»), modelo no instalado (tarjeta con tamaño y «Descargar»),
dispositivo no compatible (explicación + funciones que siguen disponibles).

## 9. Accesibilidad

`Semantics` en iconos y controles personalizados; orden de foco lógico; contraste AA; soporte de texto
grande hasta 200 % sin recortes; objetivos táctiles ≥ 48; no comunicar estado solo con color.
