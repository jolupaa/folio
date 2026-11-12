/// Adaptadores nativos (Swift / Kotlin) por `MethodChannel('folio/native')`.
/// Contrato: docs/CONTRATOS.md §6. API tipada en `package:folio_native` (reexportada aquí).
///
/// Uso: `FolioNative.recognizeText(path)`, `FolioNative.renderPdfPage(...)`,
/// `FolioNative.deviceMemory()`, `FolioNative.excludeFromBackup(path)`…
/// Los errores son `PlatformException` con `code` ∈ [NativeErrorCode] (ver `humanError`).
library;

import 'package:flutter/services.dart';
import 'package:folio_native/folio_native.dart';

import '../src/rust/api/types.dart' as rust;

export 'package:folio_native/folio_native.dart';

/// true si [error] es un `PlatformException` del canal nativo con el código [code].
bool isNativeError(Object error, String code) => error is PlatformException && error.code == code;

/// Consulta el motor OCR sin lanzar: si no hay adaptador (plataforma sin implementación, pruebas…)
/// o falla la consulta, devuelve [OcrEngineInfo.unavailable].
Future<OcrEngineInfo> safeOcrInfo() async {
  try {
    return await FolioNative.ocrInfo();
  } on MissingPluginException {
    return const OcrEngineInfo.unavailable();
  } on PlatformException {
    return const OcrEngineInfo.unavailable();
  }
}

/// Conversión del resultado nativo a los DTOs de Rust.
extension OcrResultToRust on OcrResult {
  List<rust.OcrLine> toRustLines() => [
    for (final l in lines)
      rust.OcrLine(text: l.text, x: l.x, y: l.y, w: l.w, h: l.h, confidence: l.confidence),
  ];

  /// Página lista para `create_note_from_scan` / `append_scan_to_note` / `set_page_ocr`.
  /// [text] es el texto final (posiblemente corregido); si es null se usa el reconocido.
  /// `edited` es true cuando el texto final difiere del reconocido.
  rust.OcrPageInput toPageInput({String? imagePath, String? text}) {
    final finalText = text ?? this.text;
    return rust.OcrPageInput(
      imagePath: imagePath,
      text: finalText,
      engine: engine,
      confidence: effectiveConfidence,
      lines: toRustLines(),
      edited: isTextEdited(this.text, finalText),
    );
  }
}

/// Página sin reconocimiento (OCR no disponible, cancelado o fallido): solo imagen y, si el
/// usuario lo escribió, texto propio (cuenta como editado).
rust.OcrPageInput imageOnlyPageInput({required String? imagePath, String text = ''}) => rust.OcrPageInput(
  imagePath: imagePath,
  text: text,
  engine: OcrEngines.none,
  lines: const [],
  edited: text.trim().isNotEmpty,
);

/// Un texto se considera editado si difiere del reconocido ignorando espacios finales y saltos
/// de línea `\r\n` vs `\n`.
bool isTextEdited(String recognized, String current) {
  String norm(String s) => s.replaceAll('\r\n', '\n').trimRight();
  return norm(recognized) != norm(current);
}
