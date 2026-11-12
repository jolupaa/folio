import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/grouped_section.dart';
import '../ai/ai_entry.dart';
import '../ai/ai_gateway.dart';
import '../ai/skeleton.dart';
import 'study_gateway.dart';
import 'study_labels.dart';

/// Materiales de estudio agrupados por tipo y conversaciones con la IA.
class StudyListScreen extends ConsumerWidget {
  const StudyListScreen({super.key});

  static const kindOrder = [
    StudyKind.summary,
    StudyKind.outline,
    StudyKind.keyConcepts,
    StudyKind.flashcards,
    StudyKind.quiz,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(studyItemsProvider);
    final threads = ref.watch(threadsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Estudio'),
        actions: [
          IconButton(
            tooltip: 'Crear material con IA',
            icon: const Icon(Icons.auto_awesome_rounded),
            onPressed: () => showAiActions(context, scope: Scopes.library),
          ),
        ],
      ),
      body: _body(context, ref, items, threads),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<StudyItemSummary>> items,
    AsyncValue<List<ChatThreadSummary>> threads,
  ) {
    if (items.isLoading && !items.hasValue) return const SkeletonList(label: 'Cargando materiales');
    if (items.hasError && !items.hasValue) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'No se pudieron cargar los materiales',
        message: humanError(items.error!),
        actionLabel: 'Reintentar',
        onAction: () => ref.invalidate(studyItemsProvider),
      );
    }
    final list = items.value ?? const <StudyItemSummary>[];
    final chats = threads.value ?? const <ChatThreadSummary>[];
    if (list.isEmpty && chats.isEmpty && !threads.isLoading && !threads.hasError) {
      return EmptyState(
        icon: Icons.school_outlined,
        title: 'Aún no hay materiales de estudio',
        message: 'Crea resúmenes, flashcards o cuestionarios a partir de tus notas con el asistente ✦.',
        actionLabel: 'Crear material',
        onAction: () => showAiActions(context, scope: Scopes.library),
      );
    }
    final byKind = <StudyKind, List<StudyItemSummary>>{};
    for (final it in list) {
      byKind.putIfAbsent(it.kind, () => []).add(it);
    }
    for (final l in byKind.values) {
      l.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    return RefreshIndicator(
      onRefresh: () async {
        ref.read(studyRevisionProvider.notifier).bump();
        ref.read(threadsRevisionProvider.notifier).bump();
        await ref.read(studyItemsProvider.future).catchError((_) => const <StudyItemSummary>[]);
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: Insets.xxl),
        children: [
          for (final k in kindOrder)
            if (byKind[k]?.isNotEmpty ?? false)
              GroupedSection(
                header: studyKindSection(k),
                children: [for (final it in byKind[k]!) _StudyRow(item: it)],
              ),
          if (threads.hasError && !threads.hasValue)
            GroupedSection(
              header: 'Conversaciones',
              children: [
                ListTile(
                  leading: Icon(Icons.error_outline_rounded, color: context.colors.danger),
                  title: const Text('No se pudieron cargar las conversaciones'),
                  subtitle: Text(humanError(threads.error!)),
                  trailing: TextButton(
                    onPressed: () => ref.invalidate(threadsProvider),
                    child: const Text('Reintentar'),
                  ),
                ),
              ],
            )
          else if (chats.isNotEmpty)
            GroupedSection(
              header: 'Conversaciones',
              children: [for (final t in chats) _ThreadRow(thread: t)],
            ),
        ],
      ),
    );
  }
}

class _StudyRow extends ConsumerWidget {
  const _StudyRow({required this.item});
  final StudyItemSummary item;

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final title = await promptText(context, title: 'Renombrar', initial: item.title, confirmLabel: 'Guardar');
    if (title == null || title == item.title) return;
    try {
      final gw = ref.read(studyGatewayProvider);
      final full = await gw.getItem(item.id);
      await gw.updateItem(item.id, title: title, contentJson: full.contentJson);
      ref.read(studyRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo renombrar');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirmAction(
      context,
      title: '¿Borrar «${item.title}»?',
      message:
          'Se eliminará este material${item.kind == StudyKind.quiz ? ' y sus intentos' : ''}. Tus notas no se modifican.',
      confirmLabel: 'Borrar',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(studyGatewayProvider).deleteItem(item.id);
      ref.read(studyRevisionProvider.notifier).bump();
      ref.read(libraryRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo borrar');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = studyItemCount(item.kind, item.itemCount);
    final subtitle = [
      if (item.scopeLabel.isNotEmpty) item.scopeLabel,
      if (count.isNotEmpty) count,
      Fmt.relativeDate(item.updatedAt),
    ].join(' · ');
    return ListTile(
      minTileHeight: 68,
      leading: Icon(studyKindIcon(item.kind)),
      title: Text(
        item.title.isEmpty ? studyKindLabel(item.kind) : item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => context.push('/study/${item.id}'),
      onLongPress: () => _rename(context, ref),
      trailing: _RowMenu(onRename: () => _rename(context, ref), onDelete: () => _delete(context, ref)),
    );
  }
}

class _ThreadRow extends ConsumerWidget {
  const _ThreadRow({required this.thread});
  final ChatThreadSummary thread;

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final title = await promptText(
      context,
      title: 'Renombrar conversación',
      initial: thread.title,
      confirmLabel: 'Guardar',
    );
    if (title == null || title == thread.title) return;
    try {
      await ref.read(aiGatewayProvider).renameThread(thread.id, title);
      ref.read(threadsRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo renombrar');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirmAction(
      context,
      title: '¿Borrar esta conversación?',
      message: 'Se eliminarán todos sus mensajes. Tus notas no se modifican.',
      confirmLabel: 'Borrar',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(aiGatewayProvider).deleteThread(thread.id);
      ref.read(threadsRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo borrar');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = [
      if (thread.scopeLabel.isNotEmpty) thread.scopeLabel,
      Fmt.count(thread.messageCount, 'mensaje', 'mensajes'),
      Fmt.relativeDate(thread.updatedAt),
    ].join(' · ');
    return ListTile(
      minTileHeight: 68,
      leading: const Icon(Icons.forum_outlined),
      title: Text(
        thread.title.trim().isEmpty ? 'Conversación' : thread.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => context.push('/chat/${thread.id}'),
      onLongPress: () => _rename(context, ref),
      trailing: _RowMenu(onRename: () => _rename(context, ref), onDelete: () => _delete(context, ref)),
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.onRename, required this.onDelete});
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final danger = context.colors.danger;
    return PopupMenuButton<int>(
      tooltip: 'Opciones',
      icon: Icon(Icons.more_horiz_rounded, color: context.colors.textSecondary),
      onSelected: (v) => v == 0 ? onRename() : onDelete(),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 0,
          child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Renombrar')),
        ),
        PopupMenuItem(
          value: 1,
          child: ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: danger),
            title: Text('Borrar', style: TextStyle(color: danger)),
          ),
        ),
      ],
    );
  }
}
