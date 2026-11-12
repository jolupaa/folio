import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../platform/native.dart';
import 'capture_errors.dart';
import 'capture_models.dart';

/// Resultado de pedir imágenes a una fuente (cámara, galería o escáner).
sealed class AcquireResult {
  const AcquireResult();
}

/// Rutas de las imágenes obtenidas (temporales de la fuente).
class Acquired extends AcquireResult {
  const Acquired(this.paths);
  final List<String> paths;
}

/// El usuario cerró la cámara, la galería o el escáner sin elegir nada.
class AcquireCancelled extends AcquireResult {
  const AcquireCancelled();
}

/// Permiso denegado para la cámara o las fotos.
class AcquireDenied extends AcquireResult {
  const AcquireDenied(this.origin);
  final PageOrigin origin;
}

/// La fuente no existe en este dispositivo (sin cámara, escáner no compatible…).
class AcquireUnavailable extends AcquireResult {
  const AcquireUnavailable(this.message);
  final String message;
}

class AcquireFailed extends AcquireResult {
  const AcquireFailed(this.message);
  final String message;
}

/// El escáner de documentos (VisionKit) solo existe en iOS.
bool get scannerSupportedOnPlatform => defaultTargetPlatform == TargetPlatform.iOS;

/// Pide imágenes a la fuente. [multiple] permite varias en galería y escáner.
Future<AcquireResult> acquireImages(PageOrigin origin, {bool multiple = true}) async {
  final picker = ImagePicker();
  try {
    switch (origin) {
      case PageOrigin.camera:
        final x = await picker.pickImage(source: ImageSource.camera, requestFullMetadata: false);
        return x == null ? const AcquireCancelled() : Acquired([x.path]);
      case PageOrigin.gallery:
        if (multiple) {
          final xs = await picker.pickMultiImage(limit: captureGalleryLimit, requestFullMetadata: false);
          return xs.isEmpty ? const AcquireCancelled() : Acquired([for (final x in xs) x.path]);
        }
        final x = await picker.pickImage(source: ImageSource.gallery, requestFullMetadata: false);
        return x == null ? const AcquireCancelled() : Acquired([x.path]);
      case PageOrigin.scanner:
        final paths = await FolioNative.scanDocument();
        if (paths.isEmpty) return const AcquireCancelled();
        return Acquired(multiple ? paths : [paths.first]);
    }
  } on PlatformException catch (e) {
    return mapAcquireError(e, origin);
  } on MissingPluginException {
    return const AcquireUnavailable('Esta fuente de imágenes no está disponible en este dispositivo.');
  } catch (e) {
    return AcquireFailed(captureErrorMessage(e));
  }
}

/// Traduce los errores de image_picker y del escáner nativo.
@visibleForTesting
AcquireResult mapAcquireError(PlatformException e, PageOrigin origin) {
  switch (e.code) {
    case 'camera_access_denied':
    case 'camera_access_restricted':
      return const AcquireDenied(PageOrigin.camera);
    case 'photo_access_denied':
    case 'photo_access_restricted':
      return const AcquireDenied(PageOrigin.gallery);
    case NativeErrorCode.permissionDenied:
      return AcquireDenied(origin == PageOrigin.gallery ? PageOrigin.gallery : PageOrigin.camera);
    case NativeErrorCode.cancelled:
      return const AcquireCancelled();
    case 'no_available_camera':
      return const AcquireUnavailable('No hay ninguna cámara disponible en este dispositivo.');
    case NativeErrorCode.unsupported:
      return AcquireUnavailable(
        origin == PageOrigin.scanner
            ? 'El escáner de documentos no está disponible en este dispositivo. Usa la cámara.'
            : 'Esta fuente de imágenes no está disponible en este dispositivo.',
      );
    default:
      return AcquireFailed(captureErrorMessage(e));
  }
}
