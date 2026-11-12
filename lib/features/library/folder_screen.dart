import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/large_title_scroll_view.dart';
import '../../widgets/skeleton.dart';
import '../ai/ai_entry.dart';
import '../search/bottom_search_bar.dart';
import 'compose_button.dart';
import 'folder_tree.dart';
import 'library_actions.dart';
import 'library_tiles.dart';
import 'note_list_body.dart';

/// Contenido de una carpeta: subcarpetas, fijadas y notas. Búsqueda limitada a la carpeta.
class FolderScreen extends ConsumerWidget {
  const FolderScreen({super.key, required this.folderId});
  final String folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = LibraryActions(context, ref);
    final foldersAsync = ref.watch(foldersProvider);
    final folders = foldersAsync.value ?? const <Folder>[];
    final folder = folders.where((f) => f.id == folderId).firstOrNull;
    final notes = ref.watch(notesProvider((scope: NoteListScope.folder, folderId: folderId)));

    if (folder == null) {
      return Scaffold(
        appBar: AppBar(),
        body: foldersAsync.isLoading
            ? const SkeletonGroup(rows: 4, twoLine: true)
            : EmptyState(
                icon: Icons.folder_off_outlined,
                title: 'Esta carpeta ya no existe',
                message: 'Puede que se haya movido a la papelera.',
                actionLabel: 'Volver',
                onAction: () => Navigator.of(context).maybePop(),
              ),
      );
    }

    final ancestors = folderAncestors(folders, folderId);
    final children = folders.where((f) => f.parentId == folderId).toList();

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: BottomSearchBar(
        scope: Scopes.searchFolder(folderId),
        placeholder: 'Buscar en ${folder.name}',
        trailing: ComposeButton(actions: actions, folderId: folderId),
        body: LargeTitleScrollView(
          title: folder.name,
          onRefresh: () async => actions.bump(),
          above: ancestors.length > 1
              ? Text(
                  ancestors.take(ancestors.length - 1).map((f) => f.name).join(' › '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall,
                )
              : null,
          below: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Insets.sm)),
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('Preguntar sobre esta carpeta'),
              onPressed: () => showAiActions(context, scope: Scopes.folder(folderId)),
            ),
          ),
          actions: [
            Builder(
              builder: (ctx) => IconButton(
                tooltip: 'Opciones de la carpeta',
                icon: const Icon(Icons.more_horiz_rounded),
                onPressed: () {
                  final box = ctx.findRenderObject() as RenderBox?;
                  actions.folderMenu(folder, anchor: box?.localToGlobal(box.size.bottomCenter(Offset.zero)));
                },
              ),
            ),
          ],
          slivers: [
            if (children.isNotEmpty)
              SliverToBoxAdapter(
                child: GroupedSection(
                  header: 'Subcarpetas',
                  children: [
                    for (final f in children) FolderRow(key: ValueKey(f.id), folder: f, actions: actions),
                  ],
                ),
              ),
            ...notes.when(
              loading: () => const [SliverToBoxAdapter(child: SkeletonGroup(rows: 4, twoLine: true))],
              error: (e, _) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.error_outline_rounded,
                    title: 'No se pudieron cargar las notas',
                    message: humanError(e),
                    actionLabel: 'Reintentar',
                    onAction: actions.bump,
                  ),
                ),
              ],
              data: (list) => list.isEmpty
                  ? [
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          compact: children.isNotEmpty,
                          icon: Icons.folder_open_rounded,
                          title: 'Carpeta vacía',
                          message: 'Escribe una nota, escanea tus apuntes o importa un PDF.',
                          actionLabel: 'Nueva nota',
                          onAction: () => actions.newNote(folderId: folderId),
                          secondaryLabel: 'Escanear apuntes',
                          onSecondary: () => actions.scan(folderId: folderId),
                        ),
                      ),
                    ]
                  : noteSections(list, actions),
            ),
          ],
        ),
      ),
    );
  }
}
