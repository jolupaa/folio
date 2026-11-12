import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
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

/// Raíz de la biblioteca: accesos, árbol de carpetas, estudio y papelera.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = LibraryActions(context, ref);
    final folders = ref.watch(foldersProvider);
    final counts = ref.watch(libraryCountsProvider).value;
    final expanded = ref.watch(expandedFoldersProvider);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: BottomSearchBar(
        scope: Scopes.searchLibrary,
        placeholder: 'Buscar en todas las notas',
        trailing: ComposeButton(actions: actions),
        body: LargeTitleScrollView(
          title: 'Folio',
          onRefresh: () async => actions.bump(),
          actions: [
            IconButton(
              tooltip: 'Asistente de IA sobre toda la biblioteca',
              icon: const Icon(Icons.auto_awesome_rounded),
              onPressed: () => showAiActions(context, scope: Scopes.library),
            ),
            IconButton(
              tooltip: 'Ajustes',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.push('/settings'),
            ),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: GroupedSection(
                children: [
                  LibraryRow(
                    icon: Icons.sticky_note_2_outlined,
                    title: 'Notas',
                    count: counts?.inbox,
                    onTap: () => context.push('/notes/inbox'),
                  ),
                  LibraryRow(
                    icon: Icons.notes_rounded,
                    title: 'Todas las notas',
                    count: counts?.all,
                    onTap: () => context.push('/notes/all'),
                  ),
                  LibraryRow(
                    icon: Icons.push_pin_outlined,
                    title: 'Fijadas',
                    count: counts?.pinned,
                    onTap: () => context.push('/notes/pinned'),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: folders.when(
                loading: () => const SkeletonGroup(rows: 3, header: true),
                error: (e, _) => EmptyState(
                  compact: true,
                  icon: Icons.error_outline_rounded,
                  title: 'No se pudieron cargar las carpetas',
                  message: humanError(e),
                  actionLabel: 'Reintentar',
                  onAction: actions.bump,
                ),
                data: (list) {
                  final nodes = flattenFolders(list, expanded: expanded);
                  return GroupedSection(
                    header: 'Carpetas',
                    trailing: IconButton(
                      tooltip: 'Nueva carpeta',
                      icon: const Icon(Icons.create_new_folder_outlined),
                      onPressed: () => actions.newFolder(),
                    ),
                    footer: nodes.isEmpty
                        ? 'Crea una carpeta para organizar tus asignaturas o proyectos.'
                        : null,
                    children: [
                      for (final n in nodes)
                        FolderRow(
                          key: ValueKey(n.folder.id),
                          folder: n.folder,
                          actions: actions,
                          depth: n.depth,
                          expanded: n.folder.childCount > 0 ? expanded.contains(n.folder.id) : null,
                          onToggle: () => ref.read(expandedFoldersProvider.notifier).toggle(n.folder.id),
                        ),
                      if (nodes.isEmpty)
                        LibraryRow(
                          icon: Icons.create_new_folder_outlined,
                          title: 'Nueva carpeta',
                          onTap: () => actions.newFolder(),
                        ),
                    ],
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: GroupedSection(
                children: [
                  LibraryRow(
                    icon: Icons.school_outlined,
                    title: 'Estudio',
                    count: counts?.studyItems,
                    onTap: () => context.push('/study'),
                  ),
                  LibraryRow(
                    icon: Icons.delete_outline_rounded,
                    title: 'Papelera',
                    count: counts?.trash,
                    onTap: () => context.push('/trash'),
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: Insets.xl)),
          ],
        ),
      ),
    );
  }
}
