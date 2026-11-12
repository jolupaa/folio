import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../ai/citation_widgets.dart';
import '../ai/citations.dart';
import 'study_common.dart';
import 'study_models.dart';

/// Sesión de repaso de un mazo: orden, posición, cara visible y valoración de cada tarjeta.
class FlashcardSession {
  FlashcardSession(int count, {List<int>? order}) : order = order ?? List.generate(count, (i) => i);

  /// Índices de tarjetas en el orden de la sesión.
  final List<int> order;
  int position = 0;
  bool flipped = false;

  /// Índice de tarjeta → true «Lo sé», false «Repasar».
  final Map<int, bool> marks = {};

  bool get isEmpty => order.isEmpty;
  bool get finished => order.isNotEmpty && position >= order.length;
  int get current => order[position.clamp(0, order.length - 1)];
  int get known => marks.values.where((v) => v).length;
  int get toReview => marks.values.where((v) => !v).length;
  List<int> get reviewCards => [
    for (final i in order)
      if (marks[i] == false) i,
  ];

  bool get canGoBack => position > 0;

  void flip() => flipped = !flipped;

  void next() {
    if (position < order.length) position++;
    flipped = false;
  }

  void previous() {
    if (position > 0) position--;
    flipped = false;
  }

  void mark(bool knewIt) {
    if (finished) return;
    marks[current] = knewIt;
    next();
  }
}

/// Mazo de flashcards con volteo animado y valoración «Lo sé»/«Repasar».
class FlashcardsView extends StatefulWidget {
  const FlashcardsView({super.key, required this.item, required this.content, required this.onEdit});

  final StudyItem item;
  final FlashcardsContent content;
  final VoidCallback onEdit;

  @override
  State<FlashcardsView> createState() => _FlashcardsViewState();
}

class _FlashcardsViewState extends State<FlashcardsView> {
  late FlashcardSession _session = FlashcardSession(widget.content.cards.length);

  @override
  void didUpdateWidget(covariant FlashcardsView old) {
    super.didUpdateWidget(old);
    if (old.content.cards.length != widget.content.cards.length || !_sameIds(old.content.cards, widget.content.cards)) {
      _session = FlashcardSession(widget.content.cards.length);
    }
  }

  bool _sameIds(List<Flashcard> a, List<Flashcard> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _restart({bool shuffle = false, List<int>? only}) {
    final order = only ?? List.generate(widget.content.cards.length, (i) => i);
    if (shuffle) order.shuffle();
    setState(() => _session = FlashcardSession(order.length, order: order));
  }

  void _flip() {
    HapticFeedback.selectionClick();
    setState(_session.flip);
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.content.cards;
    if (cards.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: EmptyState(
              icon: Icons.style_outlined,
              title: 'Este mazo no tiene tarjetas',
              message: 'Añade tarjetas a mano o crea un mazo nuevo con el asistente.',
              actionLabel: 'Añadir tarjetas',
              onAction: widget.onEdit,
            ),
          ),
        ],
      );
    }
    final s = _session;
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - Insets.xl - Insets.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StudyMetaLine(item: widget.item),
                const SizedBox(height: Insets.md),
                _ProgressHeader(session: s, total: s.order.length, onShuffle: () => _restart(shuffle: true)),
                const SizedBox(height: Insets.md),
                if (s.finished)
                  _SessionSummary(
                    session: s,
                    onReview: s.toReview > 0 ? () => _restart(only: s.reviewCards) : null,
                    onRestart: () => _restart(),
                    onShuffle: () => _restart(shuffle: true),
                  )
                else ...[
                  SizedBox(
                    height: math.max(280, math.min(440, constraints.maxHeight * 0.5)),
                    child: _CardFace(
                      card: cards[s.current],
                      number: s.position + 1,
                      total: s.order.length,
                      flipped: s.flipped,
                      citations: widget.content.citations,
                      onFlip: _flip,
                      onSwipeNext: () => setState(s.next),
                      onSwipePrevious: s.canGoBack ? () => setState(s.previous) : null,
                    ),
                  ),
                  const SizedBox(height: Insets.lg),
                  _Controls(
                    session: s,
                    onFlip: _flip,
                    onPrevious: s.canGoBack ? () => setState(s.previous) : null,
                    onNext: () => setState(s.next),
                    onMark: (v) => setState(() => s.mark(v)),
                  ),
                ],
                SourcesSection(sources: widget.item.sources),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.session, required this.total, required this.onShuffle});
  final FlashcardSession session;
  final int total;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final pos = s.finished ? total : s.position + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(s.finished ? 'Sesión terminada' : 'Tarjeta $pos de $total', style: context.text.titleSmall),
            ),
            Text('Lo sé ${s.known} · Repasar ${s.toReview}', style: context.text.bodySmall),
            IconButton(tooltip: 'Barajar y empezar', icon: const Icon(Icons.shuffle_rounded), onPressed: onShuffle),
          ],
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : (s.finished ? 1 : s.position / total),
            minHeight: 4,
            semanticsLabel: 'Progreso del mazo',
          ),
        ),
      ],
    );
  }
}

/// Tarjeta con volteo 3D. Toca para girar; desliza para cambiar de tarjeta.
class _CardFace extends StatelessWidget {
  const _CardFace({
    required this.card,
    required this.number,
    required this.total,
    required this.flipped,
    required this.citations,
    required this.onFlip,
    required this.onSwipeNext,
    required this.onSwipePrevious,
  });

  final Flashcard card;
  final int number;
  final int total;
  final bool flipped;
  final List<Citation> citations;
  final VoidCallback onFlip;
  final VoidCallback onSwipeNext;
  final VoidCallback? onSwipePrevious;

  @override
  Widget build(BuildContext context) {
    final duration = Motion.of(context, const Duration(milliseconds: 300));
    final refs = <int>{
      ...card.citations,
      ...citedNumbers(card.back),
      ...citedNumbers(card.front),
    }.where((n) => citations.any((c) => c.n == n)).toList()..sort();
    return Semantics(
      key: ValueKey('card-${card.id}'),
      container: true,
      button: true,
      label: 'Tarjeta $number de $total, ${flipped ? 'reverso (respuesta)' : 'anverso (pregunta)'}',
      hint: flipped ? 'Toca para volver a la pregunta' : 'Toca para ver la respuesta',
      onTap: onFlip,
      child: GestureDetector(
        onTap: onFlip,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -250) onSwipeNext();
          if (v > 250) onSwipePrevious?.call();
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: flipped ? 1 : 0),
          duration: duration,
          curve: Motion.curve,
          builder: (context, t, _) {
            final showBack = t >= 0.5;
            final transform = Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..multiply(Matrix4.rotationY(t * math.pi));
            return Transform(
              alignment: Alignment.center,
              transform: transform,
              child: showBack
                  ? Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.rotationY(math.pi),
                      child: _side(context, back: true, refs: refs),
                    )
                  : _side(context, back: false, refs: const []),
            );
          },
        ),
      ),
    );
  }

  Widget _side(BuildContext context, {required bool back, required List<int> refs}) {
    final c = context.colors;
    final text = stripCitations(back ? card.back : card.front).trim();
    return Container(
      decoration: BoxDecoration(
        color: back ? c.surface : c.accentSoft,
        borderRadius: BorderRadius.circular(Insets.radiusSheet),
        border: Border.all(color: back ? c.separator : c.accent.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.all(Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(back ? 'Respuesta' : 'Pregunta', style: context.text.labelSmall),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Text(
                  text.isEmpty ? (back ? 'Sin respuesta' : 'Sin pregunta') : text,
                  textAlign: TextAlign.center,
                  style: (back ? context.text.bodyLarge : context.text.titleLarge)?.copyWith(
                    color: text.isEmpty ? c.textTertiary : null,
                  ),
                ),
              ),
            ),
          ),
          if (back && refs.isNotEmpty) CitationChips(citations: citations, numbers: refs),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.session,
    required this.onFlip,
    required this.onPrevious,
    required this.onNext,
    required this.onMark,
  });

  final FlashcardSession session;
  final VoidCallback onFlip;
  final VoidCallback? onPrevious;
  final VoidCallback onNext;
  final ValueChanged<bool> onMark;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return Row(
      children: [
        IconButton(tooltip: 'Anterior', onPressed: onPrevious, icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(
          child: s.flipped
              ? Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => onMark(false),
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('Repasar'),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => onMark(true),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Lo sé'),
                      ),
                    ),
                  ],
                )
              : FilledButton.tonalIcon(
                  onPressed: onFlip,
                  icon: const Icon(Icons.flip_rounded),
                  label: const Text('Ver respuesta'),
                ),
        ),
        IconButton(tooltip: 'Siguiente', onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded)),
      ],
    );
  }
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary({
    required this.session,
    required this.onReview,
    required this.onRestart,
    required this.onShuffle,
  });

  final FlashcardSession session;
  final VoidCallback? onReview;
  final VoidCallback onRestart;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final unrated = s.order.length - s.marks.length;
    return Container(
      padding: const EdgeInsets.all(Insets.xl),
      decoration: BoxDecoration(color: context.colors.surface, borderRadius: BorderRadius.circular(Insets.radiusSheet)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.emoji_events_outlined, size: 40, color: context.colors.accent),
          const SizedBox(height: Insets.md),
          Semantics(
            liveRegion: true,
            child: Text('¡Mazo completado!', textAlign: TextAlign.center, style: context.text.titleLarge),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            ['Lo sé: ${s.known}', 'Por repasar: ${s.toReview}', if (unrated > 0) 'Sin valorar: $unrated'].join(' · '),
            textAlign: TextAlign.center,
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          if (onReview != null)
            FilledButton.icon(
              onPressed: onReview,
              icon: const Icon(Icons.replay_rounded),
              label: Text('Repasar ${s.toReview == 1 ? '1 tarjeta' : '${s.toReview} tarjetas'}'),
            ),
          const SizedBox(height: Insets.sm),
          OutlinedButton(onPressed: onRestart, child: const Text('Empezar de nuevo')),
          TextButton.icon(onPressed: onShuffle, icon: const Icon(Icons.shuffle_rounded), label: const Text('Barajar')),
        ],
      ),
    );
  }
}

// ─────────────────────────── Editor ───────────────────────────

/// Editor de tarjetas: editar, añadir y borrar; guarda con `update_study_item`.
class FlashcardsEditor extends ConsumerStatefulWidget {
  const FlashcardsEditor({super.key, required this.item, required this.content});

  final StudyItem item;
  final FlashcardsContent content;

  @override
  ConsumerState<FlashcardsEditor> createState() => _FlashcardsEditorState();
}

class _EditableCard {
  _EditableCard(this.original)
    : front = TextEditingController(text: original.front),
      back = TextEditingController(text: original.back);

  final Flashcard original;
  final TextEditingController front;
  final TextEditingController back;

  Flashcard build() => original.copyWith(front: front.text.trim(), back: back.text.trim());

  bool get isBlank => front.text.trim().isEmpty && back.text.trim().isEmpty;
  bool get isIncomplete => !isBlank && (front.text.trim().isEmpty || back.text.trim().isEmpty);

  void dispose() {
    front.dispose();
    back.dispose();
  }
}

class _FlashcardsEditorState extends ConsumerState<FlashcardsEditor> {
  late final _title = TextEditingController(text: widget.item.title);
  late final List<_EditableCard> _cards = [for (final c in widget.content.cards) _EditableCard(c)];
  final _scroll = ScrollController();
  bool _saving = false;
  bool _structureChanged = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    for (final c in _cards) {
      _listen(c);
    }
  }

  void _listen(_EditableCard c) {
    c.front.addListener(_changed);
    c.back.addListener(_changed);
  }

  void _changed() => setState(() {});

  bool get _dirty =>
      _structureChanged ||
      _title.text != widget.item.title ||
      _cards.any((c) => c.front.text != c.original.front || c.back.text != c.original.back);

  @override
  void dispose() {
    _title.dispose();
    for (final c in _cards) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _add() {
    final c = _EditableCard(Flashcard.create());
    _listen(c);
    setState(() {
      _cards.add(c);
      _structureChanged = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: Motion.of(context), curve: Motion.curve);
      }
    });
  }

  Future<void> _remove(int i) async {
    final c = _cards[i];
    if (!c.isBlank) {
      final ok = await confirmAction(
        context,
        title: '¿Borrar esta tarjeta?',
        confirmLabel: 'Borrar',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _cards.removeAt(i);
      _structureChanged = true;
    });
    c.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showValidation(context, 'Escribe un título');
      return;
    }
    if (_cards.any((c) => c.isIncomplete)) {
      showValidation(context, 'Completa la pregunta y la respuesta de todas las tarjetas');
      return;
    }
    final cards = [
      for (final c in _cards)
        if (!c.isBlank) c.build(),
    ];
    setState(() => _saving = true);
    final ok = await saveStudyItem(
      context,
      ref,
      id: widget.item.id,
      title: _title.text,
      content: widget.content.copyWith(cards: cards),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return EditorScaffold(
      title: 'Editar tarjetas',
      dirty: _dirty,
      saving: _saving,
      onSave: _dirty ? _save : null,
      bottom: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.sm),
          child: OutlinedButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Añadir tarjeta'),
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
            decoration: const InputDecoration(labelText: 'Título del mazo'),
          ),
          const SizedBox(height: Insets.lg),
          if (_cards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xl),
              child: Text(
                'Sin tarjetas. Usa «Añadir tarjeta».',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium,
              ),
            ),
          for (var i = 0; i < _cards.length; i++)
            Container(
              key: ObjectKey(_cards[i]),
              margin: const EdgeInsets.only(bottom: Insets.md),
              padding: const EdgeInsets.fromLTRB(Insets.md, Insets.xs, Insets.xs, Insets.md),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Insets.radiusGroup)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Tarjeta ${i + 1}', style: context.text.labelMedium)),
                      IconButton(
                        tooltip: 'Borrar tarjeta ${i + 1}',
                        icon: Icon(Icons.delete_outline_rounded, color: c.danger),
                        onPressed: () => _remove(i),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: Insets.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _cards[i].front,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(labelText: 'Pregunta (anverso)'),
                        ),
                        const SizedBox(height: Insets.sm),
                        TextField(
                          controller: _cards[i].back,
                          minLines: 2,
                          maxLines: 8,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(labelText: 'Respuesta (reverso)'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
