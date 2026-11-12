import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import 'ai_availability.dart';
import 'ai_gateway.dart';
import 'ai_run.dart';
import 'ai_scope.dart';
import 'citation_widgets.dart';
import 'citations.dart';

/// Mensaje mostrado en la conversación.
@immutable
class ChatEntry {
  const ChatEntry({
    this.id,
    required this.role,
    required this.text,
    this.citations = const [],
    this.insufficient = false,
    this.status = 'done',
    this.error,
    this.question,
  });

  factory ChatEntry.fromMessage(ChatMessage m, {String? question}) => ChatEntry(
    id: m.id,
    role: m.role,
    text: m.content,
    citations: m.citations,
    insufficient: m.insufficient,
    status: m.status,
    question: question,
  );

  final String? id;
  final ChatRole role;
  final String text;
  final List<Citation> citations;
  final bool insufficient;

  /// 'done' | 'cancelled' | 'error'.
  final String status;
  final String? error;

  /// Pregunta que originó esta respuesta (para «Reintentar»).
  final String? question;

  bool get isUser => role == ChatRole.user;
  bool get canRetry => !isUser && status != 'done' && question != null;
}

/// Convierte los mensajes guardados en entradas, enlazando cada respuesta con su pregunta.
List<ChatEntry> entriesFromThread(ChatThread thread) {
  final out = <ChatEntry>[];
  String? lastQuestion;
  for (final m in thread.messages) {
    if (m.role == ChatRole.user) {
      lastQuestion = m.content;
      out.add(ChatEntry.fromMessage(m));
    } else {
      out.add(ChatEntry.fromMessage(m, question: lastQuestion));
    }
  }
  return out;
}

/// Conversación con las notas: preguntas, respuestas en streaming y referencias [n].
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, this.threadId, this.scope, this.initialQuestion});

  /// Hilo existente, o null para empezar uno nuevo.
  final String? threadId;

  /// Ámbito de un hilo nuevo (por defecto, toda la biblioteca).
  final AiScope? scope;

  /// Pregunta que se envía automáticamente al abrir un hilo nuevo.
  final String? initialQuestion;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  String? _threadId;
  AiScope? _scope;
  String? _title;
  String? _scopeLabel;
  bool _loading = false;
  Object? _loadError;
  final List<ChatEntry> _entries = [];
  AiRunner? _runner;
  String? _runningQuestion;
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _threadId = widget.threadId;
    if (_threadId != null) {
      _load();
    } else {
      _scope = widget.scope ?? Scopes.library;
      final q = widget.initialQuestion?.trim();
      if (q != null && q.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _send(q);
        });
      }
    }
  }

  @override
  void dispose() {
    _runner?.removeListener(_onRunnerChanged);
    _runner?.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  AiGateway get _gw => ref.read(aiGatewayProvider);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final t = await _gw.getThread(_threadId!);
      if (!mounted) return;
      setState(() {
        _applyThread(t);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  void _applyThread(ChatThread t) {
    _scope = t.scope;
    _title = t.title;
    _scopeLabel = t.scopeLabel;
    _entries
      ..clear()
      ..addAll(entriesFromThread(t));
  }

  /// Relee el hilo tras una respuesta (título, ids y estado definitivos guardados por Rust).
  Future<void> _refreshQuietly() async {
    final id = _threadId;
    if (id == null) return;
    try {
      final t = await _gw.getThread(id);
      if (!mounted || (_runner?.state.isActive ?? false)) return;
      setState(() => _applyThread(t));
    } catch (_) {
      // Se mantiene lo mostrado: la respuesta ya está en pantalla.
    }
  }

  void _send(String raw) {
    final q = raw.trim();
    final scope = _scope;
    if (q.isEmpty || scope == null || (_runner?.state.isActive ?? false)) return;
    final gw = _gw;
    final threadId = _threadId;
    final runner = AiRunner(
      start: () => gw.ask(scope: scope, question: q, threadId: threadId),
      cancelTask: gw.cancelTask,
    );
    setState(() {
      _entries.add(ChatEntry(role: ChatRole.user, text: q));
      _input.clear();
      _runner = runner;
      _runningQuestion = q;
    });
    runner.addListener(_onRunnerChanged);
    runner.finished.then((s) => _onFinished(runner, s));
    runner.run();
  }

  void _onRunnerChanged() {
    final s = _runner?.state;
    if (s == null || !mounted) return;
    if (_threadId == null && s.threadId != null) {
      _threadId = s.threadId;
      ref.read(threadsRevisionProvider.notifier).bump();
    }
    setState(() {});
  }

  void _onFinished(AiRunner runner, AiRunState s) {
    if (!mounted || !identical(runner, _runner)) return;
    runner.removeListener(_onRunnerChanged);
    if (_threadId == null && s.threadId != null) _threadId = s.threadId;
    final entry = switch (s.phase) {
      AiRunPhase.done => ChatEntry(
        id: s.resultId,
        role: ChatRole.assistant,
        text: s.text,
        citations: s.citations,
        insufficient: s.insufficient,
        question: _runningQuestion,
      ),
      AiRunPhase.cancelled => ChatEntry(
        role: ChatRole.assistant,
        text: s.text,
        citations: s.citations,
        status: 'cancelled',
        question: _runningQuestion,
      ),
      _ => ChatEntry(
        role: ChatRole.assistant,
        text: s.text,
        citations: s.citations,
        status: 'error',
        error: s.error,
        question: _runningQuestion,
      ),
    };
    setState(() {
      _entries.add(entry);
      _runner = null;
      _runningQuestion = null;
    });
    // Se libera fuera de la notificación en curso.
    scheduleMicrotask(runner.dispose);
    ref.read(threadsRevisionProvider.notifier).bump();
    if (s.phase == AiRunPhase.done) _refreshQuietly();
  }

  /// Vuelve a preguntar lo mismo; la respuesta fallida y su pregunta se sustituyen en pantalla.
  void _retry(ChatEntry e) {
    final q = e.question;
    if (q == null) return;
    setState(() {
      final i = _entries.indexOf(e);
      if (i < 0) return;
      _entries.removeAt(i);
      if (i > 0 && _entries[i - 1].isUser && _entries[i - 1].text == q) _entries.removeAt(i - 1);
    });
    _send(q);
  }

  Future<void> _rename() async {
    final id = _threadId;
    if (id == null) return;
    final title = await promptText(
      context,
      title: 'Renombrar conversación',
      initial: _title ?? '',
      confirmLabel: 'Guardar',
    );
    if (title == null) return;
    try {
      await _gw.renameThread(id, title);
      if (!mounted) return;
      setState(() => _title = title);
      ref.read(threadsRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showErrorSnack(context, e, prefix: 'No se pudo renombrar');
    }
  }

  Future<void> _delete() async {
    final id = _threadId;
    if (id == null) return;
    final ok = await confirmAction(
      context,
      title: '¿Borrar esta conversación?',
      message: 'Se eliminarán todos sus mensajes. Tus notas no se modifican.',
      confirmLabel: 'Borrar',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      _runner?.cancel();
      await _gw.deleteThread(id);
      if (!mounted) return;
      ref.read(threadsRevisionProvider.notifier).bump();
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/study');
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e, prefix: 'No se pudo borrar');
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _runner?.state.isActive ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (_title?.trim().isNotEmpty ?? false) ? _title!.trim() : 'Nueva conversación',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_threadId != null)
            PopupMenuButton<String>(
              tooltip: 'Más opciones',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) => switch (v) {
                'rename' => _rename(),
                'delete' => _delete(),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Renombrar')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: !running,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline_rounded, color: context.colors.danger),
                    title: Text('Borrar conversación', style: TextStyle(color: context.colors.danger)),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const _ChatSkeleton();
    if (_loadError != null) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'No se pudo abrir la conversación',
        message: humanError(_loadError!),
        actionLabel: 'Reintentar',
        onAction: _load,
      );
    }
    final scope = _scope!;
    final runner = _runner;
    final live = runner?.state;
    final running = live?.isActive ?? false;
    final itemCount = _entries.length + (live != null ? 1 : 0);
    return Column(
      children: [
        _ScopeHeader(scope: scope, fallbackLabel: _scopeLabel),
        Expanded(
          child: itemCount == 0
              ? _EmptyChat(onSuggestion: _send, scope: scope)
              : ListView.builder(
                  reverse: true,
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, Insets.md),
                  itemCount: itemCount,
                  itemBuilder: (context, i) {
                    if (live != null && i == 0) return _LiveBubble(state: live);
                    final idx = _entries.length - 1 - (live != null ? i - 1 : i);
                    final e = _entries[idx];
                    return e.isUser
                        ? _UserBubble(entry: e)
                        : _AssistantBubble(entry: e, onRetry: running ? null : () => _retry(e));
                  },
                ),
        ),
        _Composer(
          controller: _input,
          focusNode: _focus,
          running: running,
          cancelling: live?.cancelRequested ?? false,
          onSend: () => _send(_input.text),
          onCancel: () => _runner?.cancel(),
        ),
      ],
    );
  }
}

class _ScopeHeader extends ConsumerWidget {
  const _ScopeHeader({required this.scope, this.fallbackLabel});

  final AiScope scope;
  final String? fallbackLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final summary = ref.watch(scopeSummaryProvider(ScopeRef(scope)));
    final s = summary.value;
    final line = s != null ? scopeSummaryLine(s) : (fallbackLabel ?? fallbackScopeLabel(scope));
    final warning = s == null ? null : pendingIndexWarning(s);
    return Material(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: 'Ámbito de la conversación: $line',
              excludeSemantics: true,
              child: Row(
                children: [
                  Icon(scopeIcon(scope.kind), size: 18, color: c.accent),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(line, style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            if (warning != null)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.hourglass_top_rounded, size: 16, color: c.textSecondary),
                    const SizedBox(width: Insets.sm),
                    Expanded(child: Text(warning, style: context.text.bodySmall)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onSuggestion, required this.scope});

  final ValueChanged<String> onSuggestion;
  final AiScope scope;

  static const suggestions = [
    'Resume las ideas principales',
    '¿Qué conceptos debería repasar?',
    'Explícame el tema más importante',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyState(
              icon: Icons.forum_outlined,
              title: 'Pregunta sobre tus notas',
              message: 'Las respuestas se basan solo en tus fuentes e incluyen referencias [n] para comprobarlas.',
              compact: true,
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Insets.sm,
              children: [for (final s in suggestions) ActionChip(label: Text(s), onPressed: () => onSuggestion(s))],
            ),
          ],
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.entry});
  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: Container(
          margin: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
          padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm + 2),
          decoration: BoxDecoration(
            color: c.accentSoft,
            borderRadius: BorderRadius.circular(16).copyWith(bottomRight: const Radius.circular(4)),
          ),
          child: Semantics(
            label: 'Tu pregunta',
            child: SelectableText(entry.text, style: context.text.bodyLarge),
          ),
        ),
      ),
    );
  }
}

/// Aviso destacado de evidencia insuficiente.
class InsufficientNotice extends StatelessWidget {
  const InsufficientNotice({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: Insets.sm),
    child: NoticeCard(
      icon: Icons.info_outline_rounded,
      tone: NoticeTone.warning,
      title: 'Tus notas no tienen información suficiente',
      message: 'La respuesta no se puede respaldar con tus fuentes. Prueba con otro ámbito o añade más notas.',
    ),
  );
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.entry, required this.onRetry});

  final ChatEntry entry;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cited = citedNumbers(entry.text).where((n) => entry.citations.any((x) => x.n == n)).toList();
    final hasText = entry.text.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry.insufficient) const InsufficientNotice(),
          if (hasText) CitedMarkdown(text: entry.text, citations: entry.citations, selectable: true),
          if (cited.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            Text('Fuentes', style: context.text.labelSmall),
            CitationChips(citations: entry.citations, numbers: cited),
          ],
          if (entry.status == 'cancelled')
            _StatusRow(icon: Icons.stop_circle_outlined, text: 'Respuesta cancelada', color: c.textSecondary),
          if (entry.status == 'error')
            _StatusRow(
              icon: Icons.error_outline_rounded,
              text: entry.error ?? 'No se pudo completar la respuesta.',
              color: c.danger,
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (entry.canRetry)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reintentar'),
                ),
              if (hasText)
                IconButton(
                  tooltip: 'Copiar respuesta',
                  icon: Icon(Icons.copy_rounded, size: 20, color: c.textSecondary),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: entry.text));
                    showInfoSnack(context, 'Respuesta copiada');
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Insets.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(text, style: context.text.bodySmall?.copyWith(color: color)),
        ),
      ],
    ),
  );
}

/// Respuesta en curso: estado (Progress), fuentes y texto en streaming.
class _LiveBubble extends StatelessWidget {
  const _LiveBubble({required this.state});
  final AiRunState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final status = state.cancelRequested ? 'Cancelando…' : (state.status ?? (state.text.isEmpty ? 'Pensando…' : null));
    return Container(
      margin: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.insufficient) const InsufficientNotice(),
          if (status != null)
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, value: state.progress),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(child: Text(status, style: context.text.bodySmall)),
                ],
              ),
            ),
          if (state.citations.isNotEmpty && state.text.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                'Consultando ${state.citations.length == 1 ? '1 fragmento' : '${state.citations.length} fragmentos'}',
                style: context.text.bodySmall,
              ),
            ),
          if (state.text.isNotEmpty) ...[
            if (status != null) const SizedBox(height: Insets.sm),
            CitedMarkdown(text: state.text, citations: state.citations),
          ],
        ],
      ),
    );
  }
}

class _Composer extends ConsumerWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.running,
    required this.cancelling,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool running;
  final bool cancelling;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final status = ref.watch(aiStatusProvider);
    final availability = status.whenOrNull(data: availabilityOf);
    if (availability != null && availability != AiAvailability.ready) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Insets.gutter),
          child: availability == AiAvailability.modelMissing
              ? ModelMissingCard(onOpenModels: () => context.push('/settings/models'))
              : DeviceUnsupportedCard(
                  reason: status.value?.unavailableReason,
                  onOpenModels: () => context.push('/settings/models'),
                ),
        ),
      );
    }
    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.sm, Insets.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (!running) onSend();
                  },
                  decoration: const InputDecoration(hintText: 'Escribe una pregunta…'),
                ),
              ),
              const SizedBox(width: Insets.xs),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) => running
                    ? IconButton.filled(
                        tooltip: cancelling ? 'Cancelando' : 'Detener respuesta',
                        onPressed: cancelling ? null : onCancel,
                        icon: const Icon(Icons.stop_rounded),
                      )
                    : IconButton.filled(
                        tooltip: 'Enviar pregunta',
                        onPressed: value.text.trim().isEmpty ? null : onSend,
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatSkeleton extends StatelessWidget {
  const _ChatSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget bubble(double widthFactor, double height, {bool end = false}) => Align(
      alignment: end ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: height,
          margin: const EdgeInsets.only(top: Insets.md),
          decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
    return Semantics(
      label: 'Cargando conversación',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(Insets.gutter),
          child: Column(
            children: [bubble(0.6, 44, end: true), bubble(0.9, 120), bubble(0.5, 44, end: true), bubble(0.85, 90)],
          ),
        ),
      ),
    );
  }
}
