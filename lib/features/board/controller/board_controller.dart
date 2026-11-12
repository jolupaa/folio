import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../model/board_color.dart';
import '../model/elements.dart';
import '../model/geometry.dart';
import '../model/history.dart';
import '../model/scene.dart';

enum BoardTool {
  pen('Lápiz'),
  highlighter('Marcador'),
  eraser('Borrador'),
  select('Seleccionar'),
  text('Texto'),
  shape('Formas');

  const BoardTool(this.label);
  final String label;

  bool get hasColor => this != eraser && this != select;
}

enum SelectionMode {
  lasso('Lazo'),
  rect('Rectángulo');

  const SelectionMode(this.label);
  final String label;
}

/// Grosor/tamaño de una herramienta: 3 valores predefinidos y rango del deslizador.
class SizeSpec {
  const SizeSpec(this.presets, this.min, this.max, this.labels, this.unit);
  final List<double> presets;
  final double min, max;
  final List<String> labels;

  /// Unidad para lectores de pantalla.
  final String unit;
}

const _strokeLabels = ['Fino', 'Medio', 'Grueso'];

const toolSizeSpecs = <BoardTool, SizeSpec>{
  BoardTool.pen: SizeSpec([2, 4, 8], 1, 24, _strokeLabels, 'puntos'),
  BoardTool.highlighter: SizeSpec([12, 20, 32], 6, 60, _strokeLabels, 'puntos'),
  BoardTool.eraser: SizeSpec([8, 16, 32], 4, 64, ['Pequeño', 'Mediano', 'Grande'], 'puntos de radio'),
  BoardTool.shape: SizeSpec([1.5, 3, 6], 1, 16, _strokeLabels, 'puntos'),
  BoardTool.text: SizeSpec([16, 24, 36], 10, 96, ['Pequeño', 'Mediano', 'Grande'], 'puntos'),
};

class _ToolStyle {
  _ToolStyle(this.colorIndex, this.size);
  int colorIndex;
  double size;
}

/// Estado editable de una pizarra: elementos, vista, herramienta activa, selección e historial.
///
/// Es lógica pura (sin widgets) para poder probarla. Notifica cualquier cambio; quien dibuja
/// compara [sceneRevision] para saber si los elementos han cambiado.
class BoardController extends ChangeNotifier {
  BoardController({BoardScene scene = const BoardScene(), String title = '', BoardHistory? history, String Function()? newId})
    : _scene = scene,
      _elements = List.of(scene.elements),
      _title = title,
      viewport = ValueNotifier(scene.viewport),
      history = history ?? BoardHistory(),
      _newId = newId ?? const Uuid().v4;

  final BoardScene _scene;
  List<BoardElement> _elements;
  UnmodifiableListView<BoardElement>? _view;
  Map<String, int>? _indexById;
  int _sceneRevision = 0;
  int _titleRevision = 0;
  String _title;
  final BoardHistory history;
  final String Function() _newId;

  /// Vista actual (no forma parte del historial). Se guarda con la escena.
  final ValueNotifier<BoardViewport> viewport;

  // ─────────────────────────── escena ───────────────────────────

  List<BoardElement> get elements => _view ??= UnmodifiableListView(_elements);

  /// Cambia cada vez que cambian los elementos (añadir, borrar, deshacer…).
  int get sceneRevision => _sceneRevision;
  int get titleRevision => _titleRevision;

  String get title => _title;
  set title(String v) {
    if (v == _title) return;
    _title = v;
    _titleRevision++;
    notifyListeners();
  }

  String newId() => _newId();

  int indexOf(String id) {
    final map = _indexById ??= {for (var i = 0; i < _elements.length; i++) _elements[i].id: i};
    return map[id] ?? -1;
  }

  BoardElement? byId(String id) {
    final i = indexOf(id);
    return i < 0 ? null : _elements[i];
  }

  /// Escena actual para guardar. Incluye el texto que se está escribiendo (si no está vacío) para
  /// que un guardado al pasar a segundo plano no lo pierda.
  BoardScene toScene() => _scene.copyWith(viewport: viewport.value, elements: List.unmodifiable(_withDraft()));

  List<BoardElement> _withDraft() {
    final d = _draft;
    if (d == null || d.text.trim().isEmpty) return _elements;
    final o = _draftOriginal;
    if (o != null) {
      final i = indexOf(o.id);
      if (i >= 0) return List.of(_elements)..[i] = d;
    }
    return [..._elements, d];
  }

  String encodeScene() => toScene().encode();

  // ─────────────────────────── herramientas ───────────────────────────

  BoardTool _tool = BoardTool.pen;
  ShapeKind _shapeKind = ShapeKind.rect;
  SelectionMode _selectionMode = SelectionMode.lasso;
  final Map<BoardTool, _ToolStyle> _styles = {
    BoardTool.pen: _ToolStyle(0, 4),
    BoardTool.highlighter: _ToolStyle(4, 20),
    BoardTool.eraser: _ToolStyle(0, 16),
    BoardTool.shape: _ToolStyle(0, 3),
    BoardTool.text: _ToolStyle(0, 24),
  };

  BoardTool get tool => _tool;
  ShapeKind get shapeKind => _shapeKind;
  SelectionMode get selectionMode => _selectionMode;

  set tool(BoardTool t) {
    if (t == _tool) return;
    finishTextEdit(restoreTool: false);
    _tool = t;
    if (t != BoardTool.select) _selection.clear();
    notifyListeners();
  }

  set shapeKind(ShapeKind k) {
    if (k == _shapeKind) return;
    _shapeKind = k;
    notifyListeners();
  }

  set selectionMode(SelectionMode m) {
    if (m == _selectionMode) return;
    _selectionMode = m;
    notifyListeners();
  }

  int colorIndexOf(BoardTool t) => _styles[t]?.colorIndex ?? 0;

  void setColorIndex(BoardTool t, int index) {
    final s = _styles[t];
    if (s == null || s.colorIndex == index) return;
    s.colorIndex = index.clamp(0, boardPalette.length - 1);
    if (t == BoardTool.text && _draft != null) {
      _draft = _draft!.copyWith(color: boardPalette[s.colorIndex].light);
      _draftRevision++;
    }
    notifyListeners();
  }

  /// Grosor (lápiz, marcador, formas), radio en píxeles de pantalla (borrador) o tamaño de letra (texto).
  double sizeOf(BoardTool t) => _styles[t]?.size ?? 4;

  void setSize(BoardTool t, double v) {
    final s = _styles[t];
    final spec = toolSizeSpecs[t];
    if (s == null || spec == null) return;
    final clamped = v.clamp(spec.min, spec.max).toDouble();
    if (clamped == s.size) return;
    s.size = clamped;
    if (t == BoardTool.text && _draft != null) {
      _draft = _draft!.copyWith(size: clamped);
      _draftRevision++;
    }
    notifyListeners();
  }

  /// Color canónico (variante clara) que se guarda para la herramienta; el marcador es semitransparente.
  Color colorFor(BoardTool t) {
    final base = boardPalette[colorIndexOf(t)].light;
    return t == BoardTool.highlighter ? BoardColors.withAlpha8(base, BoardColors.highlighterAlpha) : base;
  }

  // ─────────────────────────── selección ───────────────────────────

  final Set<String> _selection = <String>{};

  Set<String> get selection => UnmodifiableSetView(_selection);
  bool get hasSelection => _selection.isNotEmpty;

  /// Elementos seleccionados en orden Z.
  List<BoardElement> get selectedElements => [
    for (final e in _elements)
      if (_selection.contains(e.id)) e,
  ];

  void select(Iterable<String> ids) {
    final next = {
      for (final id in ids)
        if (byId(id) is! UnknownElement && indexOf(id) >= 0) id,
    };
    if (setEquals(next, _selection)) return;
    _selection
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    notifyListeners();
  }

  void selectAll() {
    _tool = BoardTool.select;
    select(_elements.map((e) => e.id));
    notifyListeners();
  }

  // ─────────────────────────── edición e historial ───────────────────────────

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;

  /// Aplica una operación y la registra en el historial.
  void commit(SceneEdit edit) {
    if (edit.isEmpty) return;
    _apply(edit);
    history.push(edit);
    _changed();
  }

  bool undo() {
    if (_draft != null) finishTextEdit();
    final e = history.undo();
    if (e == null) return false;
    _apply(e);
    _changed();
    return true;
  }

  bool redo() {
    if (_draft != null) finishTextEdit();
    final e = history.redo();
    if (e == null) return false;
    _apply(e);
    _changed();
    return true;
  }

  void _apply(SceneEdit e) {
    _elements = e.applyTo(_elements);
    _view = null;
    _indexById = null;
  }

  void _changed() {
    _sceneRevision++;
    _selection.removeWhere((id) => indexOf(id) < 0);
    notifyListeners();
  }

  /// Posición Z de un elemento nuevo. El marcador se coloca por debajo de la tinta: justo encima
  /// de la última imagen o del último trazo de marcador, para resaltar sin tapar lo escrito.
  int insertionIndexFor(BoardElement e) => _insertionIndexIn(_elements, e);

  static int _insertionIndexIn(List<BoardElement> list, BoardElement e) {
    if (e is StrokeElement && e.isHighlighter) {
      for (var i = list.length - 1; i >= 0; i--) {
        final x = list[i];
        if (x is ImageElement || (x is StrokeElement && x.isHighlighter)) return i + 1;
      }
      return 0;
    }
    return list.length;
  }

  void addElement(BoardElement e) => addElements([e]);

  /// Añade elementos (los trazos de marcador por debajo de la tinta; el resto encima) como una
  /// única operación deshacible.
  void addElements(List<BoardElement> items) {
    if (items.isEmpty) return;
    var working = _elements;
    for (final e in items) {
      working = SceneEdit(inserted: [IndexedElement(_insertionIndexIn(working, e), e)]).applyTo(working);
    }
    final ids = {for (final e in items) e.id};
    commit(SceneEdit(inserted: [
      for (var i = 0; i < working.length; i++)
        if (ids.contains(working[i].id)) IndexedElement(i, working[i]),
    ]));
  }

  void removeElements(Iterable<String> ids) {
    final set = ids.toSet();
    final removed = <IndexedElement>[
      for (var i = 0; i < _elements.length; i++)
        if (set.contains(_elements[i].id)) IndexedElement(i, _elements[i]),
    ];
    commit(SceneEdit(removed: removed));
  }

  /// Sustituye elementos existentes (mismo id, misma posición Z).
  void replaceElements(Iterable<BoardElement> after) {
    final changes = <ElementChange>[];
    for (final a in after) {
      final b = byId(a.id);
      if (b == null || identical(a, b)) continue;
      changes.add(ElementChange(b, a));
    }
    commit(SceneEdit(updated: changes));
  }

  void deleteSelection() {
    if (_selection.isEmpty) return;
    removeElements(_selection.toList());
  }

  /// Duplica la selección desplazada y selecciona las copias.
  void duplicateSelection({Offset offset = const Offset(24, 24)}) {
    final src = selectedElements;
    if (src.isEmpty) return;
    final copies = [
      for (final e in src) transformElement(e.withId(newId()), ElementTransform(translate: offset)),
    ];
    final start = _elements.length;
    commit(SceneEdit(inserted: [for (var i = 0; i < copies.length; i++) IndexedElement(start + i, copies[i])]));
    select(copies.map((e) => e.id));
  }

  /// Cambia el color de los elementos seleccionados (el marcador conserva su transparencia).
  void recolorSelection(int paletteIndex) {
    final color = boardPalette[paletteIndex.clamp(0, boardPalette.length - 1)].light;
    final out = <BoardElement>[];
    for (final e in selectedElements) {
      switch (e) {
        case StrokeElement():
          out.add(e.copyWith(color: BoardColors.withAlpha8(color, BoardColors.alphaOf(e.color))));
        case ShapeElement():
          out.add(e.copyWith(color: BoardColors.withAlpha8(color, BoardColors.alphaOf(e.color))));
        case TextElement():
          out.add(e.copyWith(color: color));
        case ImageElement():
        case UnknownElement():
          break;
      }
    }
    replaceElements(out);
  }

  /// Mueve/redimensiona la selección como una única operación deshacible.
  void transformSelection(ElementTransform t) {
    if (t.isIdentity) return;
    replaceElements([for (final e in selectedElements) transformElement(e, t)]);
  }

  /// Confirma la edición de un texto. Texto vacío: no crea nada o borra el existente.
  void commitText({TextElement? original, required TextElement edited}) {
    final empty = edited.text.trim().isEmpty;
    if (original == null) {
      if (!empty) addElement(edited);
      return;
    }
    if (indexOf(original.id) < 0) return;
    if (empty) {
      removeElements([original.id]);
    } else if (edited.text != original.text ||
        edited.color != original.color ||
        edited.size != original.size ||
        edited.w != original.w ||
        edited.x != original.x ||
        edited.y != original.y) {
      replaceElements([edited]);
    }
  }

  // ─────────────────────────── edición de texto en línea ───────────────────────────

  TextElement? _draft;
  TextElement? _draftOriginal;
  BoardTool? _toolBeforeText;
  int _draftRevision = 0;

  /// Texto que se está editando (borrador) o null.
  TextElement? get textDraft => _draft;

  /// Elemento original que se está editando (null si es un texto nuevo).
  TextElement? get textDraftOriginal => _draftOriginal;
  bool get isEditingText => _draft != null;

  /// Cambia con cada pulsación en el texto en edición (para el guardado automático).
  int get draftRevision => _draftRevision;

  /// Empieza a editar `draft` (nuevo) o el texto `original`. La herramienta pasa a Texto mientras
  /// dura la edición (para ajustar color y tamaño) y se restaura al terminar.
  void beginTextEdit(TextElement draft, {TextElement? original}) {
    finishTextEdit(restoreTool: false);
    if (_tool != BoardTool.text) {
      _toolBeforeText = _tool;
      _tool = BoardTool.text;
    } else {
      _toolBeforeText = null;
    }
    _selection.clear();
    final ts = _styles[BoardTool.text]!;
    final idx = BoardColors.paletteIndexOf(draft.color);
    if (idx >= 0) ts.colorIndex = idx;
    ts.size = draft.size.clamp(toolSizeSpecs[BoardTool.text]!.min, toolSizeSpecs[BoardTool.text]!.max).toDouble();
    _draft = draft;
    _draftOriginal = original;
    _draftRevision++;
    notifyListeners();
  }

  void updateTextDraft(String text) {
    final d = _draft;
    if (d == null || d.text == text) return;
    _draft = d.copyWith(text: text);
    _draftRevision++;
    notifyListeners();
  }

  /// Confirma el texto en edición como una operación deshacible.
  void finishTextEdit({bool restoreTool = true}) {
    final d = _draft;
    if (d == null) return;
    final o = _draftOriginal;
    final previous = _toolBeforeText;
    _draft = null;
    _draftOriginal = null;
    _toolBeforeText = null;
    if (restoreTool && previous != null) _tool = previous;
    _draftRevision++;
    final before = _sceneRevision;
    commitText(original: o, edited: d);
    if (before == _sceneRevision) notifyListeners();
  }

  @override
  void dispose() {
    viewport.dispose();
    super.dispose();
  }
}
