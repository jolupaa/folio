import '../../src/rust/api/attachments.dart' as att;
import '../../src/rust/api/types.dart' as rt;
import 'capture_models.dart';

/// Imagen escrita por Rust `process_image`.
class ProcessedImage {
  const ProcessedImage({required this.path, required this.width, required this.height});
  final String path;
  final int width;
  final int height;
}

/// Normaliza EXIF, gira, recorta y limita el lado mayor (JPEG calidad 90).
typedef ImageProcessFn = Future<ProcessedImage> Function({
  required String input,
  required String output,
  required int quarterTurns,
  rt.CropRect? crop,
});

/// Implementación real con Rust.
Future<ProcessedImage> rustProcessImage({
  required String input,
  required String output,
  required int quarterTurns,
  rt.CropRect? crop,
}) async {
  final info = await att.processImage(
    inputPath: input,
    outputPath: output,
    rotateQuarterTurns: quarterTurns,
    crop: crop,
    maxDimension: captureMaxDimension,
  );
  return ProcessedImage(path: info.path, width: info.width, height: info.height);
}
