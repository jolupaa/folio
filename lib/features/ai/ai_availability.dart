import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../src/rust/api/types.dart';
import '../models/download_manager.dart';
import '../models/models_gateway.dart';

/// Disponibilidad de la IA local para generar.
enum AiAvailability {
  /// Hay un modelo de lenguaje instalado.
  ready,

  /// Falta el modelo de lenguaje.
  modelMissing,

  /// El dispositivo no cumple los requisitos y no hay modelo instalado.
  deviceUnsupported,
}

AiAvailability availabilityOf(AiStatus s) {
  if (s.llmInstalled) return AiAvailability.ready;
  return s.deviceSupported ? AiAvailability.modelMissing : AiAvailability.deviceUnsupported;
}

/// Modelo de lenguaje recomendado para este dispositivo (o el primero disponible).
ModelInfo? recommendedLlm(List<ModelInfo> models, DeviceInfo? device) {
  final llms = [
    for (final m in models)
      if (m.role == ModelRole.llm) m,
  ];
  if (llms.isEmpty) return null;
  final id = device?.recommendedLlmId;
  for (final m in llms) {
    if (m.id == id) return m;
  }
  for (final m in llms) {
    if (m.supportedOnDevice && m.tierLabel.toLowerCase().contains('recomendado')) return m;
  }
  for (final m in llms) {
    if (m.supportedOnDevice) return m;
  }
  return llms.first;
}

/// Tarjeta de aviso con icono, título, texto y acción (docs/DESIGN.md §8).
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.tone = NoticeTone.info,
    this.child,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final NoticeTone tone;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (bg, fg) = switch (tone) {
      NoticeTone.info => (c.accentSoft, c.accent),
      NoticeTone.warning => (c.highlight.withValues(alpha: 0.55), c.textPrimary),
      NoticeTone.error => (c.danger.withValues(alpha: 0.12), c.danger),
    };
    return Container(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Insets.radiusGroup)),
      padding: const EdgeInsets.all(Insets.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: fg, size: 22),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                if (message != null) ...[
                  const SizedBox(height: Insets.xs),
                  Text(message!, style: context.text.bodyMedium?.copyWith(color: c.textSecondary)),
                ],
                ?child,
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: Insets.sm),
                  FilledButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum NoticeTone { info, warning, error }

/// Estado «modelo no instalado»: tamaño de la descarga recomendada y botón «Descargar».
/// Si ya hay una descarga en curso, muestra su progreso.
class ModelMissingCard extends ConsumerWidget {
  const ModelMissingCard({super.key, required this.onOpenModels});

  final VoidCallback onOpenModels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final device = ref.watch(deviceInfoProvider).value;
    final downloads = ref.watch(downloadsProvider);
    final llm = recommendedLlm(models, device);
    final live = llm == null ? null : downloads[llm.id];
    final running = llm != null && ref.read(downloadsProvider.notifier).isRunning(llm.id);
    String message;
    if (llm == null) {
      message = 'Descarga un modelo de IA para usar el asistente. Se hace una sola vez; después funciona sin conexión.';
    } else if (running && live != null) {
      final pct = ((live.fraction ?? 0) * 100).floor();
      message = 'Descargando ${llm.displayName}: $pct %. Puedes seguir usando Folio mientras tanto.';
    } else {
      message =
          '${llm.displayName} · ${Fmt.bytes(llm.sizeBytes)}. Se descarga una sola vez; '
          'después la IA funciona sin conexión.';
    }
    return NoticeCard(
      icon: Icons.download_for_offline_rounded,
      title: running ? 'Descargando el modelo de IA' : 'Modelo de IA no instalado',
      message: message,
      actionLabel: running ? 'Ver progreso' : 'Descargar',
      onAction: onOpenModels,
    );
  }
}

/// Estado «dispositivo no compatible»: explicación y funciones que siguen disponibles.
class DeviceUnsupportedCard extends StatelessWidget {
  const DeviceUnsupportedCard({super.key, this.reason, required this.onOpenModels});

  final String? reason;
  final VoidCallback onOpenModels;

  @override
  Widget build(BuildContext context) {
    final r = reason?.trim();
    return NoticeCard(
      icon: Icons.memory_rounded,
      tone: NoticeTone.warning,
      title: 'Este dispositivo no puede ejecutar la IA local',
      message:
          '${r == null || r.isEmpty ? 'No cumple los requisitos mínimos de memoria.' : r} '
          'Las notas, la búsqueda, el escaneo con OCR y las pizarras siguen funcionando con normalidad.',
      actionLabel: 'Ver modelos',
      onAction: onOpenModels,
    );
  }
}
