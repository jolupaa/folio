import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/models.dart' as models;
import '../../src/rust/api/types.dart';
import '../ai/ai_gateway.dart' show noAutoRetry;

/// Acceso a la API del gestor de modelos de Rust. Sustituible en pruebas con
/// [modelsGatewayProvider].
abstract interface class ModelsGateway {
  Future<List<ModelInfo>> listModels();
  Future<DeviceInfo> deviceInfo();
  Stream<DownloadEvent> download(String modelId);
  Future<void> pause(String modelId);
  Future<void> cancel(String modelId);
  Future<void> delete(String modelId);
  Future<void> setActiveLlm(String modelId);
}

class FrbModelsGateway implements ModelsGateway {
  const FrbModelsGateway();

  @override
  Future<List<ModelInfo>> listModels() => models.listModels();

  @override
  Future<DeviceInfo> deviceInfo() => models.deviceInfo();

  @override
  Stream<DownloadEvent> download(String modelId) => models.downloadModel(modelId: modelId);

  @override
  Future<void> pause(String modelId) => models.pauseModelDownload(modelId: modelId);

  @override
  Future<void> cancel(String modelId) => models.cancelModelDownload(modelId: modelId);

  @override
  Future<void> delete(String modelId) => models.deleteModel(modelId: modelId);

  @override
  Future<void> setActiveLlm(String modelId) => models.setActiveLlm(modelId: modelId);
}

final modelsGatewayProvider = Provider<ModelsGateway>((ref) => const FrbModelsGateway());

final modelsProvider = FutureProvider<List<ModelInfo>>(
  (ref) => ref.watch(modelsGatewayProvider).listModels(),
  retry: noAutoRetry,
);

final deviceInfoProvider = FutureProvider<DeviceInfo>(
  (ref) => ref.watch(modelsGatewayProvider).deviceInfo(),
  retry: noAutoRetry,
);
