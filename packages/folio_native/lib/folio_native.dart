/// Adaptadores nativos de Folio: OCR (Apple Vision / ML Kit), PDF (PDFKit / PdfRenderer),
/// escáner de documentos (VisionKit), memoria del dispositivo y exclusión de copias de seguridad.
///
/// Canal `MethodChannel('folio/native')`; contrato en docs/CONTRATOS.md §6. Los errores llegan como
/// `PlatformException` con `code` ∈ [NativeErrorCode].
library;

import 'src/models.dart';
import 'src/platform_interface.dart';

export 'src/method_channel.dart' show MethodChannelFolioNative;
export 'src/models.dart';
export 'src/platform_interface.dart' show FolioNativePlatform;

/// Fachada estática de los adaptadores nativos.
abstract final class FolioNative {
  static FolioNativePlatform get _p => FolioNativePlatform.instance;

  /// Reconoce el texto de una imagen (JPEG/PNG). Respeta la orientación EXIF.
  static Future<OcrResult> recognizeText(String path, {List<String> languages = defaultOcrLanguages}) =>
      _p.recognizeText(path, languages: languages);

  /// Motor OCR disponible en este dispositivo.
  static Future<OcrEngineInfo> ocrInfo() => _p.ocrInfo();

  static Future<int> pdfPageCount(String path) => _p.pdfPageCount(path);

  /// Renderiza la página [page] (0-based) como PNG con fondo blanco en [outPath].
  static Future<PdfPageRender> renderPdfPage(
    String path, {
    required int page,
    required String outPath,
    int targetWidth = 1700,
  }) => _p.renderPdfPage(path, page: page, outPath: outPath, targetWidth: targetWidth);

  /// Capa de texto nativa de una página (puede ser `""`).
  static Future<String> pdfPageText(String path, {required int page}) => _p.pdfPageText(path, page: page);

  /// Escáner de documentos con corrección de perspectiva (solo iOS).
  static Future<List<String>> scanDocument() => _p.scanDocument();

  static Future<bool> excludeFromBackup(String path) => _p.excludeFromBackup(path);

  static Future<DeviceMemory> deviceMemory() => _p.deviceMemory();
}
