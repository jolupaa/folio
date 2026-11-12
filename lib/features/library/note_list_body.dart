import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/grouped_section.dart';
import 'library_actions.dart';
import 'library_tiles.dart';

/// Secciones «Fijadas» y «Notas» de una lista de notas (ya ordenadas por Rust).
List<Widget> noteSections(
  List<NoteSummary> notes,
  LibraryActions actions, {
  Map<String, String> locations = const {},
  bool splitPinned = true,
  String header = 'Notas',
}) {
  final pinned = splitPinned ? notes.where((n) => n.pinned).toList() : const <NoteSummary>[];
  final rest = splitPinned ? notes.where((n) => !n.pinned).toList() : notes;
  Widget row(NoteSummary n) => NoteRow(
    key: ValueKey(n.id),
    note: n,
    actions: actions,
    location: n.folderId == null ? null : locations[n.folderId],
  );
  return [
    if (pinned.isNotEmpty)
      SliverToBoxAdapter(
        child: GroupedSection(header: 'Fijadas', children: [for (final n in pinned) row(n)]),
      ),
    if (rest.isNotEmpty)
      SliverToBoxAdapter(
        child: GroupedSection(
          header: pinned.isNotEmpty || !splitPinned ? header : null,
          children: [for (final n in rest) row(n)],
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: Insets.xl)),
  ];
}
