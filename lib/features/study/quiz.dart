import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../ai/ai_availability.dart';
import '../ai/ai_gateway.dart';
import '../ai/ai_run.dart';
import '../ai/citation_widgets.dart';
import '../ai/citations.dart';
import 'study_common.dart';
import 'study_gateway.dart';
import 'study_labels.dart';
import 'study_models.dart';

/// Letra de una opción: A, B, C…
String optionLetter(int i) => String.fromCharCode(65 + i);

/// Respuesta de una pregunta de opción múltiple (corrección inmediata).
QuizAnswer gradeMcq(QuizQuestion q, int choice) {
  final correct = q.answerIndex == choice;
  return QuizAnswer(questionId: q.id, response: '$choice', correct: correct, score: correct ? 1 : 0);
}

/// Respuesta abierta corregida por la IA.
QuizAnswer openAnswerFromGrade(QuizQuestion q, String response, GradeResult g) =>
    QuizAnswer(questionId: q.id, response: response, correct: g.correct, score: g.score, feedback: g.feedback);

/// Respuesta autoevaluada (sin IA o si la corrección falla).
QuizAnswer selfAssessed(QuizQuestion q, String response, double score) =>
    QuizAnswer(questionId: q.id, response: response, correct: score >= 0.5, score: score, feedback: 'Autoevaluada');

QuizAnswer skippedAnswer(QuizQuestion q) =>
    QuizAnswer(questionId: q.id, response: '', correct: false, score: 0, feedback: 'Sin responder');

/// Nº de preguntas que puntúan (las de opción múltiple sin respuesta correcta no cuentan).
int gradableCount(List<QuizQuestion> qs) => qs.where((q) => q.isGradable).length;

enum _Mode { overview, taking, results }

/// Cuestionario: resumen con intentos anteriores, realización con corrección y resultado final.
class QuizView extends ConsumerStatefulWidget {
  const QuizView({super.key, required this.item, required this.content, required this.onEdit});

  final StudyItem item;
  final QuizContent content;
  final VoidCallback onEdit;

  @override
  ConsumerState<QuizView> createState() => _QuizViewState();
}

class _QuizViewState extends ConsumerState<QuizView> {
  _Mode _mode = _Mode.overview;
  List<QuizQuestion> _questions = const [];
  int _index = 0;
  final Map<String, QuizAnswer> _answers = {};
  bool _saving = false;
  bool _saved = false;
  Object? _saveError;
  bool _leaving = false;

  void _start() {
    setState(() {
      _questions = List.of(widget.content.questions);
      _index = 0;
      _answers.clear();
      _saved = false;
      _saveError = null;
      _mode = _Mode.taking;
    });
  }

  List<QuizAnswer> get _orderedAnswers => [
    for (final q in _questions)
      if (_answers[q.id] case final a?) a,
  ];

  double get _score => quizScore(
    _orderedAnswers.where((a) {
      final q = _questions.firstWhere((q) => q.id == a.questionId);
      return q.isGradable;
    }),
    gradableCount(_questions),
  );

  void _answer(QuizAnswer a) => setState(() => _answers[a.questionId] = a);

  void _next() {
    if (_index < _questions.length - 1) {
      setState(() => _index++);
    } else {
      setState(() => _mode = _Mode.results);
      _save(completed: true);
    }
  }

  Future<bool> _save({required bool completed}) async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await ref
          .read(studyGatewayProvider)
          .saveQuizAttempt(
            widget.item.id,
            answersJson: encodeQuizAnswers(_orderedAnswers),
            score: _orderedAnswers.isEmpty ? null : _score,
            completed: completed,
          );
      ref.invalidate(quizAttemptsProvider(widget.item.id));
      if (!mounted) return true;
      setState(() {
        _saving = false;
        _saved = true;
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _saveError = e;
      });
      return false;
    }
  }

  Future<void> _confirmLeave() async {
    final choice = await showAdaptiveDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('¿Salir del cuestionario?'),
        content: Text(
          'Has respondido ${_answers.length} de ${_questions.length} preguntas. '
          'Puedes guardar el intento sin terminar.',
        ),
        actions: [
          adaptiveAction(ctx, label: 'Seguir', onPressed: () => Navigator.pop(ctx, 'stay')),
          adaptiveAction(
            ctx,
            label: 'Salir sin guardar',
            destructive: true,
            onPressed: () => Navigator.pop(ctx, 'discard'),
          ),
          adaptiveAction(ctx, label: 'Guardar y salir', onPressed: () => Navigator.pop(ctx, 'save')),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'stay') return;
    if (choice == 'save') {
      final ok = await _save(completed: false);
      if (!ok) {
        if (mounted) showErrorSnack(context, _saveError ?? 'Error', prefix: 'No se pudo guardar el intento');
        return;
      }
    }
    if (!mounted) return;
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final blockPop = _mode == _Mode.taking && _answers.isNotEmpty && !_leaving;
    return PopScope(
      canPop: !blockPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: switch (_mode) {
        _Mode.overview => _Overview(item: widget.item, content: widget.content, onStart: _start, onEdit: widget.onEdit),
        _Mode.taking => _Taking(
          key: ValueKey('q-$_index-${_questions[_index].id}'),
          item: widget.item,
          content: widget.content,
          question: _questions[_index],
          index: _index,
          total: _questions.length,
          answer: _answers[_questions[_index].id],
          onAnswer: _answer,
          onNext: _next,
          isLast: _index == _questions.length - 1,
        ),
        _Mode.results => _Results(
          questions: _questions,
          answers: _answers,
          score: _score,
          gradable: gradableCount(_questions),
          saving: _saving,
          saved: _saved,
          saveError: _saveError,
          onRetrySave: () => _save(completed: true),
          onRepeat: _start,
          onDone: () => setState(() => _mode = _Mode.overview),
        ),
      },
    );
  }
}

// ─────────────────────────── Resumen ───────────────────────────

class _Overview extends StatelessWidget {
  const _Overview({required this.item, required this.content, required this.onStart, required this.onEdit});

  final StudyItem item;
  final QuizContent content;
  final VoidCallback onStart;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final qs = content.questions;
    final mcq = qs.where((q) => q.isMcq).length;
    final open = qs.length - mcq;
    if (qs.isEmpty) {
      return EmptyState(
        icon: Icons.quiz_outlined,
        title: 'Este cuestionario no tiene preguntas',
        message: 'Añade preguntas a mano o crea otro cuestionario con el asistente.',
        actionLabel: 'Añadir preguntas',
        onAction: onEdit,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xxl),
      children: [
        StudyMetaLine(item: item),
        const SizedBox(height: Insets.lg),
        Container(
          padding: const EdgeInsets.all(Insets.lg),
          decoration: BoxDecoration(
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(Insets.radiusGroup),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(studyItemCount(StudyKind.quiz, qs.length), style: context.text.titleLarge),
              const SizedBox(height: Insets.xs),
              Text(
                [if (mcq > 0) '$mcq de opción múltiple', if (open > 0) '$open de respuesta abierta'].join(' · '),
                style: context.text.bodySmall,
              ),
              if (open > 0) ...[
                const SizedBox(height: Insets.sm),
                Text('Las respuestas abiertas las corrige la IA en tu dispositivo.', style: context.text.bodySmall),
              ],
              const SizedBox(height: Insets.lg),
              FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Empezar cuestionario'),
              ),
            ],
          ),
        ),
        const SizedBox(height: Insets.xl),
        Semantics(header: true, child: Text('Intentos anteriores', style: context.text.titleMedium)),
        const SizedBox(height: Insets.sm),
        _AttemptsList(studyId: item.id, content: content),
        SourcesSection(sources: item.sources),
      ],
    );
  }
}

class _AttemptsList extends ConsumerWidget {
  const _AttemptsList({required this.studyId, required this.content});

  final String studyId;
  final QuizContent content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final attempts = ref.watch(quizAttemptsProvider(studyId));
    return attempts.when(
      skipLoadingOnRefresh: true,
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.md),
        child: Text('Cargando intentos…', style: context.text.bodySmall),
      ),
      error: (e, _) => Row(
        children: [
          Icon(Icons.error_outline_rounded, color: c.danger, size: 20),
          const SizedBox(width: Insets.sm),
          Expanded(child: Text('No se pudieron cargar: ${humanError(e)}', style: context.text.bodySmall)),
          TextButton(onPressed: () => ref.invalidate(quizAttemptsProvider(studyId)), child: const Text('Reintentar')),
        ],
      ),
      data: (list) {
        if (list.isEmpty) {
          return Text(
            'Aún no has hecho este cuestionario.',
            style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
          );
        }
        final sorted = [...list]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return ClipRRect(
          borderRadius: BorderRadius.circular(Insets.radiusGroup),
          child: Material(
            color: c.surface,
            child: Column(
              children: [
                for (var i = 0; i < sorted.length; i++) ...[
                  if (i > 0) Divider(indent: Insets.lg + 56, height: 0.6, color: c.separator),
                  _AttemptTile(attempt: sorted[i], content: content),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AttemptTile extends StatelessWidget {
  const _AttemptTile({required this.attempt, required this.content});
  final QuizAttempt attempt;
  final QuizContent content;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final answers = parseQuizAnswers(attempt.answersJson);
    final correct = answers.where((a) => a.correct == true).length;
    final completed = attempt.completedAt != null;
    final score = attempt.score;
    return ListTile(
      minTileHeight: 64,
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: c.accentSoft,
        child: Text(
          score == null ? '–' : percentLabel(score),
          style: context.text.labelSmall?.copyWith(color: c.accent, fontWeight: FontWeight.w700),
        ),
      ),
      title: Text(Fmt.relativeDate(attempt.createdAt)),
      subtitle: Text(
        completed
            ? 'Completado · $correct de ${answers.length} correctas'
            : 'Sin terminar · ${answers.length == 1 ? '1 respondida' : '${answers.length} respondidas'}',
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: c.textTertiary),
      onTap: () => showAttemptSheet(context, attempt: attempt, content: content),
    );
  }
}

/// Detalle de un intento: pregunta, respuesta, corrección y comentario.
Future<void> showAttemptSheet(BuildContext context, {required QuizAttempt attempt, required QuizContent content}) {
  final answers = parseQuizAnswers(attempt.answersJson);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.85),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Insets.gutter, 0, Insets.gutter, Insets.xl),
        children: [
          Semantics(
            header: true,
            child: Text(
              'Intento · ${Fmt.relativeDate(attempt.createdAt)}'
              '${attempt.score == null ? '' : ' · ${percentLabel(attempt.score!)}'}',
              style: sheet.text.titleMedium,
            ),
          ),
          const SizedBox(height: Insets.md),
          if (answers.isEmpty) Text('Este intento no tiene respuestas.', style: sheet.text.bodyMedium),
          for (final a in answers) _AnswerReview(question: content.question(a.questionId), answer: a),
        ],
      ),
    ),
  );
}

class _AnswerReview extends StatelessWidget {
  const _AnswerReview({required this.question, required this.answer});
  final QuizQuestion? question;
  final QuizAnswer answer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final q = question;
    String response = answer.response;
    if (q != null && q.isMcq) {
      final i = int.tryParse(answer.response);
      if (i != null && i >= 0 && i < q.options.length) response = '${optionLetter(i)}. ${q.options[i]}';
    }
    if (response.trim().isEmpty) response = 'Sin responder';
    final verdict = _Verdict.of(answer);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q == null ? 'Pregunta eliminada' : stripCitations(q.question), style: context.text.titleSmall),
          const SizedBox(height: Insets.xs),
          Text('Tu respuesta: $response', style: context.text.bodyMedium),
          const SizedBox(height: Insets.xs),
          verdict.chip(context),
          if (answer.feedback != null && answer.feedback!.trim().isNotEmpty && answer.feedback != 'Autoevaluada')
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(answer.feedback!.trim(), style: context.text.bodySmall?.copyWith(color: c.textSecondary)),
            ),
        ],
      ),
    );
  }
}

/// Veredicto visible con icono y texto (no solo color).
class _Verdict {
  const _Verdict(this.label, this.icon, this.kind);

  final String label;
  final IconData icon;

  /// 1 correcta, 0 incorrecta, 2 parcial.
  final int kind;

  static _Verdict of(QuizAnswer a) {
    if (a.response.trim().isEmpty && a.correct != true)
      return const _Verdict('Sin responder', Icons.remove_circle_outline_rounded, 0);
    final s = a.effectiveScore;
    if (s >= 0.999 || (a.score == null && a.correct == true))
      return const _Verdict('Correcta', Icons.check_circle_rounded, 1);
    if (s > 0) return _Verdict('Parcial · ${percentLabel(s)}', Icons.adjust_rounded, 2);
    return const _Verdict('Incorrecta', Icons.cancel_rounded, 0);
  }

  Widget chip(BuildContext context) {
    final c = context.colors;
    final color = switch (kind) {
      1 => c.accent,
      2 => c.textPrimary,
      _ => c.danger,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Insets.xs),
        Text(label, style: context.text.labelMedium?.copyWith(color: color)),
      ],
    );
  }
}

// ─────────────────────────── Realización ───────────────────────────

class _Taking extends ConsumerStatefulWidget {
  const _Taking({
    super.key,
    required this.item,
    required this.content,
    required this.question,
    required this.index,
    required this.total,
    required this.answer,
    required this.onAnswer,
    required this.onNext,
    required this.isLast,
  });

  final StudyItem item;
  final QuizContent content;
  final QuizQuestion question;
  final int index;
  final int total;
  final QuizAnswer? answer;
  final ValueChanged<QuizAnswer> onAnswer;
  final VoidCallback onNext;
  final bool isLast;

  @override
  ConsumerState<_Taking> createState() => _TakingState();
}

class _TakingState extends ConsumerState<_Taking> {
  final _response = TextEditingController();
  AiRunner? _grader;
  String? _gradeError;
  bool _selfAssess = false;

  @override
  void dispose() {
    _grader?.removeListener(_onGrader);
    _grader?.dispose();
    _response.dispose();
    super.dispose();
  }

  QuizQuestion get q => widget.question;

  void _grade() {
    final text = _response.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    final gw = ref.read(aiGatewayProvider);
    final runner = AiRunner(
      start: () => gw.gradeOpenAnswer(studyId: widget.item.id, questionId: q.id, response: text),
      cancelTask: gw.cancelTask,
    );
    _grader?.removeListener(_onGrader);
    _grader?.dispose();
    setState(() {
      _grader = runner;
      _gradeError = null;
    });
    runner.addListener(_onGrader);
    runner.finished.then((s) {
      if (!mounted || !identical(runner, _grader)) return;
      switch (s.phase) {
        case AiRunPhase.done:
          final g = GradeResult.tryParse(s.text);
          if (g == null) {
            setState(() => _gradeError = 'No se pudo interpretar la corrección. Reintenta o autoevalúate.');
          } else {
            widget.onAnswer(openAnswerFromGrade(q, text, g));
          }
        case AiRunPhase.cancelled:
          setState(() => _gradeError = null);
        default:
          setState(() => _gradeError = s.error ?? 'No se pudo corregir la respuesta.');
      }
    });
    runner.run();
  }

  void _onGrader() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final answered = widget.answer != null;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xl),
            children: [
              Text('Pregunta ${widget.index + 1} de ${widget.total}', style: context.text.labelMedium),
              const SizedBox(height: Insets.xs),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: widget.total == 0 ? 0 : (widget.index + (answered ? 1 : 0)) / widget.total,
                  minHeight: 4,
                  semanticsLabel: 'Progreso del cuestionario',
                ),
              ),
              const SizedBox(height: Insets.lg),
              Semantics(
                header: true,
                child: Text(
                  stripCitations(q.question).trim().isEmpty ? 'Pregunta sin enunciado' : stripCitations(q.question),
                  style: context.text.titleLarge,
                ),
              ),
              const SizedBox(height: Insets.lg),
              if (q.isMcq) ..._mcq(context) else ..._open(context),
              if (answered) ...[
                const SizedBox(height: Insets.lg),
                _Explanation(question: q, citations: widget.content.citations),
              ],
            ],
          ),
        ),
        Material(
          color: c.surface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.sm),
              child: Row(
                children: [
                  if (!answered)
                    TextButton(
                      onPressed: (_grader?.state.isActive ?? false)
                          ? null
                          : () {
                              widget.onAnswer(skippedAnswer(q));
                              widget.onNext();
                            },
                      child: const Text('Saltar'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: answered ? widget.onNext : null,
                    child: Text(widget.isLast ? 'Ver resultado' : 'Siguiente'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _mcq(BuildContext context) {
    final c = context.colors;
    if (!q.isGradable) {
      return [
        const NoticeCard(
          icon: Icons.info_outline_rounded,
          tone: NoticeTone.warning,
          title: 'Pregunta sin respuesta correcta',
          message: 'Edita el cuestionario para marcar la opción correcta. Puedes saltarla.',
        ),
      ];
    }
    final a = widget.answer;
    final chosen = a == null ? null : int.tryParse(a.response);
    return [
      for (var i = 0; i < q.options.length; i++)
        Builder(
          builder: (context) {
            final isCorrect = i == q.answerIndex;
            final isChosen = i == chosen;
            final reveal = a != null;
            final (bg, border, icon, tag) = !reveal
                ? (c.surface, c.separator, null, null)
                : isCorrect
                ? (
                    c.accentSoft,
                    c.accent,
                    Icons.check_circle_rounded,
                    isChosen ? 'Correcta · tu respuesta' : 'Correcta',
                  )
                : isChosen
                ? (c.danger.withValues(alpha: 0.10), c.danger, Icons.cancel_rounded, 'Tu respuesta · incorrecta')
                : (c.surface, c.separator, null, null);
            return Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Semantics(
                inMutuallyExclusiveGroup: true,
                selected: isChosen,
                button: !reveal,
                label: '${optionLetter(i)}. ${q.options[i]}${tag == null ? '' : '. $tag'}',
                excludeSemantics: true,
                child: Material(
                  color: bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Insets.radiusButton),
                    side: BorderSide(color: border, width: reveal && (isCorrect || isChosen) ? 1.5 : 1),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Insets.radiusButton),
                    onTap: reveal ? null : () => widget.onAnswer(gradeMcq(q, i)),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 14,
                              backgroundColor: c.surfaceAlt,
                              child: Text(
                                optionLetter(i),
                                style: context.text.labelMedium?.copyWith(color: c.textPrimary),
                              ),
                            ),
                            const SizedBox(width: Insets.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(stripCitations(q.options[i]), style: context.text.bodyLarge),
                                  if (tag != null) Text(tag, style: context.text.labelSmall),
                                ],
                              ),
                            ),
                            if (icon != null) Icon(icon, color: border),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      if (a != null) Semantics(liveRegion: true, child: _Verdict.of(a).chip(context)),
    ];
  }

  List<Widget> _open(BuildContext context) {
    final c = context.colors;
    final a = widget.answer;
    final grader = _grader;
    final grading = grader?.state.isActive ?? false;
    final status = ref.watch(aiStatusProvider);
    final aiReady = status.whenOrNull(data: availabilityOf) == AiAvailability.ready;
    if (a != null) {
      return [
        Text('Tu respuesta', style: context.text.labelMedium),
        const SizedBox(height: Insets.xs),
        Text(a.response.isEmpty ? 'Sin responder' : a.response, style: context.text.bodyLarge),
        const SizedBox(height: Insets.md),
        Semantics(liveRegion: true, child: _Verdict.of(a).chip(context)),
        if (a.feedback != null && a.feedback!.trim().isNotEmpty && a.feedback != 'Autoevaluada') ...[
          const SizedBox(height: Insets.sm),
          Text(a.feedback!.trim(), style: context.text.bodyMedium),
        ],
        if ((q.referenceAnswer ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: Insets.lg),
          Text('Respuesta de referencia', style: context.text.labelMedium),
          const SizedBox(height: Insets.xs),
          CitedMarkdown(text: q.referenceAnswer!.trim(), citations: widget.content.citations),
        ],
      ];
    }
    return [
      TextField(
        controller: _response,
        enabled: !grading && !_selfAssess,
        minLines: 3,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(hintText: 'Escribe tu respuesta'),
      ),
      const SizedBox(height: Insets.md),
      if (grading) ...[
        Row(
          children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(grader!.state.status ?? 'Corrigiendo…', style: context.text.bodySmall),
              ),
            ),
            TextButton(onPressed: grader.state.cancelRequested ? null : grader.cancel, child: const Text('Cancelar')),
          ],
        ),
        if (partialGradeFeedback(grader.state.text).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: Text(partialGradeFeedback(grader.state.text), style: context.text.bodyMedium),
          ),
      ] else if (_selfAssess) ...[
        if ((q.referenceAnswer ?? '').trim().isNotEmpty) ...[
          Text('Respuesta de referencia', style: context.text.labelMedium),
          const SizedBox(height: Insets.xs),
          CitedMarkdown(text: q.referenceAnswer!.trim(), citations: widget.content.citations),
          const SizedBox(height: Insets.md),
        ],
        Text('¿Cómo te ha ido?', style: context.text.labelMedium),
        const SizedBox(height: Insets.sm),
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: [
            OutlinedButton(
              onPressed: () => widget.onAnswer(selfAssessed(q, _response.text.trim(), 0)),
              child: const Text('No la sabía'),
            ),
            OutlinedButton(
              onPressed: () => widget.onAnswer(selfAssessed(q, _response.text.trim(), 0.5)),
              child: const Text('A medias'),
            ),
            FilledButton(
              onPressed: () => widget.onAnswer(selfAssessed(q, _response.text.trim(), 1)),
              child: const Text('La sabía'),
            ),
          ],
        ),
      ] else ...[
        if (_gradeError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, color: c.danger, size: 20),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(_gradeError!, style: context.text.bodySmall?.copyWith(color: c.danger)),
                ),
              ],
            ),
          ),
        if (aiReady)
          FilledButton.icon(
            onPressed: _response.text.trim().isEmpty ? null : _grade,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(_gradeError == null ? 'Corregir con IA' : 'Reintentar corrección'),
          )
        else
          Text(
            'La corrección con IA necesita un modelo instalado. Puedes autoevaluarte.',
            style: context.text.bodySmall,
          ),
        TextButton(
          onPressed: () => setState(() => _selfAssess = true),
          child: const Text('Ver referencia y autoevaluarme'),
        ),
      ],
    ];
  }
}

class _Explanation extends StatelessWidget {
  const _Explanation({required this.question, required this.citations});
  final QuizQuestion question;
  final List<Citation> citations;

  @override
  Widget build(BuildContext context) {
    final q = question;
    final refs = <int>{
      ...q.citations,
      ...citedNumbers(q.explanation),
    }.where((n) => citations.any((c) => c.n == n)).toList()..sort();
    if (q.explanation.trim().isEmpty && refs.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(color: context.colors.surface, borderRadius: BorderRadius.circular(Insets.radiusGroup)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Explicación', style: context.text.labelMedium),
          if (q.explanation.trim().isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            CitedMarkdown(text: q.explanation.trim(), citations: citations, style: context.text.bodyMedium),
          ],
          if (refs.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            CitationChips(citations: citations, numbers: refs),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────── Resultado ───────────────────────────

class _Results extends StatelessWidget {
  const _Results({
    required this.questions,
    required this.answers,
    required this.score,
    required this.gradable,
    required this.saving,
    required this.saved,
    required this.saveError,
    required this.onRetrySave,
    required this.onRepeat,
    required this.onDone,
  });

  final List<QuizQuestion> questions;
  final Map<String, QuizAnswer> answers;
  final double score;
  final int gradable;
  final bool saving;
  final bool saved;
  final Object? saveError;
  final VoidCallback onRetrySave;
  final VoidCallback onRepeat;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final points = score * gradable;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.lg, Insets.gutter, Insets.xxl),
      children: [
        Container(
          padding: const EdgeInsets.all(Insets.xl),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Insets.radiusSheet)),
          child: Semantics(
            liveRegion: true,
            label: 'Resultado: ${decimalLabel(points)} de $gradable, ${percentLabel(score)}',
            excludeSemantics: true,
            child: Column(
              children: [
                Text('Resultado', style: context.text.labelMedium),
                const SizedBox(height: Insets.sm),
                Text(
                  '${decimalLabel(points)} / $gradable',
                  style: context.text.displaySmall?.copyWith(color: c.accent),
                ),
                Text(percentLabel(score), style: context.text.titleMedium),
              ],
            ),
          ),
        ),
        const SizedBox(height: Insets.md),
        if (saving)
          Text('Guardando intento…', textAlign: TextAlign.center, style: context.text.bodySmall)
        else if (saveError != null)
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: c.danger, size: 20),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text('No se pudo guardar el intento: ${humanError(saveError!)}', style: context.text.bodySmall),
              ),
              TextButton(onPressed: onRetrySave, child: const Text('Reintentar')),
            ],
          )
        else if (saved)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_rounded, size: 18, color: c.accent),
              const SizedBox(width: Insets.xs),
              Text('Intento guardado', style: context.text.bodySmall),
            ],
          ),
        const SizedBox(height: Insets.lg),
        FilledButton.icon(onPressed: onRepeat, icon: const Icon(Icons.replay_rounded), label: const Text('Repetir')),
        const SizedBox(height: Insets.sm),
        OutlinedButton(onPressed: onDone, child: const Text('Volver al cuestionario')),
        const SizedBox(height: Insets.xl),
        Semantics(header: true, child: Text('Tus respuestas', style: context.text.titleMedium)),
        const SizedBox(height: Insets.sm),
        for (final q in questions)
          if (answers[q.id] case final a?) _AnswerReview(question: q, answer: a),
      ],
    );
  }
}

// ─────────────────────────── Editor ───────────────────────────

class _EditableQuestion {
  _EditableQuestion(this.original)
    : kind = original.kind,
      answerIndex = original.answerIndex,
      question = TextEditingController(text: original.question),
      explanation = TextEditingController(text: original.explanation),
      reference = TextEditingController(text: original.referenceAnswer ?? ''),
      options = [
        for (final o in (original.isMcq && original.options.length >= 2 ? original.options : const ['', '']))
          TextEditingController(text: o),
      ];

  final QuizQuestion original;
  QuestionKind kind;
  int? answerIndex;
  final TextEditingController question;
  final TextEditingController explanation;
  final TextEditingController reference;
  final List<TextEditingController> options;

  Iterable<TextEditingController> get controllers => [question, explanation, reference, ...options];

  QuizQuestion build() {
    final isMcq = kind == QuestionKind.mcq;
    return original.copyWith(
      kind: kind,
      question: question.text.trim(),
      options: isMcq ? [for (final o in options) o.text.trim()] : const [],
      answerIndex: isMcq ? answerIndex : null,
      clearAnswerIndex: !isMcq,
      referenceAnswer: isMcq || reference.text.trim().isEmpty ? null : reference.text.trim(),
      explanation: explanation.text.trim(),
    );
  }

  /// Mensaje de validación o null si es válida.
  String? validate(int number) {
    if (question.text.trim().isEmpty) return 'La pregunta $number no tiene enunciado';
    if (kind == QuestionKind.mcq) {
      if (options.length < 2 || options.any((o) => o.text.trim().isEmpty)) {
        return 'Completa todas las opciones de la pregunta $number';
      }
      if (answerIndex == null || answerIndex! >= options.length) {
        return 'Marca la opción correcta de la pregunta $number';
      }
    } else if (reference.text.trim().isEmpty) {
      return 'Escribe la respuesta de referencia de la pregunta $number';
    }
    return null;
  }

  void dispose() {
    for (final c in controllers) {
      c.dispose();
    }
  }
}

/// Editor de preguntas: editar, añadir y borrar; guarda con `update_study_item`.
class QuizEditor extends ConsumerStatefulWidget {
  const QuizEditor({super.key, required this.item, required this.content});

  final StudyItem item;
  final QuizContent content;

  @override
  ConsumerState<QuizEditor> createState() => _QuizEditorState();
}

class _QuizEditorState extends ConsumerState<QuizEditor> {
  late final _title = TextEditingController(text: widget.item.title);
  late final List<_EditableQuestion> _qs = [for (final q in widget.content.questions) _EditableQuestion(q)];
  late final String _originalJson = jsonEncode([for (final q in widget.content.questions) q.toJson()]);
  final _scroll = ScrollController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    for (final q in _qs) {
      _listen(q);
    }
  }

  void _listen(_EditableQuestion q) {
    for (final c in q.controllers) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  bool get _dirty =>
      _title.text != widget.item.title || jsonEncode([for (final q in _qs) q.build().toJson()]) != _originalJson;

  @override
  void dispose() {
    _title.dispose();
    for (final q in _qs) {
      q.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final kind = await showModalBottomSheet<QuestionKind>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.radio_button_checked_rounded),
              title: const Text('Opción múltiple'),
              onTap: () => Navigator.pop(sheet, QuestionKind.mcq),
            ),
            ListTile(
              leading: const Icon(Icons.short_text_rounded),
              title: const Text('Respuesta abierta'),
              onTap: () => Navigator.pop(sheet, QuestionKind.open),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    final q = _EditableQuestion(QuizQuestion.create(kind));
    _listen(q);
    setState(() => _qs.add(q));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: Motion.of(context), curve: Motion.curve);
      }
    });
  }

  Future<void> _remove(int i) async {
    final ok = await confirmAction(
      context,
      title: '¿Borrar la pregunta ${i + 1}?',
      confirmLabel: 'Borrar',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final q = _qs.removeAt(i);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => q.dispose());
  }

  void _setKind(_EditableQuestion q, QuestionKind kind) {
    setState(() {
      q.kind = kind;
      if (kind == QuestionKind.mcq) {
        while (q.options.length < 2) {
          final c = TextEditingController()..addListener(_changed);
          q.options.add(c);
        }
        q.answerIndex ??= 0;
      }
    });
  }

  void _addOption(_EditableQuestion q) {
    if (q.options.length >= 6) return;
    setState(() => q.options.add(TextEditingController()..addListener(_changed)));
  }

  void _removeOption(_EditableQuestion q, int i) {
    if (q.options.length <= 2) return;
    setState(() {
      final c = q.options.removeAt(i);
      WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
      final a = q.answerIndex;
      if (a != null) {
        if (a == i) {
          q.answerIndex = null;
        } else if (a > i) {
          q.answerIndex = a - 1;
        }
      }
    });
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showValidation(context, 'Escribe un título');
      return;
    }
    for (var i = 0; i < _qs.length; i++) {
      final err = _qs[i].validate(i + 1);
      if (err != null) {
        showValidation(context, err);
        return;
      }
    }
    setState(() => _saving = true);
    final ok = await saveStudyItem(
      context,
      ref,
      id: widget.item.id,
      title: _title.text,
      content: widget.content.copyWith(questions: [for (final q in _qs) q.build()]),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return EditorScaffold(
      title: 'Editar preguntas',
      dirty: _dirty,
      saving: _saving,
      onSave: _dirty ? _save : null,
      bottom: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.sm),
          child: OutlinedButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Añadir pregunta'),
          ),
        ),
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xxl),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Título del cuestionario'),
          ),
          const SizedBox(height: Insets.lg),
          if (_qs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xl),
              child: Text(
                'Sin preguntas. Usa «Añadir pregunta».',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium,
              ),
            ),
          for (var i = 0; i < _qs.length; i++)
            Container(
              key: ObjectKey(_qs[i]),
              margin: const EdgeInsets.only(bottom: Insets.md),
              padding: const EdgeInsets.fromLTRB(Insets.md, Insets.xs, Insets.md, Insets.md),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Insets.radiusGroup)),
              child: _questionEditor(context, _qs[i], i),
            ),
        ],
      ),
    );
  }

  Widget _questionEditor(BuildContext context, _EditableQuestion q, int i) {
    final c = context.colors;
    final isMcq = q.kind == QuestionKind.mcq;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Pregunta ${i + 1}', style: context.text.labelMedium)),
            IconButton(
              tooltip: 'Borrar pregunta ${i + 1}',
              icon: Icon(Icons.delete_outline_rounded, color: c.danger),
              onPressed: () => _remove(i),
            ),
          ],
        ),
        SegmentedButton<QuestionKind>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: QuestionKind.mcq, label: Text('Opción múltiple')),
            ButtonSegment(value: QuestionKind.open, label: Text('Abierta')),
          ],
          selected: {q.kind},
          onSelectionChanged: (s) => _setKind(q, s.first),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: q.question,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Enunciado'),
        ),
        const SizedBox(height: Insets.md),
        if (isMcq) ...[
          Text('Opciones (marca la correcta)', style: context.text.labelMedium),
          const SizedBox(height: Insets.xs),
          for (var o = 0; o < q.options.length; o++)
            Padding(
              key: ObjectKey(q.options[o]),
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Row(
                children: [
                  Semantics(
                    inMutuallyExclusiveGroup: true,
                    selected: q.answerIndex == o,
                    child: IconButton(
                      tooltip: q.answerIndex == o
                          ? 'Opción ${optionLetter(o)}: correcta'
                          : 'Marcar la opción ${optionLetter(o)} como correcta',
                      onPressed: () => setState(() => q.answerIndex = o),
                      icon: Icon(
                        q.answerIndex == o ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        color: q.answerIndex == o ? c.accent : c.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: q.options[o],
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(hintText: 'Opción ${optionLetter(o)}'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Quitar la opción ${optionLetter(o)}',
                    onPressed: q.options.length > 2 ? () => _removeOption(q, o) : null,
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                ],
              ),
            ),
          if (q.options.length < 6)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => _addOption(q),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Añadir opción'),
              ),
            ),
        ] else
          TextField(
            controller: q.reference,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Respuesta de referencia',
              helperText: 'La IA la usa para corregir tus respuestas.',
            ),
          ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: q.explanation,
          minLines: 1,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Explicación (opcional)'),
        ),
      ],
    );
  }
}
