import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'platform_interface.dart';

/// Implementación por `MethodChannel('folio/native')` (docs/CONTRATOS.md §6).
class MethodChannelFolioNative extends FolioNativePlatform {
  MethodChannelFolioNative({@visibleForTesting MethodChannel? channel})
    : methodChannel = channel ?? const MethodChannel(channelName);

  static const channelName = 'folio/native';

  @visibleForTesting
  final MethodChannel methodChannel;

  Future<Map<Object?, Object?>> _invokeMap(String method, [Map<String, Object?>? args]) async {
    final r = await methodChannel.invokeMethod<Object?>(method, args);
    if (r is Map) return r.cast<Object?, Object?>();
    throw PlatformException(
      code: NativeErrorCode.io,
      message: 'Respuesta nativa inesperada para $method.',
    );
  }

  @override
  Future<OcrResult> recognizeText(String path, {List<String> languages = defaultOcrLanguages}) async {
    final m = await _invokeMap('ocr.recognize', {'path': path, 'languages': languages});
    return OcrResult.fromMap(m);
  }

  @override
  Future<OcrEngineInfo> ocrInfo() async => OcrEngineInfo.fromMap(await _invokeMap('ocr.info'));

  @override
  Future<int> pdfPageCount(String path) async {
    final r = await methodChannel.invokeMethod<Object?>('pdf.pageCount', {'path': path});
    if (r is int) return r;
    if (r is num) return r.toInt();
    throw PlatformException(code: NativeErrorCode.io, message: 'No se pudo leer el número de páginas.');
  }

  @override
  Future<PdfPageRender> renderPdfPage(
    String path, {
    required int page,
    required String outPath,
    required int targetWidth,
  }) async {
    final m = await _invokeMap('pdf.renderPage', {
      'path': path,
      'page': page,
      'outPath': outPath,
      'targetWidth': targetWidth,
    });
    final render = PdfPageRender.fromMap(m);
    if (render.path.isEmpty || render.width <= 0 || render.height <= 0) {
      throw PlatformException(code: NativeErrorCode.io, message: 'No se pudo renderizar la página.');
    }
    return render;
  }

  @override
  Future<String> pdfPageText(String path, {required int page}) async {
    final r = await methodChannel.invokeMethod<Object?>('pdf.pageText', {'path': path, 'page': page});
    return r is String ? r : '';
  }

  @override
  Future<List<String>> scanDocument() async {
    final r = await methodChannel.invokeMethod<Object?>('scanner.scan');
    if (r is List) return List.unmodifiable(r.whereType<String>());
    return const [];
  }

  @override
  Future<bool> excludeFromBackup(String path) async {
    final r = await methodChannel.invokeMethod<Object?>('files.excludeFromBackup', {'path': path});
    return r == true;
  }

  @override
  Future<DeviceMemory> deviceMemory() async => DeviceMemory.fromMap(await _invokeMap('device.memory'));
}
