import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../ai/ai_availability.dart' show NoticeCard, NoticeTone, recommendedLlm;
import '../ai/skeleton.dart';
import 'download_manager.dart';
import 'models_gateway.dart';

/// Gestor de modelos de IA (Ajustes › Modelos de IA).
class ModelsScreen extends ConsumerWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider);
    final device = ref.watch(deviceInfoProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Modelos de IA')),
      body: models.when(
        skipLoadingOnRefresh: true,
        loading: () => const SkeletonList(rows: 5, label: 'Cargando modelos'),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudieron cargar los modelos',
          message: humanError(e),
          actionLabel: 'Reintentar',
          onAction: () {
            ref.invalidate(modelsProvider);
            ref.invalidate(deviceInfoProvider);
          },
        ),
        data: (list) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(modelsProvider);
            ref.invalidate(deviceInfoProvider);
            await ref.read(modelsProvider.future).catchError((_) => const <ModelInfo>[]);
          },
          child: _ModelsBody(models: list, device: device),
        ),
      ),
    );
  }
}

class _ModelsBody extends ConsumerWidget {
  const _ModelsBody({required this.models, required this.device});

  final List<ModelInfo> models;
  final AsyncValue<DeviceInfo> device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dev = device.value;
    final llms = [
      for (final m in models)
        if (m.role == ModelRole.llm) m,
    ];
    final embeddings = [
      for (final m in models)
        if (m.role == ModelRole.embedding) m,
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: Insets.xxl),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, 0),
          child: NoticeCard(
            icon: Icons.wifi_off_rounded,
            title: 'IA 100 % en tu dispositivo',
            message:
                'Necesitas conexión solo para descargar; después la IA funciona sin conexión. '
                'Tus notas nunca salen del dispositivo.',
          ),
        ),
        _DeviceSection(device: device),
        _InitialDownloadSection(models: models, device: dev),
        if (llms.isNotEmpty)
          _ModelGroup(
            header: 'Modelos de lenguaje',
            footer: 'Responden preguntas y crean resúmenes, esquemas, flashcards y cuestionarios. Solo se usa uno a la vez.',
            models: llms,
            device: dev,
          ),
        if (embeddings.isNotEmpty)
          _ModelGroup(
            header: 'Búsqueda semántica',
            footer: 'Encuentra fragmentos relacionados aunque no compartan palabras. Sin él, la IA usa búsqueda por palabras.',
            models: embeddings,
            device: dev,
          ),
        if (models.isEmpty)
          const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'No hay modelos disponibles',
            message: 'Esta versión de Folio no incluye un catálogo de modelos.',
            compact: true,
          ),
      ],
    );
  }
}

/// Encabezado de sección con el estilo de las listas agrupadas.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.gutter + Insets.xs, Insets.xl, Insets.gutter, Insets.sm),
    child: Semantics(header: true, child: Text(text, style: context.text.titleMedium?.copyWith(fontSize: 20))),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
    child: Material(
      color: context.colors.surface,
      borderRadius: BorderRadius.circular(Insets.radiusGroup),
      child: Padding(padding: const EdgeInsets.all(Insets.lg), child: child),
    ),
  );
}

// ─────────────────────────── Dispositivo ───────────────────────────

class _DeviceSection extends ConsumerWidget {
  const _DeviceSection({required this.device});
  final AsyncValue<DeviceInfo> device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Este dispositivo'),
        _Card(
          child: device.when(
            skipLoadingOnRefresh: true,
            loading: () => SizedBox(
              height: 96,
              child: Semantics(label: 'Comprobando el dispositivo', child: const SizedBox.expand()),
            ),
            error: (e, _) => Row(
              children: [
                Icon(Icons.error_outline_rounded, color: c.danger),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text('No se pudo leer el dispositivo: ${humanError(e)}', style: context.text.bodyMedium),
                ),
                TextButton(onPressed: () => ref.invalidate(deviceInfoProvider), child: const Text('Reintentar')),
              ],
            ),
            data: (d) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoRow(
                  icon: Icons.memory_rounded,
                  label: 'Memoria RAM',
                  value: d.availableRamBytes > 0
                      ? '${Fmt.bytes(d.totalRamBytes)} (${Fmt.bytes(d.availableRamBytes)} libres)'
                      : Fmt.bytes(d.totalRamBytes),
                ),
                _InfoRow(
                  icon: Icons.sd_storage_rounded,
                  label: 'Almacenamiento libre',
                  value: Fmt.bytes(d.freeStorageBytes),
                ),
                if (d.cpuCores > 0)
                  _InfoRow(
                    icon: Icons.developer_board_rounded,
                    label: 'Procesador',
                    value: '${Fmt.count(d.cpuCores, 'núcleo', 'núcleos')}${d.arch.isEmpty ? '' : ' · ${d.arch}'}',
                  ),
                const SizedBox(height: Insets.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      d.canRunAnyLlm ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                      color: d.canRunAnyLlm ? c.accent : c.danger,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        d.canRunAnyLlm ? 'Compatible con la IA local' : 'No cumple los requisitos de la IA local',
                        style: context.text.titleSmall,
                      ),
                    ),
                  ],
                ),
                for (final n in d.notes)
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.xs, left: 32),
                    child: Text(n, style: context.text.bodySmall),
                  ),
                if (!d.canRunAnyLlm)
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.xs, left: 32),
                    child: Text(
                      'Las notas, la búsqueda, el escaneo con OCR y las pizarras funcionan igual.',
                      style: context.text.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
    child: Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.colors.textSecondary),
          const SizedBox(width: Insets.md),
          Expanded(child: Text(label, style: context.text.bodyMedium)),
          const SizedBox(width: Insets.sm),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}

// ─────────────────────────── Descarga inicial ───────────────────────────

/// Modelos de la descarga inicial: el LLM recomendado y el de búsqueda semántica.
List<ModelInfo> initialDownloadSet(List<ModelInfo> models, DeviceInfo? device) {
  final llm = recommendedLlm(models, device);
  final out = <ModelInfo>[?llm];
  for (final m in models) {
    if (m.role == ModelRole.embedding) {
      out.add(m);
      break;
    }
  }
  return out;
}

/// Bytes que faltan por descargar de un modelo.
int remainingBytes(ModelInfo m, ModelViewState v) {
  if (v.status == ModelStatus.installed) return 0;
  final total = m.sizeBytes > 0 ? m.sizeBytes : v.totalBytes;
  return (total - v.downloadedBytes).clamp(0, total);
}

class _InitialDownloadSection extends ConsumerWidget {
  const _InitialDownloadSection({required this.models, required this.device});

  final List<ModelInfo> models;
  final DeviceInfo? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final set = initialDownloadSet(models, device);
    if (set.isEmpty) return const SizedBox.shrink();
    final downloads = ref.watch(downloadsProvider);
    final notifier = ref.read(downloadsProvider.notifier);
    final views = {for (final m in set) m.id: modelViewState(m, downloads[m.id], running: notifier.isRunning(m.id))};
    final installed = set.every((m) => views[m.id]!.status == ModelStatus.installed);
    final pending = [
      for (final m in set)
        if (views[m.id]!.status != ModelStatus.installed) m,
    ];
    final anyRunning = pending.any((m) => notifier.isRunning(m.id));
    final needed = pending.fold<int>(0, (sum, m) => sum + remainingBytes(m, views[m.id]!));
    final free = device?.freeStorageBytes;
    final lacksSpace = free != null && free > 0 && needed > free;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Descarga inicial'),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                installed
                    ? 'Completada. La IA ya funciona sin conexión; solo vuelve a descargar si cambias de modelo.'
                    : 'Se hace una sola vez. Descarga lo recomendado para este dispositivo; '
                          'la descarga continúa aunque salgas de esta pantalla. Te recomendamos usar wifi.',
                style: context.text.bodyMedium,
              ),
              const SizedBox(height: Insets.md),
              for (final m in set)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  child: Row(
                    children: [
                      Icon(
                        switch (views[m.id]!.status) {
                          ModelStatus.installed => Icons.check_circle_rounded,
                          ModelStatus.downloading || ModelStatus.verifying => Icons.downloading_rounded,
                          ModelStatus.failed => Icons.error_outline_rounded,
                          _ => Icons.radio_button_unchecked_rounded,
                        },
                        size: 20,
                        color: views[m.id]!.status == ModelStatus.failed ? c.danger : c.accent,
                      ),
                      const SizedBox(width: Insets.sm),
                      Expanded(child: Text('${m.displayName} · ${m.tierLabel}', style: context.text.bodyMedium)),
                      Text(
                        views[m.id]!.status == ModelStatus.installed ? 'Instalado' : _statusShort(views[m.id]!, m),
                        style: context.text.bodySmall,
                      ),
                    ],
                  ),
                ),
              if (!installed) ...[
                if (lacksSpace) ...[
                  const SizedBox(height: Insets.sm),
                  NoticeCard(
                    icon: Icons.sd_card_alert_rounded,
                    tone: NoticeTone.error,
                    title: 'Espacio insuficiente',
                    message:
                        'Necesitas ${Fmt.bytes(needed)} libres y hay ${Fmt.bytes(free)}. '
                        'Libera espacio y vuelve a intentarlo.',
                  ),
                ],
                const SizedBox(height: Insets.md),
                FilledButton.icon(
                  onPressed: anyRunning || lacksSpace
                      ? null
                      : () async {
                          for (final m in pending) {
                            if (notifier.isRunning(m.id)) continue;
                            if (!m.supportedOnDevice) {
                              final ok = await _confirmUnsupported(context, m);
                              if (!ok) continue;
                            }
                            notifier.start(m);
                          }
                        },
                  icon: Icon(anyRunning ? Icons.downloading_rounded : Icons.download_rounded),
                  label: Text(anyRunning ? 'Descargando…' : 'Descargar todo (${Fmt.bytes(needed)})'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _statusShort(ModelViewState v, ModelInfo m) => switch (v.status) {
    ModelStatus.downloading => '${v.percent} %',
    ModelStatus.verifying => 'Verificando',
    ModelStatus.paused => 'En pausa · ${v.percent} %',
    ModelStatus.failed => 'Error',
    _ => Fmt.bytes(m.sizeBytes),
  };
}

// ─────────────────────────── Lista de modelos ───────────────────────────

class _ModelGroup extends StatelessWidget {
  const _ModelGroup({required this.header, required this.footer, required this.models, required this.device});

  final String header;
  final String footer;
  final List<ModelInfo> models;
  final DeviceInfo? device;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(header),
        for (final m in models)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.md),
            child: _Card(
              child: ModelCard(model: m, device: device),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Insets.gutter + Insets.xs, 0, Insets.gutter, 0),
          child: Text(footer, style: context.text.bodySmall),
        ),
      ],
    );
  }
}

Future<bool> _confirmUnsupported(BuildContext context, ModelInfo m) => confirmAction(
  context,
  title: 'No compatible con este dispositivo',
  message:
      '${m.displayName} necesita al menos ${Fmt.bytes(m.minRamBytes)} de RAM. Puede ir muy lento o cerrarse '
      'por falta de memoria. ¿Descargarlo de todos modos?',
  confirmLabel: 'Descargar igualmente',
);

/// Tarjeta de un modelo: nivel, tamaño, licencia, RAM mínima, estado, progreso y acciones.
class ModelCard extends ConsumerWidget {
  const ModelCard({super.key, required this.model, this.device});

  final ModelInfo model;
  final DeviceInfo? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final m = model;
    final live = ref.watch(downloadsProvider.select((s) => s[m.id]));
    final notifier = ref.read(downloadsProvider.notifier);
    final running = notifier.isRunning(m.id);
    final v = modelViewState(m, live, running: running);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.displayName, style: context.text.titleMedium),
                  const SizedBox(height: Insets.xs),
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.xs,
                    children: [
                      if (m.tierLabel.isNotEmpty) _Badge(text: m.tierLabel, strong: true),
                      if (m.isActive && v.status == ModelStatus.installed)
                        const _Badge(text: 'En uso', icon: Icons.check_rounded),
                      if (!m.supportedOnDevice)
                        const _Badge(
                          text: 'No compatible con este dispositivo',
                          icon: Icons.warning_amber_rounded,
                          danger: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (m.description.isNotEmpty) ...[
          const SizedBox(height: Insets.sm),
          Text(m.description, style: context.text.bodyMedium?.copyWith(color: c.textSecondary)),
        ],
        const SizedBox(height: Insets.sm),
        _Spec(label: 'Tamaño', value: Fmt.bytes(m.sizeBytes)),
        _Spec(label: 'RAM mínima', value: Fmt.bytes(m.minRamBytes)),
        if (m.quantization.isNotEmpty || m.contextLength > 0)
          _Spec(
            label: 'Detalles',
            value: [
              if (m.family.isNotEmpty) m.family,
              if (m.quantization.isNotEmpty) m.quantization,
              if (m.contextLength > 0) 'contexto ${NumberFormatCompact.tokens(m.contextLength)}',
            ].join(' · '),
          ),
        _LicenseRow(model: m),
        const SizedBox(height: Insets.sm),
        _StatusBlock(model: m, view: v),
        const SizedBox(height: Insets.sm),
        _Actions(model: m, view: v, running: running, device: device),
      ],
    );
  }
}

/// Formato compacto de tokens de contexto: «32 k».
abstract final class NumberFormatCompact {
  static String tokens(int n) =>
      n >= 1024 && n % 1024 == 0 ? '${n ~/ 1024} k' : (n >= 1000 ? '${(n / 1000).round()} k' : '$n');
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.icon, this.strong = false, this.danger = false});
  final String text;
  final IconData? icon;
  final bool strong;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = danger ? c.danger : (strong ? c.accent : c.textPrimary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(
        color: danger ? c.danger.withValues(alpha: 0.12) : (strong ? c.accentSoft : c.surfaceAlt),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
          Flexible(
            child: Text(text, style: context.text.labelSmall?.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}

class _Spec extends StatelessWidget {
  const _Spec({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: context.text.bodySmall)),
          Expanded(child: Text(value, style: context.text.bodyMedium)),
        ],
      ),
    ),
  );
}

class _LicenseRow extends StatelessWidget {
  const _LicenseRow({required this.model});
  final ModelInfo model;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final url = m.licenseUrl.trim();
    return Row(
      children: [
        SizedBox(width: 110, child: Text('Licencia', style: context.text.bodySmall)),
        Expanded(
          child: url.isEmpty
              ? Text(m.license.isEmpty ? 'No indicada' : m.license, style: context.text.bodyMedium)
              : Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Insets.xs)),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      showInfoSnack(context, 'Enlace de la licencia copiado');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: Text(
                      m.license.isEmpty ? 'Copiar enlace' : m.license,
                      semanticsLabel: 'Licencia ${m.license}. Copiar enlace',
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.model, required this.view});
  final ModelInfo model;
  final ModelViewState view;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = view;
    switch (v.status) {
      case ModelStatus.notInstalled:
        return _StatusLine(icon: Icons.cloud_download_outlined, text: 'No instalado', color: c.textSecondary);
      case ModelStatus.installed:
        return _StatusLine(
          icon: Icons.check_circle_rounded,
          text: 'Instalado · funciona sin conexión',
          color: c.accent,
        );
      case ModelStatus.verifying:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusLine(
              icon: Icons.verified_outlined,
              text: 'Verificando la integridad del fichero…',
              color: c.textSecondary,
            ),
            const SizedBox(height: Insets.sm),
            const LinearProgressIndicator(semanticsLabel: 'Verificando'),
          ],
        );
      case ModelStatus.downloading:
      case ModelStatus.paused:
        final paused = v.status == ModelStatus.paused;
        final details = <String>[
          '${Fmt.bytes(v.downloadedBytes)} de ${Fmt.bytes(v.totalBytes)}',
          if (!paused && v.bytesPerSecond > 0) '${Fmt.bytes(v.bytesPerSecond.round())}/s',
          if (!paused && v.eta != null) 'quedan ${formatEta(v.eta!)}',
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: _StatusLine(
                icon: paused ? Icons.pause_circle_outline_rounded : Icons.downloading_rounded,
                text: paused ? 'En pausa · ${v.percent} %' : 'Descargando · ${v.percent} %',
                color: paused ? c.textSecondary : c.accent,
              ),
            ),
            const SizedBox(height: Insets.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: v.fraction,
                minHeight: 6,
                semanticsLabel: 'Progreso de la descarga',
                semanticsValue: '${v.percent} %',
              ),
            ),
            const SizedBox(height: Insets.xs),
            Text(details.join(' · '), style: context.text.bodySmall),
          ],
        );
      case ModelStatus.failed:
        return _StatusLine(
          icon: Icons.error_outline_rounded,
          text: 'La descarga falló: ${v.error?.trim().isNotEmpty == true ? v.error!.trim() : 'error desconocido'}',
          color: c.danger,
        );
    }
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: Insets.sm),
      Expanded(
        child: Text(
          text,
          style: context.text.bodyMedium?.copyWith(color: color == context.colors.danger ? color : null),
        ),
      ),
    ],
  );
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.model, required this.view, required this.running, required this.device});

  final ModelInfo model;
  final ModelViewState view;
  final bool running;
  final DeviceInfo? device;

  Future<void> _run(BuildContext context, Future<void> Function() action, String errorPrefix) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: errorPrefix);
    }
  }

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final m = model;
    final free = device?.freeStorageBytes;
    final needed = remainingBytes(m, view);
    if (free != null && free > 0 && needed > free) {
      await showAdaptiveDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog.adaptive(
          title: const Text('Espacio insuficiente'),
          content: Text(
            'Para descargar ${m.displayName} necesitas ${Fmt.bytes(needed)} libres y hay ${Fmt.bytes(free)}. '
            'Libera espacio y vuelve a intentarlo.',
          ),
          actions: [adaptiveAction(ctx, label: 'Aceptar', onPressed: () => Navigator.pop(ctx))],
        ),
      );
      return;
    }
    if (!m.supportedOnDevice) {
      final ok = await _confirmUnsupported(context, m);
      if (!ok) return;
    }
    ref.read(downloadsProvider.notifier).start(m);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final m = model;
    final installed = view.status == ModelStatus.installed;
    final freed = installed ? m.sizeBytes : view.downloadedBytes;
    final ok = await confirmAction(
      context,
      title: installed ? '¿Eliminar ${m.displayName}?' : '¿Descartar la descarga?',
      message: [
        'Se liberarán ${Fmt.bytes(freed)}.',
        if (installed && m.isActive && m.role == ModelRole.llm)
          'La IA no estará disponible hasta que descargues o elijas otro modelo.',
        if (installed && m.role == ModelRole.embedding) 'La IA usará búsqueda por palabras.',
        if (installed) 'Podrás volver a descargarlo cuando quieras.',
      ].join(' '),
      confirmLabel: installed ? 'Eliminar' : 'Descartar',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await _run(context, () => ref.read(downloadsProvider.notifier).delete(m.id), 'No se pudo eliminar');
    if (context.mounted) showInfoSnack(context, 'Se liberaron ${Fmt.bytes(freed)}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = model;
    final notifier = ref.read(downloadsProvider.notifier);
    final c = context.colors;
    final buttons = <Widget>[];
    switch (view.status) {
      case ModelStatus.notInstalled:
        buttons.add(
          FilledButton.icon(
            onPressed: () => _download(context, ref),
            icon: const Icon(Icons.download_rounded),
            label: Text('Descargar (${Fmt.bytes(m.sizeBytes)})'),
          ),
        );
      case ModelStatus.downloading:
        buttons
          ..add(
            OutlinedButton.icon(
              onPressed: () => _run(context, () => notifier.pause(m.id), 'No se pudo pausar'),
              icon: const Icon(Icons.pause_rounded),
              label: const Text('Pausar'),
            ),
          )
          ..add(
            TextButton(
              onPressed: () => _run(context, () => notifier.cancel(m.id), 'No se pudo cancelar'),
              child: Text('Cancelar', style: TextStyle(color: c.danger)),
            ),
          );
      case ModelStatus.verifying:
        break;
      case ModelStatus.paused:
        buttons
          ..add(
            FilledButton.icon(
              onPressed: () => _download(context, ref),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Reanudar'),
            ),
          )
          ..add(
            TextButton(
              onPressed: () => _run(context, () => notifier.cancel(m.id), 'No se pudo cancelar'),
              child: Text('Cancelar', style: TextStyle(color: c.danger)),
            ),
          );
      case ModelStatus.failed:
        buttons
          ..add(
            FilledButton.icon(
              onPressed: () => _download(context, ref),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reintentar'),
            ),
          )
          ..add(
            TextButton(
              onPressed: () => _run(context, () => notifier.cancel(m.id), 'No se pudo descartar'),
              child: Text('Descartar', style: TextStyle(color: c.danger)),
            ),
          );
      case ModelStatus.installed:
        if (m.role == ModelRole.llm && !m.isActive) {
          buttons.add(
            FilledButton.icon(
              onPressed: () => _run(context, () async {
                await notifier.setActive(m.id);
                if (context.mounted) showInfoSnack(context, 'Ahora se usa ${m.displayName}');
              }, 'No se pudo cambiar de modelo'),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Usar este modelo'),
            ),
          );
        }
        buttons.add(
          TextButton.icon(
            onPressed: () => _delete(context, ref),
            icon: Icon(Icons.delete_outline_rounded, color: c.danger),
            label: Text('Eliminar', style: TextStyle(color: c.danger)),
          ),
        );
    }
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: buttons,
    );
  }
}
