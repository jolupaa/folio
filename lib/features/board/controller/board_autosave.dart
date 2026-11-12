import 'dart:async';

import 'package:flutter/foundation.dart';

enum SaveStatus {
  /// Sin cambios desde que se abrió.
  idle,

  /// Hay cambios esperando al temporizador.
  pending,
  saving,
  saved,
  error,
}

/// Guardado automático con espera (debounce) tras el último cambio, guardados serializados
/// (nunca dos a la vez) y vaciado inmediato al salir o al pasar a segundo plano.
class BoardAutosave extends ChangeNotifier {
  BoardAutosave({required Future<void> Function() save, this.delay = const Duration(seconds: 1)})
    : _save = save;

  final Future<void> Function() _save;
  final Duration delay;

  Timer? _timer;
  Future<void>? _inFlight;
  int _changes = 0;
  int _savedChanges = 0;
  int _successfulSaves = 0;
  SaveStatus _status = SaveStatus.idle;
  Object? _lastError;
  bool _disposed = false;

  SaveStatus get status => _status;
  Object? get lastError => _lastError;
  bool get isDirty => _changes != _savedChanges;

  /// Nº de guardados completados con éxito en esta sesión.
  int get successfulSaves => _successfulSaves;

  /// Registra un cambio y reinicia la espera.
  void markDirty() {
    _changes++;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
    if (_status != SaveStatus.saving) _setStatus(SaveStatus.pending);
  }

  /// Guarda ya si hay cambios pendientes (espera a un guardado en curso y repite si hace falta).
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    while (true) {
      final running = _inFlight;
      if (running != null) {
        await running;
        continue;
      }
      if (!isDirty) return;
      final target = _changes;
      final f = _run(target);
      _inFlight = f;
      try {
        await f;
      } finally {
        if (identical(_inFlight, f)) _inFlight = null;
      }
      if (_status == SaveStatus.error) return;
    }
  }

  Future<void> _run(int target) async {
    _setStatus(SaveStatus.saving);
    try {
      await _save();
      _savedChanges = target;
      _successfulSaves++;
      _lastError = null;
      _setStatus(isDirty ? SaveStatus.pending : SaveStatus.saved);
    } catch (e) {
      _lastError = e;
      _setStatus(SaveStatus.error);
    }
  }

  void _setStatus(SaveStatus s) {
    if (_status == s || _disposed) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
