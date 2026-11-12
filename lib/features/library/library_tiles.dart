import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../core/navigation.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/pressable_row.dart';
import '../../widgets/swipe_actions.dart';
import 'library_actions.dart';

/// Fila de la biblioteca: icono, título, contador y chevron.
class LibraryRow extends StatelessWidget {
  const LibraryRow({super.key, required this.icon, required this.title, this.count, required this.onTap});

  final IconData icon;
  final String title;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: count == null ? title : '$title, $count',
      excludeSemantics: true,
      child: PressableRow(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
          child: Row(
            children: [
              Icon(icon, color: c.accent),
              const SizedBox(width: Insets.lg),
              Expanded(child: Text(title, style: context.text.bodyLarge)),
              if (count != null)
                Text('$count', style: context.text.bodyLarge?.copyWith(color: c.textSecondary)),
              const SizedBox(width: Insets.xs),
              Icon(Icons.chevron_right_rounded, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fila de carpeta (árbol). [expanded] null = sin subcarpetas que desplegar.
class FolderRow extends StatelessWidget {
  const FolderRow({
    super.key,
    required this.folder,
    required this.actions,
    this.depth = 0,
    this.expanded,
    this.onToggle,
    this.showTotal = true,
  });

  final Folder folder;
  final LibraryActions actions;
  final int depth;
  final bool? expanded;
  final VoidCallback? onToggle;
  final bool showTotal;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final count = showTotal ? folder.totalNoteCount : folder.noteCount;
    final semanticsLabel = StringBuffer(folder.name)
      ..write(', ${Fmt.count(count, 'nota', 'notas')}')
      ..write(folder.childCount > 0 ? ', ${Fmt.count(folder.childCount, 'subcarpeta', 'subcarpetas')}' : '');
    return SwipeActions(
      leading: [
        SwipeAction(
          icon: Icons.drive_file_rename_outline_rounded,
          label: 'Renombrar',
          color: c.accent,
          foreground: c.onAccent,
          onTap: () => actions.renameFolder(folder),
        ),
      ],
      trailing: [
        SwipeAction(
          icon: Icons.drive_file_move_rounded,
          label: 'Mover',
          color: c.textSecondary,
          foreground: c.surface,
          onTap: () => actions.moveFolder(folder),
        ),
        SwipeAction(
          icon: Icons.delete_rounded,
          label: 'Borrar',
          color: c.danger,
          foreground: Theme.of(context).colorScheme.onError,
          onTap: () => actions.trashFolder(folder),
        ),
      ],
      child: PressableRow(
        onTap: () => context.openFolder(folder.id),
        onLongPress: (pos) => actions.folderMenu(folder, anchor: pos),
        child: Padding(
          padding: EdgeInsets.only(left: Insets.lg + depth * 20.0, right: expanded == null ? Insets.sm : 0),
          child: Row(
            children: [
              Semantics(
                button: true,
                label: semanticsLabel.toString(),
                excludeSemantics: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_rounded, color: c.accent),
                    const SizedBox(width: Insets.lg),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Insets.md),
                  child: ExcludeSemantics(
                    child: Text(
                      folder.name,
                      style: context.text.bodyLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              ExcludeSemantics(
                child: Text('$count', style: context.text.bodyLarge?.copyWith(color: c.textSecondary)),
              ),
              if (expanded != null)
                IconButton(
                  tooltip: expanded! ? 'Plegar ${folder.name}' : 'Desplegar ${folder.name}',
                  onPressed: onToggle,
                  icon: AnimatedRotation(
                    turns: expanded! ? 0.25 : 0,
                    duration: Motion.of(context, Motion.fast),
                    curve: Motion.curve,
                    child: Icon(Icons.chevron_right_rounded, color: c.textSecondary),
                  ),
                )
              else ...[
                const SizedBox(width: Insets.xs),
                Icon(Icons.chevron_right_rounded, color: c.textTertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Fila de nota: título, fecha relativa + vista previa, ubicación opcional, miniatura e iconos de
/// pizarra/adjuntos. Deslizar: Fijar (inicio), Mover/Borrar (fin); pulsación larga: menú.
class NoteRow extends StatelessWidget {
  const NoteRow({super.key, required this.note, required this.actions, this.location, this.now});

  final NoteSummary note;
  final LibraryActions actions;

  /// Carpeta de la nota (listas «Todas» y «Fijadas»).
  final String? location;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isBoard = note.kind == NoteKind.board;
    final title = noteDisplayTitle(note.title, note.kind);
    final date = Fmt.relativeDate(note.updatedAt, now: now);
    final preview = note.preview.trim().replaceAll('\n', ' ');
    final thumb = note.thumbnailPath;
    final semantics = [
      title,
      if (isBoard) 'Pizarra',
      if (note.pinned) 'Fijada',
      date,
      if (preview.isNotEmpty) preview,
      if (note.attachmentCount > 0) Fmt.count(note.attachmentCount, 'adjunto', 'adjuntos'),
      ?location,
    ].join('. ');

    return SwipeActions(
      leading: [
        SwipeAction(
          icon: note.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
          label: note.pinned ? 'Desfijar' : 'Fijar',
          color: c.accent,
          foreground: c.onAccent,
          onTap: () => actions.togglePin(note),
        ),
      ],
      trailing: [
        SwipeAction(
          icon: Icons.drive_file_move_rounded,
          label: 'Mover',
          color: c.textSecondary,
          foreground: c.surface,
          onTap: () => actions.moveNote(note.id, note.folderId),
        ),
        SwipeAction(
          icon: Icons.delete_rounded,
          label: 'Borrar',
          color: c.danger,
          foreground: Theme.of(context).colorScheme.onError,
          onTap: () => actions.trashNote(note.id, kind: note.kind),
        ),
      ],
      child: Semantics(
        button: true,
        label: semantics,
        excludeSemantics: true,
        child: PressableRow(
          minHeight: 68,
          onTap: () => context.openNote(note.id, kind: note.kind),
          onLongPress: (pos) => actions.noteMenu(note, anchor: pos),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Insets.lg, 10, Insets.lg, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (isBoard) ...[
                            Icon(Icons.draw_rounded, size: 18, color: c.accent),
                            const SizedBox(width: Insets.xs),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.titleMedium?.copyWith(
                                color: note.title.trim().isEmpty ? c.textSecondary : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: date,
                              style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w500),
                            ),
                            const TextSpan(text: '  '),
                            TextSpan(
                              text: preview.isEmpty ? (isBoard ? 'Pizarra' : 'Sin texto adicional') : preview,
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
                      ),
                      if (location != null || note.attachmentCount > 0 || note.pinned) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (note.pinned && location != null) ...[
                              Icon(Icons.push_pin_rounded, size: 14, color: c.textTertiary),
                              const SizedBox(width: 2),
                            ],
                            if (location != null) ...[
                              Icon(Icons.folder_outlined, size: 14, color: c.textTertiary),
                              const SizedBox(width: Insets.xs),
                              Flexible(
                                child: Text(
                                  location!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.text.bodySmall,
                                ),
                              ),
                              const SizedBox(width: Insets.sm),
                            ],
                            if (note.attachmentCount > 0) ...[
                              Icon(Icons.attach_file_rounded, size: 14, color: c.textTertiary),
                              Text('${note.attachmentCount}', style: context.text.bodySmall),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (thumb != null) ...[const SizedBox(width: Insets.md), _Thumbnail(path: thumb)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 52,
        height: 52,
        color: c.surfaceAlt,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: (52 * dpr).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Icon(Icons.image_not_supported_rounded, color: c.textTertiary),
        ),
      ),
    );
  }
}
