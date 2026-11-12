import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel.dart';
import 'models.dart';

/// Interfaz de plataforma de los adaptadores nativos. Las pruebas pueden sustituir
/// [instance] por una implementación falsa (usando `MockPlatformInterfaceMixin`).
abstract class FolioNativePlatform extends PlatformInterface {
  FolioNativePlatform() : super(token: _token);

  static final Object _token = Object();

  static FolioNativePlatform _instance = MethodChannelFolioNative();

  static FolioNativePlatform get instance => _instance;

  static set instance(FolioNativePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// `ocr.recognize`: reconoce el texto de la imagen en [path] (JPEG/PNG; respeta EXIF).
  Future<OcrResult> recognizeText(String path, {List<String> languages = defaultOcrLanguages});

  /// `ocr.info`.
  Future<OcrEngineInfo> ocrInfo();

  /// `pdf.pageCount`.
  Future<int> pdfPageCount(String path);

  /// `pdf.renderPage`: PNG con fondo blanco de ancho [targetWidth] en [outPath].
  /// [page] es 0-based.
  Future<PdfPageRender> renderPdfPage(
    String path, {
    required int page,
    required String outPath,
    required int targetWidth,
  });

  /// `pdf.pageText`: capa de texto nativa de la página (iOS PDFKit; Android API 35+, si no `""`).
  Future<String> pdfPageText(String path, {required int page});

  /// `scanner.scan`: rutas JPEG de las páginas escaneadas (iOS VisionKit).
  /// Android: `PlatformException(unsupported)`. Cancelación: `PlatformException(cancelled)`.
  Future<List<String>> scanDocument();

  /// `files.excludeFromBackup`.
  Future<bool> excludeFromBackup(String path);

  /// `device.memory`.
  Future<DeviceMemory> deviceMemory();
}
