import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/providers.dart';
import '../../src/rust/api/library.dart' as lib;
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton.dart';
import 'folder_tree.dart';

/// Destino elegido para mover: `folderId` null = «Notas» (sin carpeta).
typedef FolderDestination = ({String? folderId, String label});

/// Hoja para elegir carpeta de destino. [currentFolderId] se marca y no se puede elegir;
/// [excludeSubtreeOf] oculta una carpeta y sus descendientes (mover carpetas: evita ciclos).
Future<FolderDestination?> pickFolderDestination(
  BuildContext context, {
  required String title,
  String? currentFolderId,
  bool currentIsRoot = false,
  String? excludeSubtreeOf,
}) {
  return showModalBottomSheet<FolderDestination>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => _FolderPickerSheet(
        title: title,
        scroll: scroll,
        currentFolderId: currentFolderId,
        currentIsRoot: currentIsRoot,
        excludeSubtreeOf: excludeSubtreeOf,
      ),
    ),
  );
}

class _FolderPickerSheet extends ConsumerWidget {
  const _FolderPickerSheet({
    required this.title,
    required this.scroll,
    required this.currentFolderId,
    required this.currentIsRoot,
    required this.excludeSubtreeOf,
  });

  final String title;
  final ScrollController scroll;
  final String? currentFolderId;
  final bool currentIsRoot;
  final String? excludeSubtreeOf;

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await promptText(context, title: 'Nueva carpeta', hint: 'Nombre', confirmLabel: 'Crear');
    if (name == null) return;
    try {
      final f = await lib.createFolder(name: name);
      ref.read(libraryRevisionProvider.notifier).bump();
      if (context.mounted) Navigator.pop<FolderDestination>(context, (folderId: f.id, label: f.name));
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo crear la carpeta');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final folders = ref.watch(foldersProvider);
    Widget row({
      required IconData icon,
      required String label,
      required int depth,
      required bool current,
      required VoidCallback? onTap,
    }) {
      return Semantics(
        selected: current,
        button: true,
        child: ListTile(
          enabled: onTap != null,
          contentPadding: EdgeInsets.only(left: Insets.lg + depth * 20.0, right: Insets.lg),
          leading: Icon(icon, color: current ? c.textTertiary : c.accent),
          title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: current
              ? Icon(Icons.check_rounded, color: c.textTertiary, semanticLabel: 'Ubicación actual')
              : null,
          onTap: onTap,
        ),
      );
    }

    final body = folders.when(
      loading: () => const SkeletonGroup(rows: 4),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'No se pudieron cargar las carpetas',
        message: humanError(e),
        actionLabel: 'Reintentar',
        onAction: () => ref.invalidate(foldersProvider),
        compact: true,
      ),
      data: (list) {
        final nodes = flattenFolders(list, excludeSubtreeOf: excludeSubtreeOf);
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.only(bottom: Insets.xl),
          children: [
            ListTile(
              leading: Icon(Icons.create_new_folder_rounded, color: c.accent),
              title: Text('Nueva carpeta', style: TextStyle(color: c.accent)),
              onTap: () => _create(context, ref),
            ),
            Divider(height: 0.6, color: c.separator),
            row(
              icon: Icons.inbox_rounded,
              label: 'Notas (sin carpeta)',
              depth: 0,
              current: currentIsRoot,
              onTap: currentIsRoot
                  ? null
                  : () => Navigator.pop<FolderDestination>(context, (folderId: null, label: 'Notas')),
            ),
            for (final n in nodes)
              row(
                icon: Icons.folder_rounded,
                label: n.folder.name,
                depth: n.depth,
                current: n.folder.id == currentFolderId,
                onTap: n.folder.id == currentFolderId
                    ? null
                    : () => Navigator.pop<FolderDestination>(context, (
                        folderId: n.folder.id,
                        label: n.folder.name,
                      )),
              ),
          ],
        );
      },
    );

    return Material(
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.sm, Insets.sm),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(header: true, child: Text(title, style: context.text.titleMedium)),
                ),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
