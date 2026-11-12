import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/library.dart' as lib;
import '../../src/rust/api/types.dart';
import '../../widgets/adaptive_menu.dart';
import '../../widgets/dialogs.dart';
import '../capture/capture_entry.dart';
import '../capture/capture_flow.dart' show CaptureSource;
import '../notes/blocks_codec.dart';
import 'folder_picker.dart';
import 'folder_tree.dart';

/// Acciones de biblioteca compartidas por las pantallas de lista. Usa el `context` de la PANTALLA
/// (estable durante las operaciones asíncronas) y el `ref` de esa pantalla.
class LibraryActions {
  LibraryActions(this.context, this.ref) : _revision = ref.read(libraryRevisionProvider.notifier);

  final BuildContext context;
  final WidgetRef ref;
  final LibraryRevision _revision;

  void bump() => _revision.bump();

  ScaffoldMessengerState? get _messenger => ScaffoldMessenger.maybeOf(context);

  void _error(Object e, String prefix) {
    if (context.mounted) showErrorSnack(context, e, prefix: prefix);
  }

  /// Muestra un aviso con «Deshacer» que no depende de que la pantalla siga montada.
  void _undoSnack(String message, Future<void> Function() undo) {
    final messenger = _messenger;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: () async {
              try {
                await undo();
                _revision.bump();
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('No se pudo deshacer: ${humanError(e)}')));
              }
            },
          ),
        ),
      );
  }

  // ───────────── Crear ─────────────

  Future<void> newNote({String? folderId, bool pinned = false}) async {
    try {
      final note = await lib.createNote(folderId: folderId, kind: NoteKind.text, title: '');
      if (pinned) await lib.setNotePinned(id: note.id, pinned: true);
      bump();
      if (context.mounted) unawaited(context.openNote(note.id));
    } catch (e) {
      _error(e, 'No se pudo crear la nota');
    }
  }

  Future<void> newBoard({String? folderId, bool pinned = false}) async {
    try {
      final note = await lib.createNote(folderId: folderId, kind: NoteKind.board, title: '');
      if (pinned) await lib.setNotePinned(id: note.id, pinned: true);
      bump();
      if (context.mounted) unawaited(context.openNote(note.id, kind: NoteKind.board));
    } catch (e) {
      _error(e, 'No se pudo crear la pizarra');
    }
  }

  /// Escanear apuntes: escáner de documentos en iOS (VisionKit), cámara en Android.
  Future<void> scan({String? folderId}) async {
    final source = context.isCupertino ? CaptureSource.scanner : CaptureSource.camera;
    try {
      final id = await startCapture(context, folderId: folderId, source: source);
      if (id == null) return;
      bump();
      if (context.mounted) unawaited(context.openNote(id));
    } catch (e) {
      _error(e, 'No se pudo escanear');
    }
  }

  /// Importar foto o PDF: crea una nota con el adjunto como primer bloque.
  Future<void> importFile({String? folderId, Offset? anchor}) async {
    final kind = await showAdaptiveMenu<AttachKind>(
      context,
      title: 'Importar',
      anchor: anchor,
      actions: const [
        MenuAction(value: AttachKind.image, label: 'Foto o imagen', icon: Icons.image_rounded),
        MenuAction(value: AttachKind.pdf, label: 'Documento PDF', icon: Icons.picture_as_pdf_rounded),
      ],
    );
    if (kind == null || !context.mounted) return;
    Note? note;
    var saved = false;
    try {
      note = await lib.createNote(folderId: folderId, kind: NoteKind.text, title: '');
      if (!context.mounted) return;
      final attachment = await pickAndAttach(context, noteId: note.id, kind: kind);
      if (attachment == null) return;
      final block = NoteBlock(
        id: newBlockId(),
        type: attachment.kind == AttachmentKind.pdf ? BlockType.pdf : BlockType.image,
        attachmentId: attachment.id,
      );
      await lib.saveNote(
        id: note.id,
        title: titleFromFileName(attachment.fileName),
        bodyJson: encodeBlocks([block]),
        baseRevision: note.revision,
      );
      saved = true;
      bump();
      if (context.mounted) unawaited(context.openNote(note.id));
    } catch (e) {
      _error(e, 'No se pudo importar');
    } finally {
      // Cancelado o fallido: no se deja una nota vacía en la biblioteca.
      if (note != null && !saved) await _discard(note.id);
    }
  }

  Future<void> _discard(String noteId) async {
    try {
      await lib.trashNote(id: noteId);
      await lib.deletePermanently(kind: TrashKind.note, id: noteId);
    } catch (_) {
      // La nota vacía queda en la papelera y se purga a los 30 días.
    }
    bump();
  }

  // ───────────── Carpetas ─────────────

  Future<Folder?> newFolder({String? parentId}) async {
    final name = await promptText(
      context,
      title: parentId == null ? 'Nueva carpeta' : 'Nueva subcarpeta',
      hint: 'Nombre',
      confirmLabel: 'Crear',
    );
    if (name == null) return null;
    try {
      final f = await lib.createFolder(parentId: parentId, name: name);
      if (parentId != null && context.mounted) ref.read(expandedFoldersProvider.notifier).expand(parentId);
      bump();
      return f;
    } catch (e) {
      _error(e, 'No se pudo crear la carpeta');
      return null;
    }
  }

  Future<void> renameFolder(Folder folder) async {
    final name = await promptText(
      context,
      title: 'Renombrar carpeta',
      initial: folder.name,
      hint: 'Nombre',
      confirmLabel: 'Guardar',
    );
    if (name == null || name == folder.name) return;
    try {
      await lib.renameFolder(id: folder.id, name: name);
      bump();
    } catch (e) {
      _error(e, 'No se pudo renombrar');
    }
  }

  Future<void> moveFolder(Folder folder) async {
    final dest = await pickFolderDestination(
      context,
      title: 'Mover «${folder.name}»',
      currentFolderId: folder.parentId,
      currentIsRoot: folder.parentId == null,
      excludeSubtreeOf: folder.id,
    );
    if (dest == null) return;
    try {
      await lib.moveFolder(id: folder.id, newParentId: dest.folderId);
      if (dest.folderId != null && context.mounted)
        ref.read(expandedFoldersProvider.notifier).expand(dest.folderId!);
      bump();
      if (context.mounted) showInfoSnack(context, 'Carpeta movida a ${dest.label}');
    } catch (e) {
      _error(e, 'No se pudo mover la carpeta');
    }
  }

  /// Devuelve true si la carpeta se movió a la papelera.
  Future<bool> trashFolder(Folder folder) async {
    final n = folder.totalNoteCount;
    final ok = await confirmAction(
      context,
      title: '¿Borrar «${folder.name}»?',
      message: n == 0
          ? 'La carpeta y sus subcarpetas se moverán a la papelera durante 30 días.'
          : 'La carpeta, sus subcarpetas y ${n == 1 ? 'su nota' : 'sus $n notas'} se moverán a la papelera durante 30 días.',
      confirmLabel: 'Borrar',
      destructive: true,
    );
    if (!ok) return false;
    try {
      await lib.trashFolder(id: folder.id);
      bump();
      _undoSnack(
        'Carpeta movida a la papelera',
        () => lib.restoreFromTrash(kind: TrashKind.folder, id: folder.id),
      );
      return true;
    } catch (e) {
      _error(e, 'No se pudo borrar la carpeta');
      return false;
    }
  }

  Future<void> folderMenu(Folder folder, {Offset? anchor}) async {
    final action = await showAdaptiveMenu<String>(
      context,
      title: folder.name,
      anchor: anchor,
      actions: const [
        MenuAction(value: 'sub', label: 'Nueva subcarpeta', icon: Icons.create_new_folder_rounded),
        MenuAction(value: 'rename', label: 'Renombrar', icon: Icons.drive_file_rename_outline_rounded),
        MenuAction(value: 'move', label: 'Mover', icon: Icons.drive_file_move_rounded),
        MenuAction(value: 'trash', label: 'Borrar', icon: Icons.delete_rounded, destructive: true),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'sub':
        await newFolder(parentId: folder.id);
      case 'rename':
        await renameFolder(folder);
      case 'move':
        await moveFolder(folder);
      case 'trash':
        await trashFolder(folder);
    }
  }

  // ───────────── Notas ─────────────

  Future<void> togglePin(NoteSummary note) async {
    try {
      await lib.setNotePinned(id: note.id, pinned: !note.pinned);
      bump();
    } catch (e) {
      _error(e, note.pinned ? 'No se pudo desfijar' : 'No se pudo fijar');
    }
  }

  Future<void> moveNote(String noteId, String? currentFolderId) async {
    final dest = await pickFolderDestination(
      context,
      title: 'Mover a…',
      currentFolderId: currentFolderId,
      currentIsRoot: currentFolderId == null,
    );
    if (dest == null) return;
    try {
      await lib.moveNote(id: noteId, folderId: dest.folderId);
      bump();
      if (context.mounted) showInfoSnack(context, 'Movida a ${dest.label}');
    } catch (e) {
      _error(e, 'No se pudo mover la nota');
    }
  }

  Future<void> trashNote(String noteId, {NoteKind kind = NoteKind.text}) async {
    try {
      await lib.trashNote(id: noteId);
      bump();
      _undoSnack(
        kind == NoteKind.board ? 'Pizarra movida a la papelera' : 'Nota movida a la papelera',
        () => lib.restoreFromTrash(kind: TrashKind.note, id: noteId),
      );
    } catch (e) {
      _error(e, 'No se pudo borrar');
    }
  }

  Future<void> noteMenu(NoteSummary note, {Offset? anchor}) async {
    final action = await showAdaptiveMenu<String>(
      context,
      title: noteDisplayTitle(note.title, note.kind),
      anchor: anchor,
      actions: [
        MenuAction(
          value: 'pin',
          label: note.pinned ? 'Desfijar' : 'Fijar',
          icon: note.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
        ),
        const MenuAction(value: 'move', label: 'Mover', icon: Icons.drive_file_move_rounded),
        const MenuAction(value: 'trash', label: 'Borrar', icon: Icons.delete_rounded, destructive: true),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'pin':
        await togglePin(note);
      case 'move':
        await moveNote(note.id, note.folderId);
      case 'trash':
        await trashNote(note.id, kind: note.kind);
    }
  }
}

/// Título visible de una nota o pizarra.
String noteDisplayTitle(String title, NoteKind kind) {
  final t = title.trim();
  if (t.isNotEmpty) return t;
  return kind == NoteKind.board ? 'Pizarra sin título' : 'Nota sin título';
}

/// «apuntes-tema2.pdf» → «apuntes-tema2».
String titleFromFileName(String fileName) {
  final name = fileName.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.replaceAll('_', ' ').trim();
}
