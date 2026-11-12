import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../platform/native.dart';
import '../../platform/paths.dart';
import '../../src/rust/api/types.dart' show CropRect, OcrPageInput;
import 'capture_gateway.dart';
import 'capture_models.dart';

/// Reconoce el texto de una imagen.
typedef OcrFn = Future<OcrResult> Function(String imagePath);

/// Traduce un error a un mensaje para el usuario.
typedef ErrorMessageFn = String Function(Object error);

/// Resultado de añadir imágenes: cuántas se añadieron y qué errores hubo.
class AddImagesResult {
  const AddImagesResult({required this.added, required this.errors});
  final List<CapturePage> added;
  final List<Object> errors;
}

/// Estado del flujo de captura: páginas, ediciones de imagen y OCR por página.
///
/// No depende de widgets: el procesado de imagen y el OCR se inyectan, lo que permite probar la
/// lógica sin Rust ni plataforma.
class CaptureSession extends ChangeNotifier {
  CaptureSession({
    required this.workDir,
    required ImageProcessFn process,
    required OcrFn recognize,
    required bool ocrAvailable,
    ErrorMessageFn? describeError,
    String Function()? newId,
    Future<void> Function(String path)? deleteFile,
  }) : _process = process,
       _recognize = recognize,
       _ocrAvailable = ocrAvailable,
       _describe = describeError ?? ((e) => '$e'),
       _newId = newId ?? (() => const Uuid().v4()),
       _deleteFile = deleteFile ?? AppPaths.deleteQuietly;

  /// Carpeta temporal de la sesión (`<cache>/tmp/capture/<id>`).
  final String workDir;

  final ImageProcessFn _process;
  final OcrFn _recognize;
  final ErrorMessageFn _describe;
  final String Function() _newId;
  final Future<void> Function(String path) _deleteFile;

  bool _ocrAvailable;
  final List<CapturePage> _pages = [];
  final Set<String> _processing = {};
  int _preparing = 0;
  int _selected = 0;
  bool _disposed = false;

  bool _ocrRunning = false;
  bool _cancelRequested = false;
  String? _ocrPageId;

  // ─────────────── Lectura ───────────────

  List<CapturePage> get pages => List.unmodifiable(_pages);
  bool get isEmpty => _pages.isEmpty;
  int get length => _pages.length;

  int get selectedIndex => _pages.isEmpty ? 0 : _selected.clamp(0, _pages.length - 1);
  CapturePage? get selected => _pages.isEmpty ? null : _pages[selectedIndex];

  bool get ocrAvailable => _ocrAvailable;

  /// Imágenes que se están preparando (normalizando) para añadirse.
  int get preparingCount => _preparing;

  bool isProcessing(String pageId) => _processing.contains(pageId);
  bool get anyProcessing => _processing.isNotEmpty || _preparing > 0;

  bool get ocrRunning => _ocrRunning;
  bool get cancelRequested => _cancelRequested;

  /// Página que se está reconociendo ahora.
  String? get ocrPageId => _ocrPageId;

  /// Índice (0-based) de la página en reconocimiento, o null.
  int? get ocrPageIndex {
    final id = _ocrPageId;
    if (id == null) return null;
    final i = indexOf(id);
    return i < 0 ? null : i;
  }

  /// Fracción de páginas ya resueltas (reconocidas, fallidas o sin OCR).
  double get ocrProgress {
    if (_pages.isEmpty) return 0;
    final finished = _pages
        .where((p) => p.status != OcrStatus.pending && p.status != OcrStatus.running)
        .length;
    return finished / _pages.length;
  }

  /// Páginas aún pendientes de reconocer.
  int get pendingCount => _pages.where((p) => p.status == OcrStatus.pending).length;

  bool get canSave => _pages.isNotEmpty && !_ocrRunning && !anyProcessing;

  int indexOf(String pageId) => _pages.indexWhere((p) => p.id == pageId);
  CapturePage? byId(String pageId) {
    final i = indexOf(pageId);
    return i < 0 ? null : _pages[i];
  }

  /// Páginas para guardar en Rust, en orden.
  List<OcrPageInput> toPageInputs() => [for (final p in _pages) p.toPageInput()];

  // ─────────────── Selección ───────────────

  void select(int index) {
    if (_pages.isEmpty) return;
    final i = index.clamp(0, _pages.length - 1);
    if (i == _selected) return;
    _selected = i;
    _notify();
  }

  void setOcrAvailable(bool available) {
    if (_ocrAvailable == available) return;
    _ocrAvailable = available;
    for (var i = 0; i < _pages.length; i++) {
      final p = _pages[i];
      if (!available && (p.status == OcrStatus.pending || p.status == OcrStatus.skipped)) {
        _pages[i] = p.copyWith(status: OcrStatus.unavailable);
      } else if (available && p.status == OcrStatus.unavailable) {
        _pages[i] = p.copyWith(status: OcrStatus.pending);
      }
    }
    _notify();
  }

  OcrStatus get _initialStatus => _ocrAvailable ? OcrStatus.pending : OcrStatus.unavailable;

  String _file(String name) => '$workDir/$name';

  // ─────────────── Páginas ───────────────

  /// Normaliza y añade imágenes (en orden) en [insertAt] o al final. Selecciona la primera añadida.
  /// Las imágenes que fallan se omiten y se informan en [AddImagesResult.errors].
  Future<AddImagesResult> addImages(List<String> sources, PageOrigin origin, {int? insertAt}) async {
    final added = <CapturePage>[];
    final errors = <Object>[];
    var at = insertAt == null ? _pages.length : insertAt.clamp(0, _pages.length);
    _preparing += sources.length;
    _notify();
    for (final src in sources) {
      final id = _newId();
      try {
        final base = await _process(input: src, output: _file('${id}_b0.jpg'), quarterTurns: 0);
        if (_disposed) {
          await _deleteFile(base.path);
          break;
        }
        final page = CapturePage(
          id: id,
          origin: origin,
          basePath: base.path,
          baseWidth: base.width,
          baseHeight: base.height,
          status: _initialStatus,
        );
        at = at.clamp(0, _pages.length);
        _pages.insert(at, page);
        if (added.isEmpty) _selected = at;
        at++;
        added.add(page);
      } catch (e) {
        errors.add(e);
      } finally {
        _preparing--;
        _notify();
      }
    }
    return AddImagesResult(added: added, errors: errors);
  }

  /// «Repetir»: sustituye la imagen de una página (descarta giro, recorte y texto).
  Future<void> replaceImage(String pageId, String source) async {
    final page = byId(pageId);
    if (page == null || _processing.contains(pageId)) return;
    _processing.add(pageId);
    _notify();
    try {
      final rev = page.revision + 1;
      final base = await _process(input: source, output: _file('${pageId}_b$rev.jpg'), quarterTurns: 0);
      final current = byId(pageId);
      if (current == null || _disposed) {
        await _deleteFile(base.path);
        return;
      }
      final oldFiles = {current.basePath, ?current.processedPath};
      _replace(
        current.copyWith(
          basePath: base.path,
          baseWidth: base.width,
          baseHeight: base.height,
          quarterTurns: 0,
          crop: null,
          processedPath: null,
          processedWidth: null,
          processedHeight: null,
          revision: rev,
          status: _initialStatus,
          ocr: null,
          text: '',
          error: null,
        ),
      );
      for (final f in oldFiles) {
        await _deleteFile(f);
      }
    } finally {
      _processing.remove(pageId);
      _notify();
    }
  }

  /// Gira 90° en sentido horario (el recorte se transforma para conservar su contenido).
  Future<void> rotate(String pageId) {
    final page = byId(pageId);
    if (page == null) return Future.value();
    final crop = page.crop;
    return _editImage(pageId, (page.quarterTurns + 1) % 4, crop == null ? null : rotateCropClockwise(crop));
  }

  /// Aplica un recorte (normalizado respecto a la imagen girada). null = imagen completa.
  Future<void> setCrop(String pageId, CropRect? crop) {
    final page = byId(pageId);
    if (page == null) return Future.value();
    return _editImage(pageId, page.quarterTurns, normalizeCrop(crop));
  }

  Future<void> _editImage(String pageId, int quarterTurns, CropRect? crop) async {
    final page = byId(pageId);
    if (page == null || _processing.contains(pageId)) return;
    _processing.add(pageId);
    _notify();
    try {
      final rev = page.revision + 1;
      ProcessedImage? out;
      if (quarterTurns != 0 || crop != null) {
        out = await _process(
          input: page.basePath,
          output: _file('${pageId}_r$rev.jpg'),
          quarterTurns: quarterTurns,
          crop: crop,
        );
      }
      final current = byId(pageId);
      if (current == null || _disposed) {
        if (out != null) await _deleteFile(out.path);
        return;
      }
      final old = current.processedPath;
      _replace(
        current.copyWith(
          quarterTurns: quarterTurns,
          crop: crop,
          processedPath: out?.path,
          processedWidth: out?.width,
          processedHeight: out?.height,
          revision: rev,
          status: _initialStatus,
          ocr: null,
          text: '',
          error: null,
        ),
      );
      if (old != null && old != out?.path) await _deleteFile(old);
    } finally {
      _processing.remove(pageId);
      _notify();
    }
  }

  /// Quita la página (sin borrar sus ficheros, para poder deshacer). Devuelve la página quitada.
  CapturePage? removeAt(int index) {
    if (index < 0 || index >= _pages.length) return null;
    final removed = _pages.removeAt(index);
    if (_selected >= _pages.length) _selected = _pages.isEmpty ? 0 : _pages.length - 1;
    _notify();
    return removed;
  }

  /// Deshace [removeAt].
  void restore(CapturePage page, int index) {
    if (indexOf(page.id) >= 0) return;
    final at = index.clamp(0, _pages.length);
    _pages.insert(at, page);
    _selected = at;
    _notify();
  }

  /// Mueve una página a otra posición (orden de las páginas en la nota).
  void move(int from, int to) {
    if (from < 0 || from >= _pages.length) return;
    final target = to.clamp(0, _pages.length - 1);
    if (from == target) return;
    final p = _pages.removeAt(from);
    _pages.insert(target, p);
    _selected = target;
    _notify();
  }

  void updateText(String pageId, String text) {
    final page = byId(pageId);
    if (page == null || page.text == text) return;
    _replace(page.copyWith(text: text));
  }

  // ─────────────── OCR ───────────────

  /// Reconoce, en orden, todas las páginas pendientes (incluidas las que se añadan mientras tanto).
  /// La UI sigue usable. [cancelOcr] deja sin reconocer las páginas restantes.
  Future<void> runOcr() async {
    if (_ocrRunning || !_ocrAvailable || _disposed) return;
    _ocrRunning = true;
    _cancelRequested = false;
    _notify();
    try {
      while (!_cancelRequested && !_disposed) {
        final next = _pages.where((p) => p.status == OcrStatus.pending && !_processing.contains(p.id));
        if (next.isEmpty) break;
        final page = next.first;
        _ocrPageId = page.id;
        _replace(page.copyWith(status: OcrStatus.running, error: null));
        OcrResult? result;
        Object? error;
        try {
          result = await _recognize(page.imagePath);
        } catch (e) {
          error = e;
        }
        if (_disposed) return;
        final current = byId(page.id);
        // Página quitada o imagen cambiada mientras tanto: se descarta este resultado.
        if (current == null || current.revision != page.revision) continue;
        if (result != null) {
          _replace(current.copyWith(status: OcrStatus.done, ocr: result, text: result.text, error: null));
        } else if (error != null && isNativeError(error, NativeErrorCode.unsupported)) {
          // El motor no está disponible en este dispositivo: el resto se guarda solo como imagen.
          _ocrAvailable = false;
          for (var i = 0; i < _pages.length; i++) {
            final p = _pages[i];
            if (p.status == OcrStatus.pending || p.status == OcrStatus.running) {
              _pages[i] = p.copyWith(status: OcrStatus.unavailable);
            }
          }
          break;
        } else {
          _replace(
            current.copyWith(status: OcrStatus.failed, error: _describe(error ?? 'Error desconocido')),
          );
        }
      }
      if (_cancelRequested) {
        for (var i = 0; i < _pages.length; i++) {
          final p = _pages[i];
          if (p.status == OcrStatus.pending || p.status == OcrStatus.running) {
            _pages[i] = p.copyWith(status: OcrStatus.skipped);
          }
        }
      }
    } finally {
      _ocrRunning = false;
      _ocrPageId = null;
      _notify();
    }
  }

  /// Detiene el reconocimiento tras la página en curso (cuyo resultado se conserva).
  void cancelOcr() {
    if (!_ocrRunning || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
  }

  /// Vuelve a poner en cola una página fallida u omitida y reanuda el reconocimiento.
  Future<void> retryOcr(String pageId) {
    final page = byId(pageId);
    if (page == null || !_ocrAvailable) return Future.value();
    if (page.status == OcrStatus.failed || page.status == OcrStatus.skipped) {
      _replace(page.copyWith(status: OcrStatus.pending, error: null));
    }
    return runOcr();
  }

  /// Pone en cola todas las páginas omitidas o fallidas y reanuda el reconocimiento.
  Future<void> retryAll() {
    if (!_ocrAvailable) return Future.value();
    for (var i = 0; i < _pages.length; i++) {
      final p = _pages[i];
      if (p.status == OcrStatus.failed || p.status == OcrStatus.skipped) {
        _pages[i] = p.copyWith(status: OcrStatus.pending, error: null);
      }
    }
    _notify();
    return runOcr();
  }

  // ─────────────── Interno ───────────────

  void _replace(CapturePage page) {
    final i = indexOf(page.id);
    if (i < 0) return;
    _pages[i] = page;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRequested = true;
    super.dispose();
  }
}
