import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../src/rust/api/library.dart' as lib;
import '../../src/rust/api/types.dart';
import '../../widgets/adaptive_menu.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/pressable_row.dart';
import '../../widgets/skeleton.dart';

final trashProvider = FutureProvider<List<TrashItem>>((ref) {
  ref.watch(libraryRevisionProvider);
  return lib.listTrash();
});

enum _TrashAction { restore, delete }

/// Papelera: restaurar o borrar definitivamente. Los elementos se eliminan solos a los 30 días.
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() op, String ok) async {
    try {
      await op();
      ref.read(libraryRevisionProvider.notifier).bump();
      if (context.mounted) showInfoSnack(context, ok);
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, TrashItem item) async {
    final choice = await showAdaptiveMenu<_TrashAction>(
      context,
      title: item.title,
      actions: const [
        MenuAction(value: _TrashAction.restore, label: 'Restaurar', icon: Icons.restore_rounded),
        MenuAction(
          value: _TrashAction.delete,
          label: 'Borrar definitivamente',
          icon: Icons.delete_forever_rounded,
          destructive: true,
        ),
      ],
    );
    if (choice == null || !context.mounted) return;
    if (choice == _TrashAction.restore) {
      await _run(
        context,
        ref,
        () => lib.restoreFromTrash(kind: item.kind, id: item.id),
        'Restaurado en ${Fmt.location(item.originalLocation)}',
      );
    } else {
      final ok = await confirmAction(
        context,
        title: '¿Borrar definitivamente?',
        message: item.kind == TrashKind.folder
            ? 'Se borrarán la carpeta y ${Fmt.count(item.containedNotes, 'nota', 'notas')} con sus adjuntos. No se puede deshacer.'
            : 'Se borrará la nota con sus adjuntos. No se puede deshacer.',
        confirmLabel: 'Borrar',
        destructive: true,
      );
      if (ok && context.mounted) {
        await _run(
          context,
          ref,
          () => lib.deletePermanently(kind: item.kind, id: item.id),
          'Borrado definitivamente',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trash = ref.watch(trashProvider);
    final c = context.colors;
    final hasItems = trash.value?.isNotEmpty ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Papelera'),
        actions: [
          if (hasItems)
            TextButton(
              onPressed: () async {
                final ok = await confirmAction(
                  context,
                  title: '¿Vaciar la papelera?',
                  message: 'Todos los elementos se borrarán definitivamente con sus adjuntos.',
                  confirmLabel: 'Vaciar',
                  destructive: true,
                );
                if (ok && context.mounted) {
                  await _run(context, ref, () async => lib.emptyTrash(), 'Papelera vaciada');
                }
              },
              child: Text('Vaciar', style: TextStyle(color: c.danger)),
            ),
        ],
      ),
      body: trash.when(
        loading: () => const SkeletonGroup(rows: 4, twoLine: true),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudo abrir la papelera',
          message: humanError(e),
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(trashProvider),
        ),
        data: (items) => items.isEmpty
            ? const EmptyState(
                icon: Icons.delete_outline_rounded,
                title: 'La papelera está vacía',
                message: 'Lo que borres se guarda aquí 30 días antes de eliminarse.',
              )
            : ListView(
                children: [
                  GroupedSection(
                    footer: 'Los elementos se eliminan definitivamente 30 días después de borrarlos.',
                    children: [
                      for (final item in items)
                        PressableRow(
                          minHeight: 64,
                          onTap: () => _menu(context, ref, item),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
                            child: Row(
                              children: [
                                Icon(
                                  item.kind == TrashKind.folder
                                      ? Icons.folder_outlined
                                      : item.noteKind == NoteKind.board
                                      ? Icons.draw_outlined
                                      : Icons.sticky_note_2_outlined,
                                  color: c.textSecondary,
                                ),
                                const SizedBox(width: Insets.lg),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title.trim().isEmpty ? 'Sin título' : item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        [
                                          Fmt.location(item.originalLocation),
                                          if (item.kind == TrashKind.folder)
                                            Fmt.count(item.containedNotes, 'nota', 'notas'),
                                          item.daysLeft == 0
                                              ? 'se elimina hoy'
                                              : 'quedan ${Fmt.count(item.daysLeft, 'día', 'días')}',
                                        ].join(' · '),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Restaurar',
                                  icon: const Icon(Icons.restore_rounded),
                                  onPressed: () => _run(
                                    context,
                                    ref,
                                    () => lib.restoreFromTrash(kind: item.kind, id: item.id),
                                    'Restaurado en ${Fmt.location(item.originalLocation)}',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
