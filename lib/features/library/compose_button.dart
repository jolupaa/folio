import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../widgets/adaptive_menu.dart';
import 'library_actions.dart';

enum _Compose { note, board, scan, import, folder }

/// Botón «componer» de la barra inferior con el menú de creación.
class ComposeButton extends StatelessWidget {
  const ComposeButton({
    super.key,
    required this.actions,
    this.folderId,
    this.allowFolder = true,
    this.pinNew = false,
    this.onFolderCreated,
  });

  final LibraryActions actions;

  /// Carpeta donde se crea (null = bandeja «Notas»).
  final String? folderId;
  final bool allowFolder;

  /// Fija lo creado (lista «Fijadas»).
  final bool pinNew;
  final VoidCallback? onFolderCreated;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final anchor = box == null ? null : box.localToGlobal(box.size.topCenter(Offset.zero));
    final choice = await showAdaptiveMenu<_Compose>(
      context,
      anchor: anchor,
      actions: [
        const MenuAction(value: _Compose.note, label: 'Nueva nota', icon: Icons.edit_note_rounded),
        const MenuAction(value: _Compose.board, label: 'Nueva pizarra', icon: Icons.draw_rounded),
        const MenuAction(
          value: _Compose.scan,
          label: 'Escanear apuntes',
          icon: Icons.document_scanner_rounded,
        ),
        const MenuAction(
          value: _Compose.import,
          label: 'Importar foto o PDF',
          icon: Icons.upload_file_rounded,
        ),
        if (allowFolder)
          MenuAction(
            value: _Compose.folder,
            label: folderId == null ? 'Nueva carpeta' : 'Nueva subcarpeta',
            icon: Icons.create_new_folder_rounded,
          ),
      ],
    );
    switch (choice) {
      case _Compose.note:
        await actions.newNote(folderId: folderId, pinned: pinNew);
      case _Compose.board:
        await actions.newBoard(folderId: folderId, pinned: pinNew);
      case _Compose.scan:
        await actions.scan(folderId: folderId);
      case _Compose.import:
        await actions.importFile(folderId: folderId, anchor: anchor);
      case _Compose.folder:
        final f = await actions.newFolder(parentId: folderId);
        if (f != null) onFolderCreated?.call();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IconButton(
      tooltip: 'Crear',
      onPressed: () => _open(context),
      icon: Icon(Icons.edit_square, color: c.accent),
    );
  }
}
