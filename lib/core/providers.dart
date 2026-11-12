import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/ai.dart' as ai;
import '../src/rust/api/library.dart' as lib;
import '../src/rust/api/types.dart';

/// Contador de revisión de la biblioteca. Cualquier mutación (crear, guardar, mover, borrar,
/// restaurar, importar) debe llamar a `ref.read(libraryRevisionProvider.notifier).bump()`
/// para que listas y contadores se recarguen.
class LibraryRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final libraryRevisionProvider = NotifierProvider<LibraryRevision, int>(LibraryRevision.new);

final foldersProvider = FutureProvider<List<Folder>>((ref) {
  ref.watch(libraryRevisionProvider);
  return lib.listFolders();
});

final libraryCountsProvider = FutureProvider<LibraryCounts>((ref) {
  ref.watch(libraryRevisionProvider);
  return lib.libraryCounts();
});

typedef NoteListKey = ({NoteListScope scope, String? folderId});

final notesProvider = FutureProvider.family<List<NoteSummary>, NoteListKey>((ref, key) {
  ref.watch(libraryRevisionProvider);
  return lib.listNotes(scope: key.scope, folderId: key.folderId);
});

final folderPathProvider = FutureProvider.family<List<Folder>, String?>((ref, folderId) {
  ref.watch(libraryRevisionProvider);
  return lib.folderPath(folderId: folderId);
});

/// Carpeta por id (desde la lista cacheada).
final folderProvider = FutureProvider.family<Folder?, String>((ref, id) async {
  final folders = await ref.watch(foldersProvider.future);
  for (final f in folders) {
    if (f.id == id) return f;
  }
  return null;
});

/// Estado de la IA (modelo instalado, dispositivo compatible…). Invalidar tras cambios de modelos.
final aiStatusProvider = FutureProvider<AiStatus>((ref) => ai.aiStatus());

/// Estado del indexador en vivo.
final indexStatusProvider = StreamProvider<IndexStatus>((ref) => ai.watchIndex());
