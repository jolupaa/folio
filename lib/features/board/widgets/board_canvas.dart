import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import '../controller/board_controller.dart';
import '../model/board_color.dart';
import '../model/elements.dart';
import '../model/geometry.dart';
import '../model/scene.dart';
import '../render/board_image_cache.dart';
import '../render/board_renderer.dart';
import '../render/stroke_outline.dart';

/// Radio de contacto (px lógicos) a partir del cual un toque se considera la palma cuando se usa lápiz.
const _palmRadius = 24.0;

/// Tolerancia de impacto en píxeles de pantalla.
const _hitSlop = 10.0;

/// Radio táctil del asa de redimensionado (objetivo de 48 dp).
const _handleTouchRadius = 24.0;
const _handleRadius = 9.0;

/// Lienzo infinito de la pizarra: dibujo con la herramienta activa, desplazamiento y zoom,
/// rechazo de palma con lápiz, selección y edición de texto en línea.
///
/// Capas: escena confirmada grabada en un `ui.Picture` (se reutiliza al desplazar/ampliar) y una
/// capa superior que solo repinta el trazo activo, el lazo, el borrador o la selección.
class BoardCanvas extends StatefulWidget {
  const BoardCanvas({
    super.key,
    required this.controller,
    required this.renderer,
    required this.images,
    this.focusNode,
  });

  final BoardController controller;
  final BoardRenderer renderer;
  final BoardImageCache images;
  final FocusNode? focusNode;

  @override
  State<BoardCanvas> createState() => BoardCanvasState();
}

class _Track {
  _Track(this.kind, this.position, this.time) : down = position, downTime = time;
  final PointerDeviceKind kind;
  Offset position;
  final Offset down;
  final Duration downTime;
  Duration time;
  double travel = 0;
}

class _NavBase {
  _NavBase(this.focal, this.span, this.viewport);
  final Offset focal;
  final double? span;
  final BoardViewport viewport;
}

class BoardCanvasState extends State<BoardCanvas> {
  BoardController get _c => widget.controller;
  BoardRenderer get _r => widget.renderer;

  late FocusNode _focus;
  bool _ownsFocus = false;

  // Punteros
  final _tracks = <int, _Track>{};
  final _ignored = <int>{};
  final _nav = <int>{};
  _NavBase? _navBase;
  bool _navTapCandidate = false;
  int? _toolPointer;
  int? _stylusPointer;
  bool _stylusMode = false;
  _Gesture? _gesture;

  // Toques para detectar doble toque
  Duration? _lastTapTime;
  Offset? _lastTapPos;

  // Capas
  final _sceneTick = _Tick();
  final _overlayTick = _Tick();
  ui.Picture? _picture;
  Object? _pictureKey;
  int _hiddenRevision = 0;
  int _lastSceneRevision = -1;

  // Trackpad
  BoardViewport? _panZoomStart;
  Offset? _panZoomFocal;

  // Texto en edición
  TextEditingController? _textCtrl;
  FocusNode? _textFocus;
  String? _textDraftId;
  Size _lastSize = Size.zero;

  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _ownsFocus = widget.focusNode == null;
    _focus = widget.focusNode ?? FocusNode(debugLabel: 'boardCanvas');
    _c.addListener(_onController);
    _c.viewport.addListener(_overlayTick.notify);
    widget.images.addListener(_sceneTick.notify);
    _lastSceneRevision = _c.sceneRevision;
  }

  @override
  void didUpdateWidget(BoardCanvas old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      old.controller.viewport.removeListener(_overlayTick.notify);
      _c.addListener(_onController);
      _c.viewport.addListener(_overlayTick.notify);
    }
    if (old.images != widget.images) {
      old.images.removeListener(_sceneTick.notify);
      widget.images.addListener(_sceneTick.notify);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    _c.viewport.removeListener(_overlayTick.notify);
    widget.images.removeListener(_sceneTick.notify);
    _picture?.dispose();
    _disposeTextEditing();
    if (_ownsFocus) _focus.dispose();
    _sceneTick.dispose();
    _overlayTick.dispose();
    super.dispose();
  }

  void _onController() {
    if (_c.sceneRevision != _lastSceneRevision) {
      _lastSceneRevision = _c.sceneRevision;
      // Un deshacer/rehacer durante un gesto invalida lo que se estaba moviendo o borrando.
      if (_gesture != null && _gesture!.dependsOnScene) _cancelGesture();
      _sceneTick.notify();
    }
    _syncTextEditing();
    _overlayTick.notify();
    if (mounted) setState(() {});
  }

  // ─────────────────────────── capas ───────────────────────────

  Set<String> get _hidden {
    final g = _gesture?.hidden ?? const <String>{};
    final editing = _c.textDraftOriginal?.id;
    if (editing == null) return g;
    return {...g, editing};
  }

  void _hiddenChanged() {
    _hiddenRevision++;
    _sceneTick.notify();
  }

  ui.Picture _scenePicture() {
    final key = (_c.sceneRevision, _hiddenRevision, _c.textDraftOriginal?.id, _r.themeRevision, widget.images.revision);
    if (key != _pictureKey || _picture == null) {
      _picture?.dispose();
      _picture = _r.record(_c.elements, hidden: _hidden);
      _pictureKey = key;
    }
    return _picture!;
  }

  // ─────────────────────────── punteros ───────────────────────────

  bool _isStylus(PointerDeviceKind k) => k == PointerDeviceKind.stylus || k == PointerDeviceKind.invertedStylus;

  void _onDown(PointerDownEvent e) {
    if (_c.isEditingText) {
      // Tocar fuera del texto en edición lo confirma; este contacto no dibuja.
      _c.finishTextEdit();
      _ignored.add(e.pointer);
      return;
    }
    if (!_focus.hasFocus) _focus.requestFocus();
    final track = _Track(e.kind, e.localPosition, e.timeStamp);

    if (_isStylus(e.kind)) {
      _stylusMode = true;
      if (_stylusPointer != null) {
        _ignored.add(e.pointer);
        return;
      }
      _tracks[e.pointer] = track;
      _stylusPointer = e.pointer;
      if (_gesture != null) _cancelGesture();
      _startTool(e, eraser: e.kind == PointerDeviceKind.invertedStylus);
      return;
    }

    if (e.kind == PointerDeviceKind.mouse) {
      _tracks[e.pointer] = track;
      if (e.buttons & kPrimaryButton != 0 && _gesture == null) {
        _startTool(e);
      } else {
        _addNav(e.pointer);
      }
      return;
    }

    // Dedo (u otro dispositivo táctil).
    if (_stylusPointer != null || (_stylusMode && e.radiusMajor > _palmRadius)) {
      _ignored.add(e.pointer);
      return;
    }
    _tracks[e.pointer] = track;
    if (_stylusMode || _nav.isNotEmpty) {
      _addNav(e.pointer);
      return;
    }
    final drawing = _toolPointer;
    if (drawing != null) {
      // Segundo dedo: se descarta lo que hacía el primero y se pasa a desplazar/ampliar.
      _cancelGesture();
      _toolPointer = null;
      _addNav(drawing);
      _addNav(e.pointer);
      return;
    }
    _startTool(e);
  }

  void _onMove(PointerMoveEvent e) {
    final t = _tracks[e.pointer];
    if (t == null || _ignored.contains(e.pointer)) return;
    t.travel += (e.localPosition - t.position).distance;
    t.position = e.localPosition;
    t.time = e.timeStamp;
    if (e.pointer == _toolPointer) {
      _gesture?.update(_c.viewport.value.toCanvas(e.localPosition), e, t);
      _overlayTick.notify();
    } else if (_nav.contains(e.pointer)) {
      _updateNav();
    }
  }

  void _onUp(PointerUpEvent e) => _release(e.pointer, e, cancelled: false);

  void _onCancel(PointerCancelEvent e) => _release(e.pointer, e, cancelled: true);

  void _release(int pointer, PointerEvent e, {required bool cancelled}) {
    if (_ignored.remove(pointer)) {
      _tracks.remove(pointer);
      return;
    }
    final t = _tracks.remove(pointer);
    if (pointer == _stylusPointer) _stylusPointer = null;
    if (pointer == _toolPointer) {
      _toolPointer = null;
      final g = _gesture;
      _gesture = null;
      if (g != null) {
        if (cancelled) {
          g.cancel();
        } else {
          g.end(t);
        }
        if (g.hidden.isNotEmpty) _hiddenChanged();
      }
      _overlayTick.notify();
      return;
    }
    if (_nav.remove(pointer)) {
      final wasTap = _navTapCandidate && t != null && !cancelled && _isTap(t);
      if (_nav.isEmpty) {
        _navBase = null;
        _navTapCandidate = false;
        if (wasTap) _handleTap(_c.viewport.value.toCanvas(t.position), t);
      } else {
        _navTapCandidate = false;
        _rebaseNav();
      }
    }
  }

  bool _isTap(_Track t) {
    final slop = t.kind == PointerDeviceKind.touch ? kTouchSlop : 6.0;
    return t.travel < slop && (t.time - t.downTime) < const Duration(milliseconds: 400);
  }

  // ─────────────────────────── navegación ───────────────────────────

  void _addNav(int pointer) {
    _nav.add(pointer);
    _navTapCandidate = _nav.length == 1 && (_tracks[pointer]?.kind == PointerDeviceKind.touch);
    _rebaseNav();
  }

  (Offset, double?) _navMetrics() {
    var sum = Offset.zero;
    final pts = <Offset>[];
    for (final p in _nav) {
      final t = _tracks[p];
      if (t == null) continue;
      pts.add(t.position);
      sum += t.position;
    }
    if (pts.isEmpty) return (Offset.zero, null);
    final focal = sum / pts.length.toDouble();
    if (pts.length < 2) return (focal, null);
    var span = 0.0;
    for (final p in pts) {
      span += (p - focal).distance;
    }
    return (focal, span / pts.length);
  }

  void _rebaseNav() {
    if (_nav.isEmpty) {
      _navBase = null;
      return;
    }
    final (focal, span) = _navMetrics();
    _navBase = _NavBase(focal, span, _c.viewport.value);
  }

  void _updateNav() {
    final base = _navBase;
    if (base == null) return;
    final (focal, span) = _navMetrics();
    var scale = base.viewport.scale;
    if (base.span != null && span != null && base.span! > 1) {
      scale = BoardViewport.clampScale(base.viewport.scale * span / base.span!);
    }
    final anchor = base.viewport.toCanvas(base.focal);
    _c.viewport.value = BoardViewport(x: anchor.dx - focal.dx / scale, y: anchor.dy - focal.dy / scale, scale: scale);
  }

  void _onSignal(PointerSignalEvent e) {
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final vp = _c.viewport.value;
      if (event is PointerScrollEvent) {
        final keys = HardwareKeyboard.instance;
        if (keys.isControlPressed || keys.isMetaPressed) {
          _c.viewport.value = vp.zoomAt(event.localPosition, vp.scale * math.exp(-event.scrollDelta.dy / 300));
        } else {
          final d = keys.isShiftPressed ? Offset(event.scrollDelta.dy, event.scrollDelta.dx) : event.scrollDelta;
          _c.viewport.value = vp.panBy(-d);
        }
      } else if (event is PointerScaleEvent) {
        _c.viewport.value = vp.zoomAt(event.localPosition, vp.scale * event.scale);
      }
    });
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _panZoomStart = _c.viewport.value;
    _panZoomFocal = e.localPosition;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    final start = _panZoomStart, focal0 = _panZoomFocal;
    if (start == null || focal0 == null) return;
    final scale = BoardViewport.clampScale(start.scale * e.scale);
    final focal = focal0 + e.localPan;
    final anchor = start.toCanvas(focal0);
    _c.viewport.value = BoardViewport(x: anchor.dx - focal.dx / scale, y: anchor.dy - focal.dy / scale, scale: scale);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent e) {
    _panZoomStart = null;
    _panZoomFocal = null;
  }

  /// Zoom desde los controles (100 %, ampliar, reducir) centrado en la vista.
  void zoomTo(double scale) {
    final center = Offset(_size.width / 2, _size.height / 2);
    _c.viewport.value = _c.viewport.value.zoomAt(center, scale);
  }

  // ─────────────────────────── herramientas ───────────────────────────

  void _startTool(PointerDownEvent e, {bool eraser = false}) {
    _toolPointer = e.pointer;
    final vp = _c.viewport.value;
    final p = vp.toCanvas(e.localPosition);
    final tool = eraser ? BoardTool.eraser : _c.tool;
    final g = switch (tool) {
      BoardTool.pen || BoardTool.highlighter => _InkGesture(this, tool, p, e),
      BoardTool.eraser => _EraserGesture(this, p, e.localPosition),
      BoardTool.shape => _ShapeGesture(this, p),
      BoardTool.text => _TapGesture(this),
      BoardTool.select => _selectGestureAt(p, e.localPosition),
    };
    _gesture = g;
    if (g.hidden.isNotEmpty) _hiddenChanged();
    _overlayTick.notify();
  }

  _Gesture _selectGestureAt(Offset p, Offset screen) {
    if (_c.hasSelection) {
      final bounds = selectionScreenRect();
      if (bounds != null) {
        if ((screen - bounds.bottomRight).distance <= _handleTouchRadius) return _ResizeGesture(this, p);
        if (bounds.inflate(4).contains(screen)) return _MoveGesture(this, p);
      }
    }
    final hit = topmostAt(_c.elements, p, _hitSlop / _c.viewport.value.scale, textHeight: _r.textHeight);
    if (hit != null) {
      _c.select([hit.id]);
      return _MoveGesture(this, p);
    }
    return _LassoGesture(this, p, _c.selectionMode);
  }

  void _cancelGesture() {
    final g = _gesture;
    _gesture = null;
    if (g == null) return;
    g.cancel();
    if (g.hidden.isNotEmpty) _hiddenChanged();
    _overlayTick.notify();
  }

  void _handleTap(Offset canvasPoint, _Track t) {
    final now = t.time;
    final isDouble = _lastTapTime != null &&
        _lastTapPos != null &&
        now - _lastTapTime! < const Duration(milliseconds: 350) &&
        (t.position - _lastTapPos!).distance < 32;
    _lastTapTime = isDouble ? null : now;
    _lastTapPos = t.position;
    final tol = _hitSlop / _c.viewport.value.scale;
    switch (_c.tool) {
      case BoardTool.text:
        final hit = _topmostText(canvasPoint, tol);
        if (hit != null) {
          _c.beginTextEdit(hit, original: hit);
        } else {
          _createText(canvasPoint);
        }
      case BoardTool.select:
        final hit = topmostAt(_c.elements, canvasPoint, tol, textHeight: _r.textHeight);
        if (isDouble && hit is TextElement) {
          _c.beginTextEdit(hit, original: hit);
        } else if (hit != null) {
          _c.select([hit.id]);
        } else {
          _c.clearSelection();
        }
      default:
        break;
    }
  }

  TextElement? _topmostText(Offset p, double tol) {
    final els = _c.elements;
    for (var i = els.length - 1; i >= 0; i--) {
      final e = els[i];
      if (e is TextElement && hitTestElement(e, p, tol, textHeight: _r.textHeight)) return e;
    }
    return null;
  }

  void _createText(Offset p) {
    final vp = _c.viewport.value;
    final size = _c.sizeOf(BoardTool.text);
    final visible = vp.visibleRect(_size);
    final available = visible.right - p.dx - 16 / vp.scale;
    final w = roundCoord(math.max(120, math.min(320, available)));
    _c.beginTextEdit(
      TextElement(
        id: _c.newId(),
        x: roundCoord(p.dx),
        y: roundCoord(p.dy - size * kBoardTextLineHeight / 2),
        w: w,
        text: '',
        color: _c.colorFor(BoardTool.text),
        size: size,
      ),
    );
  }

  /// Rectángulo de la selección en pantalla (null si no hay selección dibujable).
  Rect? selectionScreenRect() {
    final b = unionBounds(_c.selectedElements, textHeight: _r.textHeight);
    if (b == null) return null;
    return _c.viewport.value.rectToScreen(b).inflate(6);
  }

  // ─────────────────────────── teclado ───────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (FocusManager.instance.primaryFocus != _focus) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mod = keys.isControlPressed || keys.isMetaPressed;
    final k = event.logicalKey;
    if (mod && k == LogicalKeyboardKey.keyZ) {
      keys.isShiftPressed ? _c.redo() : _c.undo();
      return KeyEventResult.handled;
    }
    if (mod && k == LogicalKeyboardKey.keyY) {
      _c.redo();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (mod && k == LogicalKeyboardKey.keyA) {
      _c.selectAll();
      return KeyEventResult.handled;
    }
    if (mod && k == LogicalKeyboardKey.keyD && _c.hasSelection) {
      _c.duplicateSelection();
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && _c.hasSelection) {
      _c.deleteSelection();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _c.hasSelection) {
      _c.clearSelection();
      return KeyEventResult.handled;
    }
    if (mod || keys.isAltPressed) return KeyEventResult.ignored;
    final tool = switch (k) {
      LogicalKeyboardKey.keyP => BoardTool.pen,
      LogicalKeyboardKey.keyM => BoardTool.highlighter,
      LogicalKeyboardKey.keyE => BoardTool.eraser,
      LogicalKeyboardKey.keyV => BoardTool.select,
      LogicalKeyboardKey.keyT => BoardTool.text,
      LogicalKeyboardKey.keyS => BoardTool.shape,
      _ => null,
    };
    if (tool == null) return KeyEventResult.ignored;
    _c.tool = tool;
    return KeyEventResult.handled;
  }

  // ─────────────────────────── texto en línea ───────────────────────────

  void _syncTextEditing() {
    final draft = _c.textDraft;
    if (draft == null) {
      if (_textCtrl != null) {
        _disposeTextEditing();
        if (mounted) _focus.requestFocus();
      }
      return;
    }
    if (_textDraftId == draft.id && _textCtrl != null) return;
    _disposeTextEditing();
    _textDraftId = draft.id;
    _textCtrl = TextEditingController(text: draft.text)..addListener(_onTextChanged);
    _textFocus = FocusNode(debugLabel: 'boardText');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _textFocus?.requestFocus();
        _ensureEditVisible();
      }
    });
  }

  void _onTextChanged() {
    final t = _textCtrl?.text;
    if (t != null) _c.updateTextDraft(t);
  }

  void _disposeTextEditing() {
    final ctrl = _textCtrl, focus = _textFocus;
    _textCtrl = null;
    _textFocus = null;
    _textDraftId = null;
    if (ctrl == null && focus == null) return;
    ctrl?.removeListener(_onTextChanged);
    // Se liberan tras el fotograma: el TextField aún puede estar montado en este.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ctrl?.dispose();
      focus?.dispose();
    });
  }

  /// Si el teclado tapa el texto en edición, desplaza la vista para mostrarlo.
  void _ensureEditVisible() {
    final d = _c.textDraft;
    if (d == null || _size.isEmpty) return;
    final vp = _c.viewport.value;
    final top = vp.toScreen(Offset(d.x, d.y)).dy;
    final lineH = d.size * kBoardTextLineHeight * vp.scale;
    final limit = _size.height - lineH * 2 - 16;
    if (top >= 8 && top <= limit) return;
    final targetTop = math.max(16.0, _size.height * 0.25);
    _c.viewport.value = BoardViewport(x: vp.x, y: d.y - targetTop / vp.scale, scale: vp.scale);
  }

  // ─────────────────────────── construcción ───────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final count = _c.elements.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        if (_size != _lastSize) {
          final shrunk = _size.height < _lastSize.height;
          _lastSize = _size;
          if (shrunk && _c.isEditingText) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _ensureEditVisible();
            });
          }
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              container: true,
              label: 'Lienzo de la pizarra',
              value: count == 0 ? 'Vacío' : (count == 1 ? '1 elemento' : '$count elementos'),
              hint: _stylusMode
                  ? 'Dibuja con el lápiz; desplaza y amplía con los dedos'
                  : 'Dibuja con un dedo; desplaza y amplía con dos',
              child: Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: _onKey,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: _onCancel,
                  onPointerSignal: _onSignal,
                  onPointerPanZoomStart: _onPanZoomStart,
                  onPointerPanZoomUpdate: _onPanZoomUpdate,
                  onPointerPanZoomEnd: _onPanZoomEnd,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: colors.background),
                      RepaintBoundary(
                        child: CustomPaint(
                          isComplex: true,
                          painter: _ScenePainter(this, _r.themeRevision, Listenable.merge([_sceneTick, _c.viewport])),
                        ),
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          willChange: true,
                          painter: _OverlayPainter(this, colors, _overlayTick),
                        ),
                      ),
                      if (count == 0 && !_c.isEditingText) const _EmptyHint(),
                    ],
                  ),
                ),
              ),
            ),
            if (_c.textDraft != null && _textCtrl != null) _buildTextOverlay(context),
          ],
        );
      },
    );
  }

  Widget _buildTextOverlay(BuildContext context) {
    final colors = context.colors;
    return ValueListenableBuilder<BoardViewport>(
      valueListenable: _c.viewport,
      builder: (context, vp, _) {
        final d = _c.textDraft;
        if (d == null || _textCtrl == null) return const SizedBox.shrink();
        final pos = vp.toScreen(Offset(d.x, d.y));
        final style = _r.theme.textStyleFor(d);
        return Positioned(
          left: pos.dx,
          top: pos.dy,
          child: Transform.scale(
            scale: vp.scale,
            alignment: Alignment.topLeft,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
              child: CustomPaint(
                foregroundPainter: _EditFramePainter(colors.accent, vp.scale),
                child: SizedBox(
                  width: d.w,
                  child: Material(
                    type: MaterialType.transparency,
                    child: TextField(
                      controller: _textCtrl,
                      focusNode: _textFocus,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      style: style,
                      cursorColor: colors.accent,
                      decoration: InputDecoration.collapsed(
                        hintText: 'Escribe aquí',
                        hintStyle: style.copyWith(color: colors.textTertiary),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Tick extends ChangeNotifier {
  void notify() => notifyListeners();
}

// ─────────────────────────── pintores ───────────────────────────

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.state, this.themeRevision, Listenable repaint) : super(repaint: repaint);
  final BoardCanvasState state;
  final int themeRevision;

  @override
  void paint(Canvas canvas, Size size) {
    final vp = state._c.viewport.value;
    final picture = state._scenePicture();
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(vp.scale)
      ..translate(-vp.x, -vp.y)
      ..drawPicture(picture)
      ..restore();
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.state != state || old.themeRevision != themeRevision;
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.state, this.colors, Listenable repaint) : super(repaint: repaint);
  final BoardCanvasState state;
  final FolioColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final vp = state._c.viewport.value;
    final g = state._gesture;
    canvas.clipRect(Offset.zero & size);
    if (g != null) {
      canvas
        ..save()
        ..scale(vp.scale)
        ..translate(-vp.x, -vp.y);
      g.paintCanvas(canvas, vp, colors);
      canvas.restore();
      g.paintScreen(canvas, vp, colors);
    }
    if (state._c.hasSelection && (g == null || g.showsSelection)) {
      final rect = g?.selectionRect() ?? state.selectionScreenRect();
      if (rect != null) _paintSelection(canvas, rect);
    }
  }

  void _paintSelection(Canvas canvas, Rect r) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(6)),
      Paint()..color = colors.accentSoft,
    );
    _dashedRect(
      canvas,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = colors.accent,
    );
    final h = r.bottomRight;
    canvas
      ..drawCircle(h, _handleRadius, Paint()..color = colors.surface)
      ..drawCircle(
        h,
        _handleRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.accent,
      );
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => old.state != state || old.colors != colors;
}

void _dashedRect(Canvas canvas, Rect r, Paint paint, {double dash = 6, double gap = 4}) {
  void line(Offset a, Offset b) {
    final len = (b - a).distance;
    if (len == 0) return;
    final dir = (b - a) / len;
    var d = 0.0;
    while (d < len) {
      final e = math.min(d + dash, len);
      canvas.drawLine(a + dir * d, a + dir * e, paint);
      d = e + gap;
    }
  }

  line(r.topLeft, r.topRight);
  line(r.topRight, r.bottomRight);
  line(r.bottomRight, r.bottomLeft);
  line(r.bottomLeft, r.topLeft);
}

class _EditFramePainter extends CustomPainter {
  _EditFramePainter(this.color, this.scale);
  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 6 / scale;
    _dashedRect(
      canvas,
      (Offset.zero & size).inflate(pad),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 / scale
        ..color = color.withValues(alpha: 0.7),
      dash: 6 / scale,
      gap: 4 / scale,
    );
  }

  @override
  bool shouldRepaint(_EditFramePainter old) => old.color != color || old.scale != scale;
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xxl, Insets.xxl, Insets.xxl, 120),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
                  child: Icon(Icons.gesture_rounded, size: 30, color: c.accent),
                ),
                const SizedBox(height: Insets.md),
                Text('Pizarra en blanco', style: context.text.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: Insets.xs),
                Text(
                  'Dibuja con un dedo o con el lápiz. Usa dos dedos para moverte y ampliar.',
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── gestos de herramienta ───────────────────────────

abstract class _Gesture {
  _Gesture(this.s);
  final BoardCanvasState s;

  /// Elementos que no se dibujan en la escena mientras dura el gesto.
  Set<String> get hidden => const {};

  /// Si un cambio de la escena (deshacer) debe cancelar el gesto.
  bool get dependsOnScene => false;

  /// Si se dibuja el marco de selección durante el gesto.
  bool get showsSelection => true;

  /// Marco de selección alternativo (p. ej. durante el movimiento).
  Rect? selectionRect() => null;

  void update(Offset p, PointerEvent e, _Track t);
  void end(_Track? t);
  void cancel() {}
  void paintCanvas(Canvas canvas, BoardViewport vp, FolioColors colors) {}
  void paintScreen(Canvas canvas, BoardViewport vp, FolioColors colors) {}
}

/// Lápiz y marcador: presión real del lápiz o simulada por la velocidad con el dedo/ratón.
class _InkGesture extends _Gesture {
  _InkGesture(super.s, this.tool, Offset p, PointerDownEvent e)
    : color = s._c.colorFor(tool),
      width = s._c.sizeOf(tool),
      _realPressure = e.pressureMax > e.pressureMin && s._isStylus(e.kind),
      _lastScreen = e.localPosition,
      _lastTime = e.timeStamp {
    _add(p, _realPressure ? _normalized(e) : 0.5);
  }

  final BoardTool tool;
  final Color color;
  final double width;
  final bool _realPressure;
  final _pts = <double>[];
  Offset _lastScreen;
  Duration _lastTime;
  double _simulated = 0.5;
  Float64List? _buffer;
  Path? _preview;

  bool get _highlighter => tool == BoardTool.highlighter;

  static double _normalized(PointerEvent e) {
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / range).clamp(0.05, 1.0);
  }

  void _add(Offset p, double pressure) {
    _pts
      ..add(roundCoord(p.dx))
      ..add(roundCoord(p.dy))
      ..add(roundPressure(pressure));
    _preview = null;
  }

  @override
  void update(Offset p, PointerEvent e, _Track t) {
    final screenDist = (e.localPosition - _lastScreen).distance;
    if (screenDist < 0.75) return;
    double pressure;
    if (_realPressure) {
      pressure = _normalized(e);
    } else {
      final dtMs = math.max(1, (e.timeStamp - _lastTime).inMicroseconds / 1000.0);
      final speed = screenDist / dtMs; // px/ms
      final target = 0.68 - (math.min(speed, 3.0) / 3.0) * 0.38;
      _simulated += (target - _simulated) * 0.3;
      pressure = _simulated;
    }
    _lastScreen = e.localPosition;
    _lastTime = e.timeStamp;
    _add(p, pressure);
  }

  @override
  void end(_Track? t) {
    if (_pts.isEmpty) return;
    s._c.addElement(
      StrokeElement(
        id: s._c.newId(),
        tool: _highlighter ? StrokeTools.highlighter : StrokeTools.pen,
        color: color,
        width: width,
        points: Float64List.fromList(_pts),
      ),
    );
  }

  @override
  void paintCanvas(Canvas canvas, BoardViewport vp, FolioColors colors) {
    if (_pts.isEmpty) return;
    if (_preview == null) {
      final buf = (_buffer == null || _buffer!.length < _pts.length)
          ? (_buffer = Float64List(math.max(_pts.length * 2, 300)))
          : _buffer!;
      buf.setRange(0, _pts.length, _pts);
      _preview = outlineToPath(
        strokeOutline(buf, width: width, highlighter: _highlighter, complete: false, count: _pts.length ~/ 3),
      );
    }
    canvas.drawPath(
      _preview!,
      Paint()
        ..isAntiAlias = true
        ..color = BoardColors.display(color, s._r.theme.brightness),
    );
  }
}

/// Borrador: borra trazos y formas completos al tocarlos; se confirma al levantar.
class _EraserGesture extends _Gesture {
  _EraserGesture(super.s, Offset p, this._screen) : _last = p {
    _hit(p, p);
  }

  final _erased = <String>{};
  Offset _last;
  Offset _screen;

  double get _radiusScreen => s._c.sizeOf(BoardTool.eraser);

  @override
  Set<String> get hidden => _erased;

  @override
  bool get dependsOnScene => true;

  void _hit(Offset from, Offset to) {
    final r = _radiusScreen / s._c.viewport.value.scale;
    final hits = eraserHits(s._c.elements, from, to, r, skip: _erased);
    if (hits.isNotEmpty) {
      _erased.addAll(hits);
      s._hiddenChanged();
    }
  }

  @override
  void update(Offset p, PointerEvent e, _Track t) {
    _hit(_last, p);
    _last = p;
    _screen = e.localPosition;
  }

  @override
  void end(_Track? t) {
    if (_erased.isNotEmpty) s._c.removeElements(_erased.toList());
  }

  @override
  void cancel() => _erased.clear();

  @override
  void paintScreen(Canvas canvas, BoardViewport vp, FolioColors colors) {
    canvas
      ..drawCircle(_screen, _radiusScreen, Paint()..color = colors.textPrimary.withValues(alpha: 0.08))
      ..drawCircle(
        _screen,
        _radiusScreen,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = colors.textSecondary,
      );
  }
}

/// Formas: rectángulo, elipse, línea o flecha arrastrando desde el punto inicial.
class _ShapeGesture extends _Gesture {
  _ShapeGesture(super.s, this.start) : current = start, kind = s._c.shapeKind;

  final Offset start;
  Offset current;
  final ShapeKind kind;

  ShapeElement _element(String id) {
    final color = s._c.colorFor(BoardTool.shape);
    final width = s._c.sizeOf(BoardTool.shape);
    if (kind.isLinear) {
      return ShapeElement(
        id: id,
        shape: kind,
        x: roundCoord(start.dx),
        y: roundCoord(start.dy),
        w: roundCoord(current.dx - start.dx),
        h: roundCoord(current.dy - start.dy),
        color: color,
        width: width,
      );
    }
    final r = Rect.fromPoints(start, current);
    return ShapeElement(
      id: id,
      shape: kind,
      x: roundCoord(r.left),
      y: roundCoord(r.top),
      w: roundCoord(r.width),
      h: roundCoord(r.height),
      color: color,
      width: width,
    );
  }

  @override
  void update(Offset p, PointerEvent e, _Track t) => current = p;

  @override
  void end(_Track? t) {
    final screenSize = (current - start).distance * s._c.viewport.value.scale;
    if (screenSize < 4) return;
    s._c.addElement(_element(s._c.newId()));
  }

  @override
  void paintCanvas(Canvas canvas, BoardViewport vp, FolioColors colors) {
    if (current == start) return;
    s._r.paintShape(canvas, _element('preview'));
  }
}

/// Texto: un toque crea o edita.
class _TapGesture extends _Gesture {
  _TapGesture(super.s);

  @override
  void update(Offset p, PointerEvent e, _Track t) {}

  @override
  void end(_Track? t) {
    if (t != null && s._isTap(t)) s._handleTap(s._c.viewport.value.toCanvas(t.position), t);
  }
}

/// Mover la selección arrastrando dentro de su marco. Sin movimiento, es un toque.
class _MoveGesture extends _Gesture {
  _MoveGesture(super.s, this.start);

  final Offset start;
  Offset _delta = Offset.zero;
  bool _moving = false;
  Set<String> _ids = const {};
  List<BoardElement> _elements = const [];

  @override
  Set<String> get hidden => _ids;

  @override
  bool get dependsOnScene => true;

  @override
  Rect? selectionRect() {
    final r = s.selectionScreenRect();
    if (r == null || !_moving) return r;
    return r.shift(_delta * s._c.viewport.value.scale);
  }

  @override
  void update(Offset p, PointerEvent e, _Track t) {
    if (!_moving) {
      final slop = t.kind == PointerDeviceKind.touch ? kTouchSlop / 2 : 4.0;
      if (t.travel < slop) return;
      _moving = true;
      _ids = {...s._c.selection};
      _elements = s._c.selectedElements;
      s._hiddenChanged();
    }
    _delta = p - start;
  }

  @override
  void end(_Track? t) {
    if (!_moving) {
      if (t != null && s._isTap(t)) s._handleTap(s._c.viewport.value.toCanvas(t.position), t);
      return;
    }
    final d = Offset(roundCoord(_delta.dx), roundCoord(_delta.dy));
    if (d == Offset.zero) return;
    final tr = ElementTransform(translate: d);
    final after = <BoardElement>[];
    for (final e in _elements) {
      final moved = transformElement(e, tr);
      if (e is StrokeElement && moved is StrokeElement) s._r.seedTranslated(e, moved, d);
      after.add(moved);
    }
    s._c.replaceElements(after);
  }

  @override
  void cancel() => _ids = const {};

  @override
  void paintCanvas(Canvas canvas, BoardViewport vp, FolioColors colors) {
    if (!_moving) return;
    canvas
      ..save()
      ..translate(_delta.dx, _delta.dy);
    for (final e in _elements) {
      s._r.paintElement(canvas, e);
    }
    canvas.restore();
  }
}

/// Redimensionar con el asa inferior derecha. Proporcional salvo una única forma.
class _ResizeGesture extends _Gesture {
  _ResizeGesture(super.s, Offset p) {
    _elements = s._c.selectedElements;
    final b = unionBounds(_elements, textHeight: s._r.textHeight)!;
    anchor = b.topLeft;
    corner = b.bottomRight;
    grab = corner - p;
    uniform = !(_elements.length == 1 && _elements.first is ShapeElement);
    _ids = {...s._c.selection};
  }

  late final List<BoardElement> _elements;
  late final Offset anchor, corner, grab;
  late final bool uniform;
  Set<String> _ids = const {};
  double sx = 1, sy = 1;

  @override
  Set<String> get hidden => _ids;

  @override
  bool get dependsOnScene => true;

  @override
  Rect? selectionRect() {
    final vp = s._c.viewport.value;
    final a = vp.toScreen(anchor);
    final c = vp.toScreen(anchor + Offset((corner.dx - anchor.dx) * sx, (corner.dy - anchor.dy) * sy));
    return Rect.fromPoints(a, c).inflate(6);
  }

  @override
  void update(Offset p, PointerEvent e, _Track t) {
    final target = p + grab;
    final v = target - anchor;
    final c = corner - anchor;
    if (uniform) {
      final len2 = c.dx * c.dx + c.dy * c.dy;
      final f = len2 <= 0 ? 1.0 : (v.dx * c.dx + v.dy * c.dy) / len2;
      sx = sy = f.clamp(0.05, 40.0);
    } else {
      sx = c.dx.abs() < 1 ? 1 : (v.dx / c.dx).clamp(0.05, 40.0);
      sy = c.dy.abs() < 1 ? 1 : (v.dy / c.dy).clamp(0.05, 40.0);
    }
  }

  @override
  void end(_Track? t) {
    if (sx == 1 && sy == 1) return;
    s._c.transformSelection(ElementTransform(sx: sx, sy: sy, anchor: anchor));
  }

  @override
  void cancel() => _ids = const {};

  @override
  void paintCanvas(Canvas canvas, BoardViewport vp, FolioColors colors) {
    canvas
      ..save()
      ..translate(anchor.dx, anchor.dy)
      ..scale(sx, sy)
      ..translate(-anchor.dx, -anchor.dy);
    for (final e in _elements) {
      s._r.paintElement(canvas, e);
    }
    canvas.restore();
  }
}

/// Selección por lazo libre o rectángulo. Sin arrastre, un toque en vacío deselecciona.
class _LassoGesture extends _Gesture {
  _LassoGesture(super.s, this.start, this.mode) : current = start {
    s._c.clearSelection();
    _points.add(start);
  }

  final Offset start;
  final SelectionMode mode;
  Offset current;
  final _points = <Offset>[];

  @override
  bool get showsSelection => false;

  List<Offset> get _polygon => mode == SelectionMode.rect ? rectPolygon(Rect.fromPoints(start, current)) : _points;

  @override
  void update(Offset p, PointerEvent e, _Track t) {
    current = p;
    if (mode == SelectionMode.lasso && (p - _points.last).distance * s._c.viewport.value.scale > 2) _points.add(p);
  }

  @override
  void end(_Track? t) {
    if (t != null && s._isTap(t)) {
      s._handleTap(s._c.viewport.value.toCanvas(t.position), t);
      return;
    }
    final ids = elementsInPolygon(s._c.elements, _polygon, textHeight: s._r.textHeight);
    s._c.select(ids);
  }

  @override
  void paintCanvas(Canvas canvas, BoardViewport vp, FolioColors colors) {
    final poly = _polygon;
    if (poly.length < 2) return;
    final path = Path()..addPolygon(poly, mode == SelectionMode.rect);
    if (mode == SelectionMode.lasso) path.close();
    canvas
      ..drawPath(path, Paint()..color = colors.accentSoft)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / vp.scale
          ..strokeJoin = StrokeJoin.round
          ..color = colors.accent,
      );
  }
}
