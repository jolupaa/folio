import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

enum BoardImageState { loading, ready, failed }

class _Entry {
  BoardImageState state = BoardImageState.loading;
  ui.Image? image;
}

/// Caché de imágenes decodificadas de los adjuntos de la pizarra (`ui.Image` reducidas a
/// [maxDimension] px en el lado mayor). Notifica cuando termina una carga para volver a dibujar.
class BoardImageCache extends ChangeNotifier {
  BoardImageCache({required Future<String> Function(String attachmentId) resolvePath, this.maxDimension = 2048})
    : _resolvePath = resolvePath;

  final Future<String> Function(String attachmentId) _resolvePath;
  final int maxDimension;
  final _entries = <String, _Entry>{};
  bool _disposed = false;
  int _revision = 0;

  /// Cambia cuando una imagen termina de cargarse (o falla).
  int get revision => _revision;

  /// Imagen lista o null (y arranca la carga si no se había pedido).
  ui.Image? imageFor(String attachmentId) => _entry(attachmentId).image;

  BoardImageState stateOf(String attachmentId) => _entry(attachmentId).state;

  /// Vuelve a intentar las imágenes que fallaron (p. ej. tras «Reintentar»).
  void retryFailed() {
    final failed = [
      for (final e in _entries.entries)
        if (e.value.state == BoardImageState.failed) e.key,
    ];
    for (final id in failed) {
      _entries.remove(id);
      _entry(id);
    }
    if (failed.isNotEmpty) _bump();
  }

  _Entry _entry(String id) {
    final existing = _entries[id];
    if (existing != null) return existing;
    final e = _Entry();
    _entries[id] = e;
    _load(id, e);
    return e;
  }

  Future<void> _load(String id, _Entry entry) async {
    try {
      final path = await _resolvePath(id);
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      int? tw, th;
      if (math.max(w, h) > maxDimension) {
        if (w >= h) {
          tw = maxDimension;
        } else {
          th = maxDimension;
        }
      }
      final codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (_disposed || !identical(_entries[id], entry)) {
        frame.image.dispose();
        return;
      }
      entry
        ..image = frame.image
        ..state = BoardImageState.ready;
    } catch (_) {
      if (_disposed) return;
      entry.state = BoardImageState.failed;
    }
    _bump();
  }

  void _bump() {
    if (_disposed) return;
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final e in _entries.values) {
      e.image?.dispose();
    }
    _entries.clear();
    super.dispose();
  }
}
