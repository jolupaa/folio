import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/large_title_scroll_view.dart';
import '../../widgets/skeleton.dart';
import '../ai/ai_entry.dart';
import '../search/bottom_search_bar.dart';
import 'compose_button.dart';
import 'folder_tree.dart';
import 'library_actions.dart';
import 'note_list_body.dart';

/// Listas transversales: bandeja «Notas», «Todas las notas» y «Fijadas».
class NoteListScreen extends ConsumerWidget {
  const NoteListScreen({super.key, required this.scope});
  final NoteListScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = LibraryActions(context, ref);
    final notes = ref.watch(notesProvider((scope: scope, folderId: null)));
    final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
    final showLocation = scope != NoteListScope.inbox;
    final locations = <String, String>{
      if (showLocation)
        for (final f in folders) f.id: folderAncestors(folders, f.id).map((x) => x.name).join(' › '),
    };
    final title = switch (scope) {
      NoteListScope.all => 'Todas las notas',
      NoteListScope.pinned => 'Fijadas',
      _ => 'Notas',
    };

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: BottomSearchBar(
        scope: Scopes.searchLibrary,
        placeholder: 'Buscar en todas las notas',
        trailing: ComposeButton(actions: actions, allowFolder: false, pinNew: scope == NoteListScope.pinned),
        body: LargeTitleScrollView(
          title: title,
          onRefresh: () async => actions.bump(),
          actions: [
            IconButton(
              tooltip: 'Asistente de IA sobre toda la biblioteca',
              icon: const Icon(Icons.auto_awesome_rounded),
              onPressed: () => showAiActions(context, scope: Scopes.library),
            ),
          ],
          slivers: notes.when(
            loading: () => const [SliverToBoxAdapter(child: SkeletonGroup(rows: 5, twoLine: true))],
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
                      child: scope == NoteListScope.pinned
                          ? const EmptyState(
                              icon: Icons.push_pin_outlined,
                              title: 'Nada fijado todavía',
                              message: 'Desliza una nota hacia la derecha o usa su menú para fijarla.',
                            )
                          : EmptyState(
                              icon: Icons.edit_note_rounded,
                              title: 'Aún no hay notas',
                              message: 'Escribe una nota o escanea tus apuntes para empezar.',
                              actionLabel: 'Nueva nota',
                              onAction: () => actions.newNote(),
                              secondaryLabel: 'Escanear apuntes',
                              onSecondary: () => actions.scan(),
                            ),
                    ),
                  ]
                : noteSections(
                    list,
                    actions,
                    locations: locations,
                    splitPinned: scope != NoteListScope.pinned,
                  ),
          ),
        ),
      ),
    );
  }
}
