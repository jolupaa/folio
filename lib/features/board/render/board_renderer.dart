import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Brightness;
import 'package:flutter/painting.dart';

import '../model/board_color.dart';
import '../model/elements.dart';
import '../model/geometry.dart';
import 'board_image_cache.dart';
import 'stroke_outline.dart';

/// Colores del tema que necesita el dibujo de la escena.
class BoardPaintTheme {
  const BoardPaintTheme({
    required this.brightness,
    required this.textStyle,
    required this.placeholderFill,
    required this.placeholderStroke,
    required this.placeholderIcon,
  });

  final Brightness brightness;

  /// Estilo base de los textos (familia del sistema); el tamaño y el color los da cada elemento.
  final TextStyle textStyle;
  final Color placeholderFill;
  final Color placeholderStroke;
  final Color placeholderIcon;

  TextStyle textStyleFor(TextElement e) => textStyle.copyWith(
    fontSize: e.size,
    height: kBoardTextLineHeight,
    color: BoardColors.display(e.color, brightness),
    letterSpacing: 0,
  );

  @override
  bool operator ==(Object other) =>
      other is BoardPaintTheme &&
      other.brightness == brightness &&
      other.textStyle == textStyle &&
      other.placeholderFill == placeholderFill &&
      other.placeholderStroke == placeholderStroke &&
      other.placeholderIcon == placeholderIcon;

  @override
  int get hashCode => Object.hash(brightness, textStyle, placeholderFill, placeholderStroke, placeholderIcon);
}

class _TextLayout {
  _TextLayout(this.painter, this.theme);
  final TextPainter painter;
  final BoardPaintTheme theme;
}

/// Dibuja elementos de la escena con cachés por elemento (contorno de trazos, maquetación de
/// textos) y graba la escena confirmada en un `ui.Picture` reutilizable entre fotogramas.
class BoardRenderer {
  BoardRenderer({required this.images, required BoardPaintTheme theme}) : _theme = theme;

  final BoardImageCache images;
  BoardPaintTheme _theme;
  final _paths = Expando<Path>('strokePath');
  final _texts = <TextElement, _TextLayout>{};
  int _themeRevision = 0;

  BoardPaintTheme get theme => _theme;
  int get themeRevision => _themeRevision;

  set theme(BoardPaintTheme t) {
    if (t == _theme) return;
    _theme = t;
    _themeRevision++;
  }

  // ─────────────────────────── cachés ───────────────────────────

  Path strokePath(StrokeElement s) => _paths[s] ??= outlineToPath(
    strokeOutline(s.points, width: s.width, highlighter: s.isHighlighter),
  );

  /// Reutiliza el contorno de `from` desplazado para `to` (mover sin recalcular el suavizado).
  void seedTranslated(StrokeElement from, StrokeElement to, Offset delta) {
    final p = _paths[from];
    if (p != null && _paths[to] == null) _paths[to] = p.shift(delta);
  }

  TextPainter textPainter(TextElement e) {
    final cached = _texts[e];
    if (cached != null && identical(cached.theme, _theme)) return cached.painter;
    cached?.painter.dispose();
    final painter = TextPainter(
      text: TextSpan(text: e.text.isEmpty ? ' ' : e.text, style: _theme.textStyleFor(e)),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: math.max(1, e.w));
    _texts[e] = _TextLayout(painter, _theme);
    return painter;
  }

  double textHeight(TextElement e) => textPainter(e).height;

  // ─────────────────────────── dibujo ───────────────────────────

  /// Graba los elementos (salvo `hidden`) en coordenadas de lienzo. Libera de paso las
  /// maquetaciones de texto de elementos que ya no están en la escena.
  ui.Picture record(List<BoardElement> elements, {Set<String> hidden = const {}}) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final e in elements) {
      if (hidden.isNotEmpty && hidden.contains(e.id)) continue;
      paintElement(canvas, e);
    }
    _pruneTexts(elements);
    return recorder.endRecording();
  }

  void _pruneTexts(List<BoardElement> elements) {
    if (_texts.length <= 64) return;
    final live = Set<TextElement>.identity()..addAll(elements.whereType<TextElement>());
    _texts.removeWhere((k, v) {
      if (live.contains(k)) return false;
      v.painter.dispose();
      return true;
    });
  }

  void paintElement(Canvas canvas, BoardElement e) {
    switch (e) {
      case StrokeElement():
        canvas.drawPath(
          strokePath(e),
          Paint()
            ..isAntiAlias = true
            ..color = BoardColors.display(e.color, _theme.brightness),
        );
      case ShapeElement():
        paintShape(canvas, e);
      case TextElement():
        textPainter(e).paint(canvas, Offset(e.x, e.y));
      case ImageElement():
        _paintImage(canvas, e);
      case UnknownElement():
        break;
    }
  }

  void paintShape(Canvas canvas, ShapeElement s) {
    final b = _theme.brightness;
    final stroke = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = BoardColors.display(s.color, b);
    final r = Rect.fromPoints(s.start, s.end);
    final rotated = s.rotation != 0;
    if (rotated) {
      canvas
        ..save()
        ..translate(r.center.dx, r.center.dy)
        ..rotate(s.rotation * math.pi / 180)
        ..translate(-r.center.dx, -r.center.dy);
    }
    final fill = s.fill == null
        ? null
        : (Paint()
            ..isAntiAlias = true
            ..color = BoardColors.display(s.fill!, b));
    switch (s.shape) {
      case ShapeKind.rect:
        if (fill != null) canvas.drawRect(r, fill);
        canvas.drawRect(r, stroke);
      case ShapeKind.ellipse:
        if (fill != null) canvas.drawOval(r, fill);
        canvas.drawOval(r, stroke);
      case ShapeKind.line:
        canvas.drawLine(s.start, s.end, stroke);
      case ShapeKind.arrow:
        canvas.drawLine(s.start, s.end, stroke);
        if (s.w != 0 || s.h != 0) {
          final (h1, h2) = arrowHeadPoints(s);
          canvas
            ..drawLine(s.end, h1, stroke)
            ..drawLine(s.end, h2, stroke);
        }
    }
    if (rotated) canvas.restore();
  }

  void _paintImage(Canvas canvas, ImageElement e) {
    final dst = Rect.fromPoints(Offset(e.x, e.y), Offset(e.x + e.w, e.y + e.h));
    if (dst.isEmpty) return;
    final img = images.imageFor(e.attachmentId);
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        dst,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..isAntiAlias = true,
      );
      return;
    }
    final failed = images.stateOf(e.attachmentId) == BoardImageState.failed;
    final rr = RRect.fromRectAndRadius(dst, const Radius.circular(8));
    canvas.drawRRect(rr, Paint()..color = _theme.placeholderFill);
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _theme.placeholderStroke,
    );
    // Icono simple: marco de imagen (cargando) o aspa (no disponible).
    final side = math.min(48.0, math.min(dst.width, dst.height) * 0.4);
    final icon = Rect.fromCenter(center: dst.center, width: side, height: side * 0.8);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, side / 16)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _theme.placeholderIcon;
    if (failed) {
      canvas
        ..drawLine(icon.topLeft, icon.bottomRight, p)
        ..drawLine(icon.topRight, icon.bottomLeft, p);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(icon, Radius.circular(side / 8)), p);
      final m = Path()
        ..moveTo(icon.left + side * 0.1, icon.bottom - side * 0.12)
        ..lineTo(icon.left + side * 0.4, icon.top + side * 0.4)
        ..lineTo(icon.left + side * 0.6, icon.bottom - side * 0.3)
        ..lineTo(icon.left + side * 0.75, icon.top + side * 0.5)
        ..lineTo(icon.right - side * 0.1, icon.bottom - side * 0.12);
      canvas.drawPath(m, p);
    }
  }

  void dispose() {
    for (final t in _texts.values) {
      t.painter.dispose();
    }
    _texts.clear();
  }
}
