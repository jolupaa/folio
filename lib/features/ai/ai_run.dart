import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors.dart';
import '../../src/rust/api/types.dart';

/// Fase de una tarea de IA en streaming (Started → Progress/Sources → Token* → Done|Cancelled|Error).
enum AiRunPhase { starting, running, done, cancelled, error }

/// Estado acumulado de una tarea de IA a partir de sus eventos. Inmutable; [apply] es puro.
@immutable
class AiRunState {
  const AiRunState({
    this.phase = AiRunPhase.starting,
    this.taskId,
    this.status,
    this.progress,
    this.text = '',
    this.citations = const [],
    this.insufficient = false,
    this.resultId,
    this.threadId,
    this.error,
    this.cancelRequested = false,
  });

  final AiRunPhase phase;
  final String? taskId;

  /// Último mensaje de progreso («Buscando en tus notas…», «Resumiendo parte 2 de 5…»).
  final String? status;

  /// 0..1 si la tarea informa de progreso determinado.
  final double? progress;

  /// Texto acumulado (tokens) o, al terminar, el resultado completo validado.
  final String text;
  final List<Citation> citations;
  final bool insufficient;

  /// Id del mensaje (conversación) o del material de estudio guardado.
  final String? resultId;
  final String? threadId;
  final String? error;
  final bool cancelRequested;

  bool get isActive => phase == AiRunPhase.starting || phase == AiRunPhase.running;
  bool get isFinished => !isActive;

  AiRunState copyWith({
    AiRunPhase? phase,
    String? taskId,
    String? status,
    bool clearStatus = false,
    double? progress,
    String? text,
    List<Citation>? citations,
    bool? insufficient,
    String? resultId,
    String? threadId,
    String? error,
    bool? cancelRequested,
  }) => AiRunState(
    phase: phase ?? this.phase,
    taskId: taskId ?? this.taskId,
    status: clearStatus ? null : (status ?? this.status),
    progress: progress ?? this.progress,
    text: text ?? this.text,
    citations: citations ?? this.citations,
    insufficient: insufficient ?? this.insufficient,
    resultId: resultId ?? this.resultId,
    threadId: threadId ?? this.threadId,
    error: error ?? this.error,
    cancelRequested: cancelRequested ?? this.cancelRequested,
  );

  /// Aplica un evento. Los eventos posteriores a un estado final se ignoran.
  AiRunState apply(AiEvent e) {
    if (isFinished) return this;
    final base = copyWith(
      taskId: e.taskId.isEmpty ? null : e.taskId,
      threadId: e.threadId,
      insufficient: insufficient || e.insufficient,
    );
    switch (e.kind) {
      case AiEventKind.started:
        return base.copyWith(phase: AiRunPhase.running, status: e.text.trim().isEmpty ? null : e.text.trim());
      case AiEventKind.progress:
        return base.copyWith(
          phase: AiRunPhase.running,
          status: e.text.trim().isEmpty ? null : e.text.trim(),
          progress: e.progress?.clamp(0.0, 1.0),
        );
      case AiEventKind.sources:
        return base.copyWith(
          phase: AiRunPhase.running,
          citations: e.citations,
          status: e.text.trim().isEmpty ? null : e.text.trim(),
        );
      case AiEventKind.token:
        return base.copyWith(phase: AiRunPhase.running, text: text + e.text);
      case AiEventKind.done:
        return base.copyWith(
          phase: AiRunPhase.done,
          text: e.text.isNotEmpty ? e.text : text,
          citations: e.citations.isNotEmpty ? e.citations : citations,
          resultId: e.resultId,
          progress: 1,
          clearStatus: true,
        );
      case AiEventKind.cancelled:
        return base.copyWith(phase: AiRunPhase.cancelled, clearStatus: true);
      case AiEventKind.error:
        return base.copyWith(
          phase: AiRunPhase.error,
          error: e.text.trim().isEmpty ? 'No se pudo completar la tarea.' : e.text.trim(),
          clearStatus: true,
        );
    }
  }

  /// Error del propio stream (excepción de Rust antes o durante la tarea).
  AiRunState failWith(Object error) =>
      isFinished ? this : copyWith(phase: AiRunPhase.error, error: humanError(error), clearStatus: true);

  /// El stream terminó sin evento final (no debería ocurrir): se trata como error.
  AiRunState closed() => isFinished
      ? this
      : (cancelRequested
            ? copyWith(phase: AiRunPhase.cancelled, clearStatus: true)
            : copyWith(phase: AiRunPhase.error, error: 'La tarea terminó de forma inesperada.', clearStatus: true));
}

/// Consume un stream de [AiEvent] y notifica cada cambio de estado. Gestiona la cancelación
/// incluso si se pide antes de recibir `Started` (aún sin `task_id`).
class AiRunner extends ChangeNotifier {
  AiRunner({required this.start, required this.cancelTask});

  /// Abre el stream de eventos (se llama una sola vez en [run]).
  final Stream<AiEvent> Function() start;

  /// `cancel_task` de Rust: true si la tarea existía.
  final bool Function(String taskId) cancelTask;
  StreamSubscription<AiEvent>? _sub;
  AiRunState _state = const AiRunState();
  bool _disposed = false;
  final _done = Completer<AiRunState>();

  AiRunState get state => _state;

  /// Se completa con el estado final.
  Future<AiRunState> get finished => _done.future;

  void run() {
    if (_sub != null) return;
    try {
      _sub = start().listen(_onEvent, onError: _onError, onDone: _onDone, cancelOnError: true);
    } catch (e) {
      _onError(e);
    }
  }

  void cancel() {
    if (_state.isFinished || _state.cancelRequested) return;
    _set(_state.copyWith(cancelRequested: true));
    final id = _state.taskId;
    if (id != null) _tryCancel(id);
  }

  void _tryCancel(String id) {
    var existed = false;
    try {
      existed = cancelTask(id);
    } catch (_) {
      existed = false;
    }
    if (!existed) {
      // La tarea ya no existe en Rust: cerramos localmente.
      _sub?.cancel();
      _set(_state.copyWith(phase: AiRunPhase.cancelled, clearStatus: true));
    }
  }

  void _onEvent(AiEvent e) {
    final hadTask = _state.taskId != null;
    _set(_state.apply(e));
    if (!hadTask && _state.taskId != null && _state.cancelRequested && _state.isActive) {
      _tryCancel(_state.taskId!);
    }
  }

  void _onError(Object error, [StackTrace? _]) => _set(_state.failWith(error));

  void _onDone() => _set(_state.closed());

  void _set(AiRunState s) {
    _state = s;
    if (s.isFinished && !_done.isCompleted) _done.complete(s);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_state.isActive) {
      final id = _state.taskId;
      if (id != null) {
        try {
          cancelTask(id);
        } catch (_) {}
      }
    }
    _sub?.cancel();
    super.dispose();
  }
}
