import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../study/study_gateway.dart';
import '../study/study_models.dart' show countStreamedItems;
import 'ai_gateway.dart';
import 'ai_run.dart';
import 'citations.dart';

/// Petición de generación de un material de estudio.
@immutable
class StudyRequest {
  const StudyRequest({required this.kind, required this.scope, required this.options, required this.label});

  final StudyKind kind;
  final AiScope scope;
  final StudyOptions options;

  /// «Resumen breve», «Flashcards»…
  final String label;
}

/// Resultado de la hoja de generación.
sealed class GenerationOutcome {
  const GenerationOutcome();
}

final class GenerationDone extends GenerationOutcome {
  const GenerationDone(this.studyId);
  final String studyId;
}

final class GenerationCancelled extends GenerationOutcome {
  const GenerationCancelled();
}

/// Muestra la hoja de progreso y devuelve el resultado (null si se cerró tras un error).
Future<GenerationOutcome?> showGenerationSheet(BuildContext context, StudyRequest request) {
  return showModalBottomSheet<GenerationOutcome>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => GenerationSheet(request: request),
  );
}

/// Progreso de la generación: mensajes de estado, texto en streaming, cancelar y errores.
class GenerationSheet extends ConsumerStatefulWidget {
  const GenerationSheet({super.key, required this.request});

  final StudyRequest request;

  @override
  ConsumerState<GenerationSheet> createState() => _GenerationSheetState();
}

class _GenerationSheetState extends ConsumerState<GenerationSheet> {
  AiRunner? _runner;
  final _scroll = ScrollController();
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final gw = ref.read(aiGatewayProvider);
    final req = widget.request;
    final old = _runner;
    final runner = AiRunner(
      start: () => gw.generateStudy(kind: req.kind, scope: req.scope, options: req.options),
      cancelTask: gw.cancelTask,
    );
    runner.addListener(_onChange);
    setState(() => _runner = runner);
    old?.removeListener(_onChange);
    old?.dispose();
    runner.finished.then((state) => _onFinished(runner, state));
    runner.run();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  void _onFinished(AiRunner runner, AiRunState s) {
    if (!mounted || _closing || !identical(runner, _runner)) return;
    switch (s.phase) {
      case AiRunPhase.done:
        final id = s.resultId;
        if (id == null || id.isEmpty) return; // Se muestra como error en build().
        ref.read(studyRevisionProvider.notifier).bump();
        ref.read(libraryRevisionProvider.notifier).bump();
        _close(GenerationDone(id));
      case AiRunPhase.cancelled:
        _close(const GenerationCancelled());
      default:
        break;
    }
  }

  void _close(GenerationOutcome outcome) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(outcome);
  }

  Future<void> _confirmCancel() async {
    final runner = _runner;
    if (runner == null || !runner.state.isActive) return;
    final ok = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('¿Cancelar la generación?'),
        content: const Text('Se perderá lo generado hasta ahora.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Seguir')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Cancelar', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) runner.cancel();
  }

  @override
  void dispose() {
    _runner?.removeListener(_onChange);
    _runner?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final runner = _runner!;
    final s = runner.state;
    final req = widget.request;
    final missingResult = s.phase == AiRunPhase.done && (s.resultId == null || s.resultId!.isEmpty);
    final failed = s.phase == AiRunPhase.error || missingResult;
    final structured = req.kind == StudyKind.flashcards || req.kind == StudyKind.quiz;
    final count = structured ? countStreamedItems(s.text, req.kind) : 0;

    return PopScope(
      canPop: !s.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmCancel();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.gutter, 0, Insets.gutter, Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: c.accent),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      failed ? 'No se pudo crear: ${req.label.toLowerCase()}' : 'Creando: ${req.label.toLowerCase()}',
                      style: context.text.titleMedium,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.md),
            if (failed) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, color: c.danger),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        missingResult ? 'El material no se pudo guardar. Inténtalo de nuevo.' : s.error!,
                        style: context.text.bodyMedium,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reintentar'),
              ),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
            ] else ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  _statusText(s, req, count),
                  style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
                ),
              ),
              const SizedBox(height: Insets.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: s.phase == AiRunPhase.done ? 1 : s.progress,
                  minHeight: 6,
                  semanticsLabel: 'Progreso de la generación',
                ),
              ),
              if (s.citations.isNotEmpty) ...[
                const SizedBox(height: Insets.sm),
                Text(_sourcesText(s.citations), style: context.text.bodySmall),
              ],
              if (!structured && s.text.trim().isNotEmpty) ...[
                const SizedBox(height: Insets.md),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(Insets.radiusGroup),
                    ),
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(Insets.md),
                      child: Text(stripCitations(s.text), style: context.text.bodyMedium),
                    ),
                  ),
                ),
              ],
              if (s.insufficient) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  'Las fuentes tienen poca información sobre este tema; el resultado puede ser breve.',
                  style: context.text.bodySmall,
                ),
              ],
              const SizedBox(height: Insets.lg),
              OutlinedButton.icon(
                onPressed: s.isActive && !s.cancelRequested ? _confirmCancel : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(s.cancelRequested ? 'Cancelando…' : 'Cancelar'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusText(AiRunState s, StudyRequest req, int count) {
    if (s.phase == AiRunPhase.done) return 'Listo. Abriendo…';
    if (count > 0) {
      final noun = req.kind == StudyKind.flashcards
          ? (count == 1 ? 'tarjeta' : 'tarjetas')
          : (count == 1 ? 'pregunta' : 'preguntas');
      return '${s.status ?? 'Generando'} · $count $noun';
    }
    if (s.status != null) return s.status!;
    if (s.text.isNotEmpty) return 'Escribiendo…';
    return s.phase == AiRunPhase.starting ? 'Preparando…' : 'Trabajando…';
  }

  String _sourcesText(List<Citation> citations) {
    final notes = {for (final c in citations) c.noteId}.length;
    final frag = citations.length == 1 ? '1 fragmento' : '${citations.length} fragmentos';
    return 'Usando $frag de ${notes == 1 ? '1 nota' : '$notes notas'}';
  }
}
