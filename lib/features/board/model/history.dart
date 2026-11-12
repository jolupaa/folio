import 'dart:collection';

import 'elements.dart';

/// Elemento con su posición en una lista.
class IndexedElement {
  const IndexedElement(this.index, this.element);
  final int index;
  final BoardElement element;
}

/// Cambio de un elemento que conserva su posición (mismo id).
class ElementChange {
  const ElementChange(this.before, this.after);
  final BoardElement before;
  final BoardElement after;
}

/// Operación reversible sobre la lista de elementos.
///
/// Aplicar sobre el estado «antes»: se quitan [removed] (índices en la lista anterior), se
/// sustituyen [updated] por id y se insertan [inserted] (índices en la lista resultante). Las
/// posiciones relativas de los demás elementos se mantienen, así que la inversa es exacta.
class SceneEdit {
  SceneEdit({
    List<IndexedElement> removed = const [],
    List<IndexedElement> inserted = const [],
    this.updated = const [],
  }) : removed = (List.of(removed)..sort((a, b) => a.index.compareTo(b.index))),
       inserted = (List.of(inserted)..sort((a, b) => a.index.compareTo(b.index)));

  final List<IndexedElement> removed;
  final List<IndexedElement> inserted;
  final List<ElementChange> updated;

  bool get isEmpty => removed.isEmpty && inserted.isEmpty && updated.isEmpty;

  SceneEdit get inverse => SceneEdit(
    removed: inserted,
    inserted: removed,
    updated: [for (final u in updated) ElementChange(u.after, u.before)],
  );

  /// Coste aproximado en memoria (números retenidos).
  int get weight {
    var w = 8;
    for (final r in removed) {
      w += r.element.weight;
    }
    for (final i in inserted) {
      w += i.element.weight;
    }
    for (final u in updated) {
      w += u.before.weight + u.after.weight;
    }
    return w;
  }

  /// Devuelve la lista resultante (O(n)); no modifica `before`.
  List<BoardElement> applyTo(List<BoardElement> before) {
    final removedIdx = <int>{for (final r in removed) r.index};
    final replace = <String, BoardElement>{for (final u in updated) u.before.id: u.after};
    final rest = <BoardElement>[];
    for (var i = 0; i < before.length; i++) {
      if (removedIdx.contains(i)) continue;
      final e = before[i];
      rest.add(replace[e.id] ?? e);
    }
    if (inserted.isEmpty) return rest;
    final out = <BoardElement>[];
    var src = 0;
    for (final ins in inserted) {
      while (out.length < ins.index && src < rest.length) {
        out.add(rest[src++]);
      }
      out.add(ins.element);
    }
    while (src < rest.length) {
      out.add(rest[src++]);
    }
    return out;
  }
}

/// Historial de deshacer/rehacer ilimitado en la sesión, con un presupuesto de memoria: si se
/// supera, se descartan las operaciones más antiguas (nunca la última).
class BoardHistory {
  BoardHistory({this.maxWeight = defaultMaxWeight});

  /// ≈ 3 M números (≈ 24 MB en el peor caso de trazos no compartidos con la escena).
  static const defaultMaxWeight = 3000000;

  final int maxWeight;
  final _undo = ListQueue<SceneEdit>();
  final _redo = <SceneEdit>[];
  int _weight = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoCount => _undo.length;
  int get redoCount => _redo.length;
  int get weight => _weight;

  void push(SceneEdit edit) {
    if (edit.isEmpty) return;
    _undo.addLast(edit);
    _weight += edit.weight;
    for (final r in _redo) {
      _weight -= r.weight;
    }
    _redo.clear();
    while (_weight > maxWeight && _undo.length > 1) {
      _weight -= _undo.removeFirst().weight;
    }
  }

  /// Operación inversa que hay que aplicar para deshacer (null si no hay nada).
  SceneEdit? undo() {
    if (_undo.isEmpty) return null;
    final e = _undo.removeLast();
    _redo.add(e);
    return e.inverse;
  }

  /// Operación que hay que volver a aplicar (null si no hay nada).
  SceneEdit? redo() {
    if (_redo.isEmpty) return null;
    final e = _redo.removeLast();
    _undo.addLast(e);
    return e;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
    _weight = 0;
  }
}
