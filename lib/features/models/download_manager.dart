import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import 'models_gateway.dart';

/// Último estado conocido de la descarga de un modelo (eventos de `download_model`).
@immutable
class DownloadProgress {
  const DownloadProgress({
    required this.modelId,
    required this.kind,
    required this.downloadedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
    this.message,
  });

  final String modelId;
  final DownloadEventKind kind;
  final int downloadedBytes;
  final int totalBytes;

  /// Velocidad suavizada (bytes/s).
  final double bytesPerSecond;
  final String? message;

  bool get isRunning =>
      kind == DownloadEventKind.started || kind == DownloadEventKind.progress || kind == DownloadEventKind.verifying;

  double? get fraction => totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : null;

  /// Tiempo restante estimado (null si no se puede estimar).
  Duration? get eta {
    if (bytesPerSecond <= 0 || totalBytes <= 0 || downloadedBytes >= totalBytes) return null;
    return Duration(seconds: ((totalBytes - downloadedBytes) / bytesPerSecond).ceil());
  }

  DownloadProgress copyWith({
    DownloadEventKind? kind,
    int? downloadedBytes,
    int? totalBytes,
    double? bytesPerSecond,
    String? message,
  }) => DownloadProgress(
    modelId: modelId,
    kind: kind ?? this.kind,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    message: message ?? this.message,
  );
}

/// Suavizado exponencial de la velocidad para que la estimación no oscile.
double smoothSpeed(double previous, double sample) {
  if (sample <= 0) return previous;
  if (previous <= 0) return sample;
  return previous * 0.7 + sample * 0.3;
}

/// Mantiene las suscripciones a las descargas a nivel de app: siguen activas aunque se cierre la
/// pantalla de modelos. Estado: último progreso conocido por modelo.
class DownloadsNotifier extends Notifier<Map<String, DownloadProgress>> {
  final _subs = <String, StreamSubscription<DownloadEvent>>{};
  final _lastSample = <String, ({int bytes, int atMs})>{};

  @override
  Map<String, DownloadProgress> build() {
    ref.onDispose(() {
      for (final s in _subs.values) {
        s.cancel();
      }
      _subs.clear();
    });
    return const {};
  }

  ModelsGateway get _gateway => ref.read(modelsGatewayProvider);

  /// true si hay una suscripción de descarga viva para el modelo.
  bool isRunning(String modelId) => _subs.containsKey(modelId);

  /// Inicia o reanuda la descarga (Rust usa HTTP Range para continuar el fichero parcial).
  void start(ModelInfo model) {
    final id = model.id;
    if (_subs.containsKey(id)) return;
    _lastSample.remove(id);
    _put(
      DownloadProgress(
        modelId: id,
        kind: DownloadEventKind.started,
        downloadedBytes: state[id]?.downloadedBytes ?? model.downloadedBytes,
        totalBytes: model.sizeBytes,
      ),
    );
    try {
      _subs[id] = _gateway
          .download(id)
          .listen((e) => _onEvent(id, e), onError: (Object e) => _onError(id, e), onDone: () => _onDone(id));
    } catch (e) {
      _onError(id, e);
    }
  }

  Future<void> pause(String modelId) async {
    await _gateway.pause(modelId);
    final cur = state[modelId];
    if (cur != null && cur.isRunning && !_subs.containsKey(modelId)) {
      _put(cur.copyWith(kind: DownloadEventKind.paused, bytesPerSecond: 0));
    }
    if (!_subs.containsKey(modelId)) _refreshLists();
  }

  /// Cancela la descarga y elimina el fichero parcial.
  Future<void> cancel(String modelId) async {
    await _gateway.cancel(modelId);
    await _subs.remove(modelId)?.cancel();
    _remove(modelId);
    _refreshLists();
  }

  /// Elimina el modelo instalado (o los restos de una descarga fallida).
  Future<void> delete(String modelId) async {
    await _subs.remove(modelId)?.cancel();
    await _gateway.delete(modelId);
    _remove(modelId);
    _refreshLists();
  }

  Future<void> setActive(String modelId) async {
    await _gateway.setActiveLlm(modelId);
    _refreshLists();
  }

  /// Olvida el estado local (p. ej. al descartar un error ya mostrado).
  void forget(String modelId) {
    if (!_subs.containsKey(modelId)) _remove(modelId);
  }

  void _onEvent(String id, DownloadEvent e) {
    final prev = state[id];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var speed = prev?.bytesPerSecond ?? 0;
    if (e.bytesPerSecond > 0) {
      speed = smoothSpeed(speed, e.bytesPerSecond.toDouble());
    } else if (e.kind == DownloadEventKind.progress) {
      final last = _lastSample[id];
      if (last != null && nowMs > last.atMs && e.downloadedBytes >= last.bytes) {
        speed = smoothSpeed(speed, (e.downloadedBytes - last.bytes) * 1000 / (nowMs - last.atMs));
      }
    }
    _lastSample[id] = (bytes: e.downloadedBytes, atMs: nowMs);
    final terminal = switch (e.kind) {
      DownloadEventKind.completed ||
      DownloadEventKind.paused ||
      DownloadEventKind.cancelled ||
      DownloadEventKind.failed => true,
      _ => false,
    };
    if (e.kind == DownloadEventKind.cancelled) {
      _remove(id);
    } else {
      _put(
        DownloadProgress(
          modelId: id,
          kind: e.kind,
          downloadedBytes: e.downloadedBytes > 0 ? e.downloadedBytes : (prev?.downloadedBytes ?? 0),
          totalBytes: e.totalBytes > 0 ? e.totalBytes : (prev?.totalBytes ?? 0),
          bytesPerSecond: terminal || e.kind == DownloadEventKind.verifying ? 0 : speed,
          message: e.message,
        ),
      );
    }
    if (terminal) {
      _subs.remove(id)?.cancel();
      _refreshLists();
    }
  }

  void _onError(String id, Object error) {
    _subs.remove(id)?.cancel();
    final prev = state[id];
    _put(
      DownloadProgress(
        modelId: id,
        kind: DownloadEventKind.failed,
        downloadedBytes: prev?.downloadedBytes ?? 0,
        totalBytes: prev?.totalBytes ?? 0,
        message: humanError(error),
      ),
    );
    _refreshLists();
  }

  void _onDone(String id) {
    if (_subs.remove(id) == null) return;
    // El stream se cerró sin evento final: Rust lo considera detenido.
    final cur = state[id];
    if (cur != null && cur.isRunning) {
      _put(cur.copyWith(kind: DownloadEventKind.paused, bytesPerSecond: 0));
    }
    _refreshLists();
  }

  void _put(DownloadProgress p) => state = {...state, p.modelId: p};

  void _remove(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }

  void _refreshLists() {
    ref.invalidate(modelsProvider);
    ref.invalidate(deviceInfoProvider);
    ref.invalidate(aiStatusProvider);
  }
}

final downloadsProvider = NotifierProvider<DownloadsNotifier, Map<String, DownloadProgress>>(DownloadsNotifier.new);

/// Estado efectivo de un modelo combinando la lista de Rust con el progreso en vivo.
@immutable
class ModelViewState {
  const ModelViewState({
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
    this.eta,
    this.error,
  });

  final ModelStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final Duration? eta;
  final String? error;

  double? get fraction => totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : null;
  int get percent => ((fraction ?? 0) * 100).floor();
}

/// Combina [ModelInfo] (persistido) con el último [DownloadProgress] (en memoria).
/// `running` indica si hay una suscripción viva: un estado «Downloading» persistido sin
/// suscripción (p. ej. tras cerrar la app) se muestra como pausado para poder reanudarlo.
ModelViewState modelViewState(ModelInfo info, DownloadProgress? live, {required bool running}) {
  final total = info.sizeBytes > 0 ? info.sizeBytes : (live?.totalBytes ?? 0);
  if (live != null) {
    final status = switch (live.kind) {
      DownloadEventKind.started || DownloadEventKind.progress => running ? ModelStatus.downloading : ModelStatus.paused,
      DownloadEventKind.verifying => running ? ModelStatus.verifying : ModelStatus.paused,
      DownloadEventKind.completed => ModelStatus.installed,
      DownloadEventKind.paused => ModelStatus.paused,
      DownloadEventKind.cancelled => ModelStatus.notInstalled,
      DownloadEventKind.failed => ModelStatus.failed,
    };
    // Si Rust ya refleja un estado definitivo más reciente (instalado o borrado), manda la lista.
    if (!running && info.status == ModelStatus.installed && status != ModelStatus.installed) {
      return ModelViewState(status: ModelStatus.installed, downloadedBytes: total, totalBytes: total);
    }
    return ModelViewState(
      status: status,
      downloadedBytes: status == ModelStatus.installed ? total : live.downloadedBytes,
      totalBytes: live.totalBytes > 0 ? live.totalBytes : total,
      bytesPerSecond: running ? live.bytesPerSecond : 0,
      eta: running ? live.eta : null,
      error: status == ModelStatus.failed ? (live.message ?? info.error) : null,
    );
  }
  final status = switch (info.status) {
    ModelStatus.downloading || ModelStatus.verifying => running ? info.status : ModelStatus.paused,
    final s => s,
  };
  return ModelViewState(
    status: status,
    downloadedBytes: status == ModelStatus.installed ? total : info.downloadedBytes,
    totalBytes: total,
    error: status == ModelStatus.failed ? info.error : null,
  );
}

/// «menos de 1 min», «3 min», «1 h 5 min».
String formatEta(Duration d) {
  if (d.inSeconds < 60) return 'menos de 1 min';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final m = d.inMinutes.remainder(60);
  return m == 0 ? '${d.inHours} h' : '${d.inHours} h $m min';
}
