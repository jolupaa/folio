import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextRange;

import '../../platform/native.dart';
import '../../src/rust/api/types.dart' show CropRect, OcrPageInput;

/// Lado mayor máximo de las imágenes de captura (procesadas por Rust `process_image`).
const captureMaxDimension = 2600;

/// Máximo de imágenes por selección en la galería.
const captureGalleryLimit = 30;

/// De dónde salió una página (para «Repetir» con el mismo origen).
enum PageOrigin { camera, gallery, scanner }

/// Estado del reconocimiento de una página.
enum OcrStatus {
  /// En cola (aún no reconocida).
  pending,

  /// Reconociéndose ahora mismo.
  running,

  /// Reconocida (el texto puede estar vacío si no se encontró nada).
  done,

  /// El motor devolvió un error.
  failed,

  /// El usuario canceló el reconocimiento antes de llegar a esta página.
  skipped,

  /// No hay motor OCR en el dispositivo: se guardará solo la imagen.
  unavailable,
}

const Object _unset = Object();

/// Una página del flujo de captura.
@immutable
class CapturePage {
  const CapturePage({
    required this.id,
    required this.origin,
    required this.basePath,
    required this.baseWidth,
    required this.baseHeight,
    this.quarterTurns = 0,
    this.crop,
    this.processedPath,
    this.processedWidth,
    this.processedHeight,
    this.revision = 0,
    this.status = OcrStatus.pending,
    this.ocr,
    this.text = '',
    this.error,
  });

  final String id;
  final PageOrigin origin;

  /// Imagen normalizada (orientación EXIF aplicada, lado mayor ≤ [captureMaxDimension]).
  /// Todas las ediciones se aplican sobre ella (nunca se recomprime en cadena).
  final String basePath;
  final int baseWidth;
  final int baseHeight;

  /// Giros de 90° en sentido horario (0..3).
  final int quarterTurns;

  /// Recorte normalizado respecto a la imagen base YA girada. null = imagen completa.
  final CropRect? crop;

  /// Resultado de aplicar giro y recorte; null si no hay ediciones (se usa [basePath]).
  final String? processedPath;
  final int? processedWidth;
  final int? processedHeight;

  /// Aumenta con cada cambio de imagen: un OCR en curso de una revisión anterior se descarta.
  final int revision;

  final OcrStatus status;
  final OcrResult? ocr;

  /// Texto actual (reconocido y, quizá, corregido por el usuario).
  final String text;

  /// Mensaje legible del último error de OCR.
  final String? error;

  /// Imagen que se reconoce y se guarda.
  String get imagePath => processedPath ?? basePath;
  int get imageWidth => processedWidth ?? baseWidth;
  int get imageHeight => processedHeight ?? baseHeight;
  double get aspectRatio => imageHeight == 0 ? 1 : imageWidth / imageHeight;

  bool get hasImageEdits => quarterTurns != 0 || crop != null;

  /// Tamaño de la imagen base tras el giro (espacio de coordenadas del recorte).
  int get rotatedBaseWidth => quarterTurns.isOdd ? baseHeight : baseWidth;
  int get rotatedBaseHeight => quarterTurns.isOdd ? baseWidth : baseHeight;

  bool get isRecognized => status == OcrStatus.done && ocr != null;

  /// true si el usuario cambió el texto reconocido (o escribió texto en una página sin OCR).
  bool get textWasEdited {
    final r = ocr;
    if (isRecognized && r != null) return isTextEdited(r.text, text);
    return text.trim().isNotEmpty;
  }

  bool get isLowConfidence => isRecognized && (ocr?.isLowConfidence ?? false);

  /// Reconocida pero sin texto.
  bool get recognizedEmpty => isRecognized && (ocr?.isEmpty ?? true);

  CapturePage copyWith({
    String? basePath,
    int? baseWidth,
    int? baseHeight,
    int? quarterTurns,
    Object? crop = _unset,
    Object? processedPath = _unset,
    Object? processedWidth = _unset,
    Object? processedHeight = _unset,
    int? revision,
    OcrStatus? status,
    Object? ocr = _unset,
    String? text,
    Object? error = _unset,
  }) {
    return CapturePage(
      id: id,
      origin: origin,
      basePath: basePath ?? this.basePath,
      baseWidth: baseWidth ?? this.baseWidth,
      baseHeight: baseHeight ?? this.baseHeight,
      quarterTurns: quarterTurns ?? this.quarterTurns,
      crop: identical(crop, _unset) ? this.crop : crop as CropRect?,
      processedPath: identical(processedPath, _unset) ? this.processedPath : processedPath as String?,
      processedWidth: identical(processedWidth, _unset) ? this.processedWidth : processedWidth as int?,
      processedHeight: identical(processedHeight, _unset) ? this.processedHeight : processedHeight as int?,
      revision: revision ?? this.revision,
      status: status ?? this.status,
      ocr: identical(ocr, _unset) ? this.ocr : ocr as OcrResult?,
      text: text ?? this.text,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  /// Página para `create_note_from_scan` / `append_scan_to_note`.
  OcrPageInput toPageInput() {
    final r = ocr;
    if (isRecognized && r != null) return r.toPageInput(imagePath: imagePath, text: text);
    return imageOnlyPageInput(imagePath: imagePath, text: text);
  }
}

// ─────────────────────────── Recorte ───────────────────────────

/// Tamaño mínimo (normalizado) de un recorte.
const minCropFraction = 0.05;

/// Transforma un recorte al girar la imagen 90° en sentido horario.
/// Un punto (x, y) de la imagen pasa a (1 − y, x); el rectángulo conserva su contenido.
CropRect rotateCropClockwise(CropRect c) => CropRect(x: 1 - (c.y + c.h), y: c.x, w: c.h, h: c.w);

/// Acota el recorte a la imagen y a un tamaño mínimo. Devuelve null si cubre (casi) toda la imagen.
CropRect? normalizeCrop(CropRect? c) {
  if (c == null) return null;
  double clamp01(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0).toDouble();
  var x = clamp01(c.x);
  var y = clamp01(c.y);
  var w = clamp01(c.w).clamp(minCropFraction, 1.0).toDouble();
  var h = clamp01(c.h).clamp(minCropFraction, 1.0).toDouble();
  if (x + w > 1) x = 1 - w;
  if (y + h > 1) y = 1 - h;
  const eps = 0.004;
  if (x <= eps && y <= eps && w >= 1 - eps && h >= 1 - eps) return null;
  return CropRect(x: x, y: y, w: w, h: h);
}

// ─────────────────────────── Texto ⇄ líneas ───────────────────────────

/// Localiza cada línea reconocida en el texto (posiblemente editado) en orden de lectura.
/// Devuelve, para cada línea, su rango en [text] o null si ya no aparece (el usuario la cambió).
/// La búsqueda es secuencial: una línea editada no desplaza a las siguientes.
List<TextRange?> mapLinesToText(String text, List<String> lines) {
  final lower = text.toLowerCase();
  final ranges = <TextRange?>[];
  var cursor = 0;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) {
      ranges.add(null);
      continue;
    }
    var idx = text.indexOf(line, cursor);
    if (idx < 0) idx = lower.indexOf(line.toLowerCase(), cursor);
    if (idx < 0) {
      ranges.add(null);
      continue;
    }
    ranges.add(TextRange(start: idx, end: idx + line.length));
    cursor = idx + line.length;
  }
  return ranges;
}

/// Índice de la línea cuyo rango contiene [offset] (incluido el final de la línea), o null.
int? lineAtOffset(List<TextRange?> ranges, int offset) {
  for (var i = 0; i < ranges.length; i++) {
    final r = ranges[i];
    if (r != null && offset >= r.start && offset <= r.end) return i;
  }
  return null;
}

/// Porcentaje legible de una confianza 0..1: «87 %».
String confidenceLabel(double c) => '${(c * 100).round()} %';
