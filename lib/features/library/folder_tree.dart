import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/types.dart';

/// Carpeta en un árbol aplanado con su profundidad.
typedef FolderNode = ({Folder folder, int depth});

/// Hijas por carpeta padre (null = raíz), conservando el orden de `list_folders`.
Map<String?, List<Folder>> childrenByParent(List<Folder> folders) {
  final map = <String?, List<Folder>>{};
  final ids = {for (final f in folders) f.id};
  for (final f in folders) {
    // Una carpeta cuyo padre no está en la lista se muestra en la raíz.
    final parent = f.parentId != null && ids.contains(f.parentId) ? f.parentId : null;
    (map[parent] ??= []).add(f);
  }
  return map;
}

/// Árbol aplanado en orden de lectura. Si [expanded] es null se despliega todo.
/// [excludeSubtreeOf] oculta esa carpeta y sus descendientes (destinos de «Mover»).
List<FolderNode> flattenFolders(List<Folder> folders, {Set<String>? expanded, String? excludeSubtreeOf}) {
  final children = childrenByParent(folders);
  final out = <FolderNode>[];
  final visited = <String>{};
  void walk(String? parent, int depth) {
    for (final f in children[parent] ?? const <Folder>[]) {
      if (f.id == excludeSubtreeOf || !visited.add(f.id)) continue;
      out.add((folder: f, depth: depth));
      if (expanded == null || expanded.contains(f.id)) walk(f.id, depth + 1);
    }
  }

  walk(null, 0);
  return out;
}

/// Ruta desde la raíz hasta [id] (incluida). Vacía si no existe.
List<Folder> folderAncestors(List<Folder> folders, String id) {
  final byId = {for (final f in folders) f.id: f};
  final path = <Folder>[];
  final seen = <String>{};
  String? current = id;
  while (current != null && seen.add(current)) {
    final f = byId[current];
    if (f == null) break;
    path.insert(0, f);
    current = f.parentId;
  }
  return path;
}

/// Carpetas desplegadas en el árbol de la biblioteca (se mantiene durante la sesión).
class ExpandedFolders extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String id) => state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
  void expand(String id) {
    if (!state.contains(id)) state = {...state, id};
  }
}

final expandedFoldersProvider = NotifierProvider<ExpandedFolders, Set<String>>(ExpandedFolders.new);
