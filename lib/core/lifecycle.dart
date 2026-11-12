import 'dart:async';

import 'package:flutter/widgets.dart';

import '../src/rust/api/ai.dart' as ai;

/// Libera el modelo de IA de memoria tras 30 s en segundo plano (Rust pospone la liberación
/// si hay una generación en curso). Evita que el sistema cierre la app por presión de memoria.
class AiMemoryLifecycle {
  AiMemoryLifecycle() {
    _listener = AppLifecycleListener(onHide: _schedule, onShow: () => _timer?.cancel());
  }

  late final AppLifecycleListener _listener;
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 30), () {
      ai.releaseAiMemory().catchError((_) {});
    });
  }

  void dispose() {
    _timer?.cancel();
    _listener.dispose();
  }
}
