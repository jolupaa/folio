import 'package:flutter/foundation.dart';

/// Códigos de error del canal nativo (docs/CONTRATOS.md §6). Llegan como
/// `PlatformException.code`.
abstract final class NativeErrorCode {
  static const permissionDenied = 'permission_denied';
  static const unsupported = 'unsupported';
  static const io = 'io';
  static const ocrFailed = 'ocr_failed';
  static const cancelled = 'cancelled';
}

/// Identificadores de motor OCR que devuelven los adaptadores nativos.
abstract final class OcrEngines {
  static const appleVision = 'apple_vision';
  static const mlkitLatin = 'mlkit_latin';

  /// Página guardada sin reconocimiento (OCR no disponible o no ejecutado).
  static const none = 'none';
}

/// Idiomas solicitados por defecto al motor OCR.
const defaultOcrLanguages = <String>['es-ES', 'en-US'];

/// Umbral por debajo del cual una línea o página se marca como «confianza baja».
const lowConfidenceThreshold = 0.5;

double? _toDouble(Object? v) {
  if (v is num) {
    final d = v.toDouble();
    return d.isFinite ? d : null;
  }
  return null;
}

int _toInt(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num && v.isFinite) return v.round();
  return fallback;
}

double _unit(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0).toDouble();

/// Una línea reconocida. Coordenadas normalizadas 0..1 con origen arriba-izquierda,
/// relativas a la imagen tal como se ve (orientación EXIF ya aplicada).
@immutable
class OcrTextLine {
  const OcrTextLine({
    required this.text,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.confidence,
  });

  final String text;
  final double x;
  final double y;
  final double w;
  final double h;

  /// 0..1 si el motor la proporciona.
  final double? confidence;

  /// true si la línea tiene una caja utilizable para dibujarla sobre la imagen.
  bool get hasBox => w > 0 && h > 0;

  bool get isLowConfidence => confidence != null && confidence! < lowConfidenceThreshold;

  /// Parsea una línea del mapa nativo. Devuelve null si no tiene texto.
  /// Las coordenadas se acotan a 0..1 y la caja se recorta para no salirse de la imagen.
  static OcrTextLine? fromMap(Map<Object?, Object?> map) {
    final raw = map['text'];
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final x = _unit(_toDouble(map['x']) ?? 0);
    final y = _unit(_toDouble(map['y']) ?? 0);
    final w = _unit(_toDouble(map['w']) ?? 0).clamp(0.0, 1.0 - x).toDouble();
    final h = _unit(_toDouble(map['h']) ?? 0).clamp(0.0, 1.0 - y).toDouble();
    final c = _toDouble(map['confidence']);
    return OcrTextLine(text: text, x: x, y: y, w: w, h: h, confidence: c == null ? null : _unit(c));
  }

  Map<String, Object?> toMap() => {
    'text': text,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    if (confidence != null) 'confidence': confidence,
  };

  @override
  bool operator ==(Object other) =>
      other is OcrTextLine &&
      other.text == text &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(text, x, y, w, h, confidence);

  @override
  String toString() => 'OcrTextLine("$text", $x, $y, $w, $h, $confidence)';
}

/// Resultado de `ocr.recognize`.
@immutable
class OcrResult {
  const OcrResult({required this.text, required this.engine, this.confidence, required this.lines});

  /// Resultado vacío (sin texto reconocido).
  const OcrResult.empty(this.engine) : text = '', confidence = null, lines = const [];

  /// Texto completo: bloques separados por una línea en blanco, líneas por `\n`.
  final String text;

  /// 'apple_vision' | 'mlkit_latin' | …
  final String engine;

  /// Confianza global 0..1 si el motor la proporciona.
  final double? confidence;
  final List<OcrTextLine> lines;

  factory OcrResult.fromMap(Map<Object?, Object?> map) {
    final rawLines = map['lines'];
    final lines = <OcrTextLine>[];
    if (rawLines is List) {
      for (final l in rawLines) {
        if (l is Map) {
          final line = OcrTextLine.fromMap(l.cast<Object?, Object?>());
          if (line != null) lines.add(line);
        }
      }
    }
    final rawText = map['text'];
    var text = rawText is String ? rawText.replaceAll('\r\n', '\n').trim() : '';
    if (text.isEmpty && lines.isNotEmpty) {
      text = lines.map((l) => l.text).join('\n');
    }
    final engine = map['engine'];
    final c = _toDouble(map['confidence']);
    return OcrResult(
      text: text,
      engine: engine is String && engine.isNotEmpty ? engine : 'unknown',
      confidence: c == null ? null : _unit(c),
      lines: List.unmodifiable(lines),
    );
  }

  bool get isEmpty => text.trim().isEmpty;

  /// Confianza global; si el motor no la da, media de las líneas que la tengan.
  double? get effectiveConfidence {
    if (confidence != null) return confidence;
    var sum = 0.0;
    var n = 0;
    for (final l in lines) {
      final c = l.confidence;
      if (c != null) {
        sum += c;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  bool get isLowConfidence {
    final c = effectiveConfidence;
    return c != null && c < lowConfidenceThreshold;
  }

  int get lowConfidenceLineCount => lines.where((l) => l.isLowConfidence).length;

  Map<String, Object?> toMap() => {
    'text': text,
    'engine': engine,
    if (confidence != null) 'confidence': confidence,
    'lines': [for (final l in lines) l.toMap()],
  };

  @override
  String toString() => 'OcrResult($engine, ${text.length} chars, ${lines.length} lines, $confidence)';
}

/// Resultado de `ocr.info`.
@immutable
class OcrEngineInfo {
  const OcrEngineInfo({
    required this.engine,
    required this.languages,
    required this.handwriting,
    required this.available,
  });

  /// Motor no disponible (plataforma sin adaptador, error al consultar…).
  const OcrEngineInfo.unavailable()
    : engine = OcrEngines.none,
      languages = const [],
      handwriting = false,
      available = false;

  final String engine;
  final List<String> languages;
  final bool handwriting;
  final bool available;

  factory OcrEngineInfo.fromMap(Map<Object?, Object?> map) {
    final langs = map['languages'];
    return OcrEngineInfo(
      engine: map['engine'] is String ? map['engine']! as String : OcrEngines.none,
      languages: langs is List ? List.unmodifiable(langs.whereType<String>()) : const [],
      handwriting: map['handwriting'] == true,
      available: map['available'] == true,
    );
  }
}

/// Resultado de `pdf.renderPage`: PNG con fondo blanco.
@immutable
class PdfPageRender {
  const PdfPageRender({required this.path, required this.width, required this.height});

  final String path;
  final int width;
  final int height;

  double get aspectRatio => height == 0 ? 1 : width / height;

  factory PdfPageRender.fromMap(Map<Object?, Object?> map) => PdfPageRender(
    path: map['path'] is String ? map['path']! as String : '',
    width: _toInt(map['width']),
    height: _toInt(map['height']),
  );
}

/// Resultado de `device.memory` (bytes).
@immutable
class DeviceMemory {
  const DeviceMemory({required this.total, required this.available});

  final int total;
  final int available;

  factory DeviceMemory.fromMap(Map<Object?, Object?> map) =>
      DeviceMemory(total: _toInt(map['total']), available: _toInt(map['available']));
}
