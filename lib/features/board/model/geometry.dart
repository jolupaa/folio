import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'elements.dart';

/// Alto de un elemento de texto (en unidades de lienzo). La UI lo mide con `TextPainter`;
/// [estimateTextHeight] es una aproximación sin motor de texto (tests, cálculos previos).
typedef TextHeightOf = double Function(TextElement e);

/// Interlineado usado al dibujar y editar texto.
const kBoardTextLineHeight = 1.3;

double estimateTextHeight(TextElement e) {
  final charsPerLine = math.max(1, (e.w / (e.size * 0.55)).floor());
  var lines = 0;
  for (final line in e.text.split('\n')) {
    lines += math.max(1, (line.length / charsPerLine).ceil());
  }
  return math.max(1, lines) * e.size * kBoardTextLineHeight;
}

final _strokeBounds = Expando<Rect>('strokeBounds');

/// Caja envolvente en unidades de lienzo (incluye el grosor del trazo).
Rect elementBounds(BoardElement e, {TextHeightOf textHeight = estimateTextHeight}) {
  switch (e) {
    case StrokeElement():
      return _strokeBounds[e] ??= _computeStrokeBounds(e);
    case ShapeElement():
      final r = Rect.fromPoints(e.start, e.end);
      final rotated = e.rotation == 0 ? r : _rotatedBounds(r, e.rotation);
      final pad = e.width / 2 + (e.shape == ShapeKind.arrow ? _arrowHeadLength(e) : 0);
      return rotated.inflate(pad);
    case TextElement():
      return Rect.fromLTWH(e.x, e.y, e.w, textHeight(e));
    case ImageElement():
      return Rect.fromPoints(Offset(e.x, e.y), Offset(e.x + e.w, e.y + e.h));
    case UnknownElement():
      return Rect.zero;
  }
}

/// Unión de las cajas de varios elementos (null si no hay ninguno con área).
Rect? unionBounds(Iterable<BoardElement> elements, {TextHeightOf textHeight = estimateTextHeight}) {
  Rect? acc;
  for (final e in elements) {
    if (e is UnknownElement) continue;
    final b = elementBounds(e, textHeight: textHeight);
    acc = acc == null ? b : acc.expandToInclude(b);
  }
  return acc;
}

Rect _computeStrokeBounds(StrokeElement s) {
  final p = s.points;
  if (p.isEmpty) return Rect.zero;
  var minX = p[0], maxX = p[0], minY = p[1], maxY = p[1];
  for (var i = 3; i < p.length; i += 3) {
    final x = p[i], y = p[i + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  // El contorno con presión máxima puede llegar a ~0.8× el ancho a cada lado.
  final pad = s.width * 0.8;
  return Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
}

double _arrowHeadLength(ShapeElement e) => math.max(12, e.width * 4);

Rect _rotatedBounds(Rect r, double degrees) {
  final c = r.center;
  final pts = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight].map((p) => _rotate(p, c, degrees));
  var acc = Rect.fromPoints(pts.first, pts.first);
  for (final p in pts) {
    acc = acc.expandToInclude(Rect.fromPoints(p, p));
  }
  return acc;
}

Offset _rotate(Offset p, Offset c, double degrees) {
  final a = degrees * math.pi / 180;
  final s = math.sin(a), co = math.cos(a);
  final d = p - c;
  return Offset(c.dx + d.dx * co - d.dy * s, c.dy + d.dx * s + d.dy * co);
}

/// Distancia de `p` al segmento `a`–`b`.
double distanceToSegment(Offset p, Offset a, Offset b) {
  final abx = b.dx - a.dx, aby = b.dy - a.dy;
  final len2 = abx * abx + aby * aby;
  if (len2 == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) / len2;
  t = t.clamp(0.0, 1.0);
  final cx = a.dx + abx * t, cy = a.dy + aby * t;
  final dx = p.dx - cx, dy = p.dy - cy;
  return math.sqrt(dx * dx + dy * dy);
}

/// ¿Toca un círculo (centro `c`, radio `r`) la línea del trazo (con su grosor)?
bool strokeHitsCircle(StrokeElement s, Offset c, double r) {
  final reach = r + s.width / 2;
  if (!elementBounds(s).inflate(r).contains(c)) return false;
  final p = s.points;
  final n = s.pointCount;
  if (n == 0) return false;
  if (n == 1) return (Offset(p[0], p[1]) - c).distance <= reach;
  for (var i = 0; i < n - 1; i++) {
    final a = Offset(p[i * 3], p[i * 3 + 1]);
    final b = Offset(p[i * 3 + 3], p[i * 3 + 4]);
    if (distanceToSegment(c, a, b) <= reach) return true;
  }
  return false;
}

/// Prueba de impacto de un punto (unidades de lienzo) con tolerancia `tolerance`.
bool hitTestElement(
  BoardElement e,
  Offset p,
  double tolerance, {
  TextHeightOf textHeight = estimateTextHeight,
}) {
  switch (e) {
    case StrokeElement():
      return strokeHitsCircle(e, p, tolerance);
    case ShapeElement():
      return _hitShape(e, p, tolerance);
    case TextElement():
    case ImageElement():
      return elementBounds(e, textHeight: textHeight).inflate(tolerance).contains(p);
    case UnknownElement():
      return false;
  }
}

bool _hitShape(ShapeElement s, Offset point, double tol) {
  final r = Rect.fromPoints(s.start, s.end);
  // Deshace la rotación para comprobar en el sistema de la forma.
  final p = s.rotation == 0 ? point : _rotate(point, r.center, -s.rotation);
  final reach = tol + s.width / 2;
  switch (s.shape) {
    case ShapeKind.line:
      return distanceToSegment(p, s.start, s.end) <= reach;
    case ShapeKind.arrow:
      if (distanceToSegment(p, s.start, s.end) <= reach) return true;
      final (h1, h2) = arrowHeadPoints(s);
      return distanceToSegment(p, s.end, h1) <= reach || distanceToSegment(p, s.end, h2) <= reach;
    case ShapeKind.rect:
      if (s.fill != null && r.contains(p)) return true;
      if (!r.inflate(reach).contains(p)) return false;
      final inner = r.deflate(reach);
      return inner.isEmpty || !inner.contains(p);
    case ShapeKind.ellipse:
      final rx = r.width / 2, ry = r.height / 2;
      final c = r.center;
      if (rx < 0.5 || ry < 0.5) {
        return distanceToSegment(p, Offset(r.left, c.dy), Offset(r.right, c.dy)) <= reach ||
            distanceToSegment(p, Offset(c.dx, r.top), Offset(c.dx, r.bottom)) <= reach;
      }
      final dx = p.dx - c.dx, dy = p.dy - c.dy;
      final k = math.sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry));
      if (s.fill != null && k <= 1) return true;
      // Distancia radial aproximada al contorno.
      final dist = (k - 1).abs() * math.min(rx, ry);
      return dist <= reach;
  }
}

/// Extremos de las dos líneas de la punta de flecha (en el sistema sin rotar).
(Offset, Offset) arrowHeadPoints(ShapeElement s) {
  final len = _arrowHeadLength(s);
  final angle = math.atan2(s.h, s.w);
  const spread = 28 * math.pi / 180;
  final e = s.end;
  Offset at(double a) => Offset(e.dx - len * math.cos(a), e.dy - len * math.sin(a));
  return (at(angle - spread), at(angle + spread));
}

/// Elemento superior (último en orden Z) que contiene el punto, o null.
BoardElement? topmostAt(
  List<BoardElement> elements,
  Offset p,
  double tolerance, {
  TextHeightOf textHeight = estimateTextHeight,
}) {
  for (var i = elements.length - 1; i >= 0; i--) {
    final e = elements[i];
    if (hitTestElement(e, p, tolerance, textHeight: textHeight)) return e;
  }
  return null;
}

/// Trazos (y formas) que toca el borrador al moverse de `from` a `to` con radio `radius`.
/// Muestrea el segmento para no saltarse trazos con movimientos rápidos.
Set<String> eraserHits(
  List<BoardElement> elements,
  Offset from,
  Offset to,
  double radius, {
  Set<String> skip = const {},
}) {
  final hits = <String>{};
  final dist = (to - from).distance;
  final steps = math.max(1, (dist / math.max(1, radius * 0.5)).ceil());
  final sweep = Rect.fromPoints(from, to).inflate(radius);
  for (final e in elements) {
    if (skip.contains(e.id)) continue;
    if (e is! StrokeElement && e is! ShapeElement) continue;
    if (!elementBounds(e).overlaps(sweep)) continue;
    for (var i = 0; i <= steps; i++) {
      final c = Offset.lerp(from, to, i / steps)!;
      final hit = e is StrokeElement ? strokeHitsCircle(e, c, radius) : _hitShape(e as ShapeElement, c, radius);
      if (hit) {
        hits.add(e.id);
        break;
      }
    }
  }
  return hits;
}

/// Punto dentro de un polígono (regla par-impar).
bool pointInPolygon(Offset p, List<Offset> poly) {
  if (poly.length < 3) return false;
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) && p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Ids de los elementos rodeados por el lazo (o rectángulo como polígono de 4 vértices).
/// Trazos: al menos la mitad de sus puntos dentro. Resto: el centro de su caja dentro.
List<String> elementsInPolygon(
  List<BoardElement> elements,
  List<Offset> polygon, {
  TextHeightOf textHeight = estimateTextHeight,
}) {
  if (polygon.length < 3) return const [];
  var bbox = Rect.fromPoints(polygon.first, polygon.first);
  for (final p in polygon) {
    bbox = bbox.expandToInclude(Rect.fromPoints(p, p));
  }
  final out = <String>[];
  for (final e in elements) {
    if (e is UnknownElement) continue;
    final b = elementBounds(e, textHeight: textHeight);
    if (!b.overlaps(bbox)) continue;
    if (e is StrokeElement) {
      final n = e.pointCount;
      if (n == 0) continue;
      final step = math.max(1, n ~/ 40);
      var inside = 0, total = 0;
      for (var i = 0; i < n; i += step) {
        total++;
        if (pointInPolygon(e.pointAt(i), polygon)) inside++;
      }
      if (inside * 2 >= total) out.add(e.id);
    } else if (pointInPolygon(b.center, polygon)) {
      out.add(e.id);
    }
  }
  return out;
}

List<Offset> rectPolygon(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

/// Transformación afín simple: escala (`sx`,`sy`) respecto a `anchor` y luego traslación.
class ElementTransform {
  const ElementTransform({this.translate = Offset.zero, this.sx = 1, this.sy = 1, this.anchor = Offset.zero});

  static const identity = ElementTransform();

  final Offset translate;
  final double sx, sy;
  final Offset anchor;

  bool get isIdentity => translate == Offset.zero && sx == 1 && sy == 1;
  bool get isUniform => sx == sy;
  bool get isTranslationOnly => sx == 1 && sy == 1;

  Offset apply(Offset p) =>
      Offset(anchor.dx + (p.dx - anchor.dx) * sx + translate.dx, anchor.dy + (p.dy - anchor.dy) * sy + translate.dy);

  /// Factor para magnitudes no direccionales (grosor, tamaño de letra).
  double get uniformFactor => math.sqrt((sx * sy).abs());
}

/// Aplica la transformación a un elemento. Trazos: puntos y grosor; texto: posición, ancho y
/// tamaño de letra; imágenes y formas: posición y tamaño (el grosor de línea de las formas se mantiene).
BoardElement transformElement(BoardElement e, ElementTransform t) {
  if (t.isIdentity) return e;
  switch (e) {
    case StrokeElement():
      final src = e.points;
      final out = Float64List(src.length);
      for (var i = 0; i < src.length; i += 3) {
        final q = t.apply(Offset(src[i], src[i + 1]));
        out[i] = roundCoord(q.dx);
        out[i + 1] = roundCoord(q.dy);
        out[i + 2] = src[i + 2];
      }
      return e.copyWith(points: out, width: t.isTranslationOnly ? e.width : roundCoord(e.width * t.uniformFactor));
    case ShapeElement():
      final a = t.apply(e.start);
      final b = t.apply(e.end);
      if (e.shape.isLinear) {
        return e.copyWith(x: roundCoord(a.dx), y: roundCoord(a.dy), w: roundCoord(b.dx - a.dx), h: roundCoord(b.dy - a.dy));
      }
      final r = Rect.fromPoints(a, b);
      return e.copyWith(x: roundCoord(r.left), y: roundCoord(r.top), w: roundCoord(r.width), h: roundCoord(r.height));
    case TextElement():
      final a = t.apply(Offset(e.x, e.y));
      final f = t.uniformFactor;
      return e.copyWith(
        x: roundCoord(a.dx),
        y: roundCoord(a.dy),
        w: roundCoord(math.max(16, e.w * t.sx.abs())),
        size: roundCoord((e.size * f).clamp(4, 400)),
      );
    case ImageElement():
      final r = Rect.fromPoints(t.apply(Offset(e.x, e.y)), t.apply(Offset(e.x + e.w, e.y + e.h)));
      return e.copyWith(x: roundCoord(r.left), y: roundCoord(r.top), w: roundCoord(r.width), h: roundCoord(r.height));
    case UnknownElement():
      return e;
  }
}

/// Redondeo de coordenadas a centésimas (JSON compacto e idas y vueltas exactas).
double roundCoord(double v) => (v * 100).roundToDouble() / 100;

/// Redondeo de presión a milésimas.
double roundPressure(double v) => (v.clamp(0.0, 1.0) * 1000).roundToDouble() / 1000;
