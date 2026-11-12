import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import 'ai_availability.dart';
import 'ai_scope.dart';
import 'generation_sheet.dart';
import 'source_picker.dart';

/// Lo que el usuario eligió en la hoja de acciones de IA.
sealed class AiSheetResult {
  const AiSheetResult();
}

/// Abrir una conversación nueva con una pregunta.
final class AskResult extends AiSheetResult {
  const AskResult(this.scope, this.question);
  final AiScope scope;
  final String question;
}

/// Generar un material de estudio.
final class StudyResult extends AiSheetResult {
  const StudyResult(this.request);
  final StudyRequest request;
}

/// Ir al gestor de modelos.
final class OpenModelsResult extends AiSheetResult {
  const OpenModelsResult();
}

/// Límites de cantidad de la UI (Rust acota además a 3..=30).
const flashcardCountRange = (min: 5, max: 30, initial: 15);
const quizCountRange = (min: 3, max: 30, initial: 10);

/// Longitud máxima del fragmento seleccionado que se envía para «Explicar».
const maxExplainChars = 1200;

String explainQuestion(String selected) {
  var t = selected.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length > maxExplainChars) t = '${t.substring(0, maxExplainChars)}…';
  return 'Explícame: «$t»';
}

String quizMixLabel(QuizMix m) => switch (m) {
  QuizMix.multipleChoice => 'Opción múltiple',
  QuizMix.openEnded => 'Abierta',
  QuizMix.mixed => 'Mixto',
};

/// Hoja compacta del asistente: ámbito, estado de la IA y acciones.
class AiActionsSheet extends ConsumerStatefulWidget {
  const AiActionsSheet({super.key, required this.scope, this.selectedText});

  final AiScope scope;
  final String? selectedText;

  @override
  ConsumerState<AiActionsSheet> createState() => _AiActionsSheetState();
}

enum _Expanded { none, flashcards, quiz }

class _AiActionsSheetState extends ConsumerState<AiActionsSheet> {
  late AiScope _scope = widget.scope;
  ScopeOption? _custom;
  _Expanded _expanded = _Expanded.none;
  int _flashCount = flashcardCountRange.initial;
  int _quizCount = quizCountRange.initial;
  QuizMix _quizMix = QuizMix.mixed;
  final _question = TextEditingController();

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  void _ask() {
    final q = _question.text.trim();
    if (q.isEmpty) return;
    Navigator.pop(context, AskResult(_scope, q));
  }

  void _generate(StudyKind kind, String label, {DetailLevel detail = DetailLevel.brief, int? count, QuizMix? mix}) {
    Navigator.pop(
      context,
      StudyResult(
        StudyRequest(
          kind: kind,
          scope: _scope,
          label: label,
          options: StudyOptions(detail: detail, count: count ?? quizCountRange.initial, quizMix: mix ?? QuizMix.mixed),
        ),
      ),
    );
  }

  Future<void> _pickSources() async {
    final initial = _scope.kind == ScopeKind.notes || _scope.kind == ScopeKind.note ? _scope.ids : const <String>[];
    final ids = await pickSources(context, initial: initial);
    if (ids == null || ids.isEmpty || !mounted) return;
    final scope = ids.length == 1 ? Scopes.note(ids.first) : Scopes.notes(ids);
    setState(() {
      _custom = ScopeOption(
        scope: scope,
        label: ids.length == 1 ? '1 nota elegida' : '${ids.length} notas elegidas',
        icon: scopeIcon(ScopeKind.notes),
      );
      _scope = scope;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final options = ref.watch(scopeOptionsProvider(ScopeRef(widget.scope)));
    final summary = ref.watch(scopeSummaryProvider(ScopeRef(_scope)));
    final status = ref.watch(aiStatusProvider);
    final availability = status.whenOrNull(data: availabilityOf);
    final ready = availability == AiAvailability.ready;
    final summaryValue = summary.value;
    final hasNotes = summaryValue == null || summaryValue.noteCount > 0;
    final enabled = ready && hasNotes && !summary.hasError;
    final selected = widget.selectedText?.trim();

    final chips = <ScopeOption>[
      ...?options.value,
      if (options.value == null)
        ScopeOption(scope: widget.scope, label: fallbackScopeLabel(widget.scope), icon: scopeIcon(widget.scope.kind)),
    ];
    final custom = _custom;
    if (custom != null && !chips.any((o) => sameScope(o.scope, custom.scope))) chips.add(custom);
    final scopeLabel = summaryValue?.label ?? fallbackScopeLabel(_scope);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, color: c.accent),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Semantics(header: true, child: Text('Asistente', style: context.text.titleMedium)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.md),
            // ── Ámbito ──
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
              child: Row(
                children: [
                  for (final o in chips)
                    Padding(
                      padding: const EdgeInsets.only(right: Insets.sm),
                      child: ChoiceChip(
                        avatar: Icon(o.icon, size: 18),
                        label: Text(o.label),
                        selected: sameScope(o.scope, _scope),
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _scope = o.scope),
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.checklist_rounded, size: 18),
                    label: const Text('Elegir fuentes…'),
                    onPressed: _pickSources,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.xs, Insets.gutter, 0),
              child: _ScopeSummaryLine(
                summary: summary,
                onRetry: () => ref.invalidate(scopeSummaryProvider(ScopeRef(_scope))),
              ),
            ),
            // ── Estado de la IA ──
            if (availability == AiAvailability.modelMissing)
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, 0),
                child: ModelMissingCard(onOpenModels: () => Navigator.pop(context, const OpenModelsResult())),
              ),
            if (availability == AiAvailability.deviceUnsupported)
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, 0),
                child: DeviceUnsupportedCard(
                  reason: status.value?.unavailableReason,
                  onOpenModels: () => Navigator.pop(context, const OpenModelsResult()),
                ),
              ),
            if (status.hasError)
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, 0),
                child: NoticeCard(
                  icon: Icons.error_outline_rounded,
                  tone: NoticeTone.error,
                  title: 'No se pudo comprobar el estado de la IA',
                  message: humanError(status.error!),
                  actionLabel: 'Reintentar',
                  onAction: () => ref.invalidate(aiStatusProvider),
                ),
              ),
            if (ready && status.value?.deviceSupported == false)
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, 0),
                child: const NoticeCard(
                  icon: Icons.speed_rounded,
                  tone: NoticeTone.warning,
                  title: 'Puede ir lento en este dispositivo',
                  message: 'El modelo instalado supera los requisitos recomendados para este dispositivo.',
                ),
              ),
            if (summaryValue != null && summaryValue.noteCount == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, 0),
                child: const NoticeCard(
                  icon: Icons.note_alt_outlined,
                  title: 'No hay notas en este ámbito',
                  message: 'Elige otro ámbito o escribe algo antes de usar el asistente.',
                ),
              ),
            const SizedBox(height: Insets.md),
            // ── Preguntar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _question,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _ask(),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(hintText: 'Pregunta sobre ${lowerScopeLabel(scopeLabel)}…'),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  IconButton.filled(
                    tooltip: 'Preguntar',
                    onPressed: enabled && _question.text.trim().isNotEmpty ? _ask : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            if (selected != null && selected.isNotEmpty)
              _ActionTile(
                icon: Icons.lightbulb_outline_rounded,
                title: 'Explicar selección',
                subtitle: '«${selected.length > 90 ? '${selected.substring(0, 90)}…' : selected}»',
                enabled: enabled,
                onTap: () => Navigator.pop(context, AskResult(_scope, explainQuestion(selected))),
              ),
            _ActionTile(
              icon: Icons.short_text_rounded,
              title: 'Resumen breve',
              enabled: enabled,
              onTap: () => _generate(StudyKind.summary, 'Resumen breve'),
            ),
            _ActionTile(
              icon: Icons.notes_rounded,
              title: 'Resumen detallado',
              enabled: enabled,
              onTap: () => _generate(StudyKind.summary, 'Resumen detallado', detail: DetailLevel.detailed),
            ),
            _ActionTile(
              icon: Icons.account_tree_outlined,
              title: 'Esquema',
              enabled: enabled,
              onTap: () => _generate(StudyKind.outline, 'Esquema'),
            ),
            _ActionTile(
              icon: Icons.key_rounded,
              title: 'Conceptos clave',
              enabled: enabled,
              onTap: () => _generate(StudyKind.keyConcepts, 'Conceptos clave'),
            ),
            _ActionTile(
              icon: Icons.style_outlined,
              title: 'Flashcards',
              subtitle: _expanded == _Expanded.flashcards ? null : '$_flashCount tarjetas',
              enabled: enabled,
              expanded: _expanded == _Expanded.flashcards,
              onTap: () =>
                  setState(() => _expanded = _expanded == _Expanded.flashcards ? _Expanded.none : _Expanded.flashcards),
            ),
            if (_expanded == _Expanded.flashcards && enabled)
              _OptionsPanel(
                children: [
                  _CountSlider(
                    label: 'Número de tarjetas',
                    value: _flashCount,
                    min: flashcardCountRange.min,
                    max: flashcardCountRange.max,
                    onChanged: (v) => setState(() => _flashCount = v),
                  ),
                  FilledButton.icon(
                    onPressed: () => _generate(StudyKind.flashcards, 'Flashcards', count: _flashCount),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text('Crear $_flashCount flashcards'),
                  ),
                ],
              ),
            _ActionTile(
              icon: Icons.quiz_outlined,
              title: 'Cuestionario',
              subtitle: _expanded == _Expanded.quiz ? null : '$_quizCount preguntas · ${quizMixLabel(_quizMix)}',
              enabled: enabled,
              expanded: _expanded == _Expanded.quiz,
              onTap: () => setState(() => _expanded = _expanded == _Expanded.quiz ? _Expanded.none : _Expanded.quiz),
            ),
            if (_expanded == _Expanded.quiz && enabled)
              _OptionsPanel(
                children: [
                  _CountSlider(
                    label: 'Número de preguntas',
                    value: _quizCount,
                    min: quizCountRange.min,
                    max: quizCountRange.max,
                    onChanged: (v) => setState(() => _quizCount = v),
                  ),
                  Text('Tipo de preguntas', style: context.text.labelMedium),
                  const SizedBox(height: Insets.sm),
                  SegmentedButton<QuizMix>(
                    showSelectedIcon: false,
                    segments: [for (final m in QuizMix.values) ButtonSegment(value: m, label: Text(quizMixLabel(m)))],
                    selected: {_quizMix},
                    onSelectionChanged: (s) => setState(() => _quizMix = s.first),
                  ),
                  const SizedBox(height: Insets.md),
                  FilledButton.icon(
                    onPressed: () => _generate(StudyKind.quiz, 'Cuestionario', count: _quizCount, mix: _quizMix),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text('Crear cuestionario de $_quizCount'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// «Esta nota» → «esta nota» para usar la etiqueta dentro de una frase; los nombres propios
/// (carpetas) se mantienen.
String lowerScopeLabel(String label) => switch (label) {
  'Esta nota' => 'esta nota',
  'Toda la biblioteca' => 'toda la biblioteca',
  _ => label,
};

class _ScopeSummaryLine extends StatelessWidget {
  const _ScopeSummaryLine({required this.summary, required this.onRetry});

  final AsyncValue<ScopeSummary> summary;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = summary.value;
    if (s == null && summary.hasError) {
      return Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.danger),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text('No se pudo leer el ámbito: ${humanError(summary.error!)}', style: context.text.bodySmall),
          ),
          TextButton(onPressed: onRetry, child: const Text('Reintentar')),
        ],
      );
    }
    if (s == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        child: Text('Comprobando las fuentes…', style: context.text.bodySmall),
      );
    }
    final warning = pendingIndexWarning(s);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: 'Ámbito: ${scopeSummaryLine(s)}',
            excludeSemantics: true,
            child: Text(scopeSummaryLine(s), style: context.text.bodySmall),
          ),
          if (warning != null) ...[
            const SizedBox(height: Insets.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.hourglass_top_rounded, size: 16, color: c.textSecondary),
                const SizedBox(width: Insets.xs),
                Expanded(child: Text(warning, style: context.text.bodySmall)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.enabled,
    required this.onTap,
    this.expanded,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final VoidCallback onTap;

  /// null = no desplegable.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      enabled: enabled,
      minTileHeight: 52,
      leading: Icon(icon, color: enabled ? c.accent : c.textTertiary),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: expanded == null
          ? null
          : Icon(expanded! ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: c.textSecondary),
      onTap: onTap,
    );
  }
}

class _OptionsPanel extends StatelessWidget {
  const _OptionsPanel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(Insets.gutter, 0, Insets.gutter, Insets.sm),
    padding: const EdgeInsets.all(Insets.md),
    decoration: BoxDecoration(
      color: context.colors.surfaceAlt,
      borderRadius: BorderRadius.circular(Insets.radiusGroup),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

class _CountSlider extends StatelessWidget {
  const _CountSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: context.text.labelMedium)),
            IconButton(
              tooltip: 'Menos',
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            SizedBox(
              width: 36,
              child: Text('$value', textAlign: TextAlign.center, style: context.text.titleMedium),
            ),
            IconButton(
              tooltip: 'Más',
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          semanticFormatterCallback: (v) => '${v.round()}',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}
