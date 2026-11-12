import 'dart:typed_data';
import 'dart:ui';

import 'board_color.dart';

/// Elementos de la escena de pizarra v1 (docs/CONTRATOS.md §2).
///
/// Son inmutables: cada modificación crea un elemento nuevo con el mismo `id`, lo que permite
/// compartirlos entre la escena y el historial de deshacer sin copias y cachear su geometría.
/// Las claves desconocidas de cada elemento se conservan en [extra] (compatibilidad futura) y
/// los tipos desconocidos o inválidos se conservan íntegros como [UnknownElement].
sealed class BoardElement {
  const BoardElement({required this.id, this.extra = const {}});

  final String id;

  /// Claves no reconocidas, que se vuelven a escribir tal cual.
  final Map<String, Object?> extra;

  String get type;

  Map<String, Object?> toJson();

  /// Copia con otro id (duplicar).
  BoardElement withId(String id);

  /// Nº aproximado de números que retiene el elemento (presupuesto de memoria del historial).
  int get weight => 16;

  static BoardElement fromJson(Map<String, Object?> json) {
    try {
      final parsed = switch (json['type']) {
        StrokeElement.typeName => StrokeElement._fromJson(json),
        ShapeElement.typeName => ShapeElement._fromJson(json),
        TextElement.typeName => TextElement._fromJson(json),
        ImageElement.typeName => ImageElement._fromJson(json),
        _ => null,
      };
      if (parsed != null) return parsed;
    } on FormatException {
      // Elemento conocido pero con datos inválidos: se conserva sin interpretar.
    }
    return UnknownElement(Map<String, Object?>.of(json));
  }
}

/// Herramientas de trazo conocidas.
abstract final class StrokeTools {
  static const pen = 'pen';
  static const highlighter = 'highlighter';
}

/// Formas conocidas. Para `line`/`arrow`, (x,y) es el inicio y (x+w, y+h) el fin.
enum ShapeKind {
  rect('rect'),
  ellipse('ellipse'),
  line('line'),
  arrow('arrow');

  const ShapeKind(this.wire);
  final String wire;

  bool get isLinear => this == line || this == arrow;

  static ShapeKind? fromWire(Object? s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

final class StrokeElement extends BoardElement {
  StrokeElement({
    required super.id,
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    super.extra,
  }) : assert(points.length % 3 == 0);

  static const typeName = 'stroke';

  /// `pen` | `highlighter` (otros valores se conservan y se dibujan como lápiz).
  final String tool;
  final Color color;

  /// Diámetro base en unidades de lienzo (presión media).
  final double width;

  /// Tripletas planas `x, y, presión(0..1)` en unidades de lienzo.
  final Float64List points;

  bool get isHighlighter => tool == StrokeTools.highlighter;
  int get pointCount => points.length ~/ 3;
  Offset pointAt(int i) => Offset(points[i * 3], points[i * 3 + 1]);
  double pressureAt(int i) => points[i * 3 + 2];

  @override
  String get type => typeName;

  @override
  int get weight => 16 + points.length;

  @override
  StrokeElement withId(String id) =>
      StrokeElement(id: id, tool: tool, color: color, width: width, points: points, extra: extra);

  StrokeElement copyWith({Color? color, double? width, Float64List? points}) => StrokeElement(
    id: id,
    tool: tool,
    color: color ?? this.color,
    width: width ?? this.width,
    points: points ?? this.points,
    extra: extra,
  );

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'type': typeName,
    'tool': tool,
    'color': BoardColors.format(color),
    'width': width,
    'points': points,
    ...extra,
  };

  static const _keys = {'id', 'type', 'tool', 'color', 'width', 'points'};

  static StrokeElement _fromJson(Map<String, Object?> j) {
    final raw = j['points'];
    if (raw is! List || raw.length % 3 != 0) throw const FormatException('points');
    final pts = Float64List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      pts[i] = _num(raw[i]);
    }
    return StrokeElement(
      id: _id(j),
      tool: j['tool'] is String ? j['tool'] as String : StrokeTools.pen,
      color: BoardColors.parse(j['color']),
      width: _num(j['width'], fallback: 3),
      points: pts,
      extra: _extra(j, _keys),
    );
  }
}

final class ShapeElement extends BoardElement {
  const ShapeElement({
    required super.id,
    required this.shape,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.color,
    required this.width,
    this.fill,
    this.rotation = 0,
    super.extra,
  });

  static const typeName = 'shape';

  final ShapeKind shape;
  final double x, y, w, h;
  final Color color;
  final double width;
  final Color? fill;

  /// Grados, alrededor del centro. La UI no la modifica; se conserva y se respeta al dibujar.
  final double rotation;

  Offset get start => Offset(x, y);
  Offset get end => Offset(x + w, y + h);

  @override
  String get type => typeName;

  @override
  ShapeElement withId(String id) => copyWith(id: id);

  ShapeElement copyWith({
    String? id,
    double? x,
    double? y,
    double? w,
    double? h,
    Color? color,
    double? width,
  }) => ShapeElement(
    id: id ?? this.id,
    shape: shape,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    color: color ?? this.color,
    width: width ?? this.width,
    fill: fill,
    rotation: rotation,
    extra: extra,
  );

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'type': typeName,
    'shape': shape.wire,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'color': BoardColors.format(color),
    'width': width,
    'fill': fill == null ? null : BoardColors.format(fill!),
    'rotation': rotation,
    ...extra,
  };

  static const _keys = {'id', 'type', 'shape', 'x', 'y', 'w', 'h', 'color', 'width', 'fill', 'rotation'};

  static ShapeElement _fromJson(Map<String, Object?> j) {
    final kind = ShapeKind.fromWire(j['shape']);
    if (kind == null) throw const FormatException('shape');
    return ShapeElement(
      id: _id(j),
      shape: kind,
      x: _num(j['x']),
      y: _num(j['y']),
      w: _num(j['w']),
      h: _num(j['h']),
      color: BoardColors.parse(j['color']),
      width: _num(j['width'], fallback: 2),
      fill: BoardColors.tryParse(j['fill']),
      rotation: _num(j['rotation'], fallback: 0),
      extra: _extra(j, _keys),
    );
  }
}

final class TextElement extends BoardElement {
  const TextElement({
    required super.id,
    required this.x,
    required this.y,
    required this.w,
    required this.text,
    required this.color,
    required this.size,
    super.extra,
  });

  static const typeName = 'text';

  /// Esquina superior izquierda y ancho de ajuste de línea (unidades de lienzo).
  final double x, y, w;
  final String text;
  final Color color;

  /// Tamaño de fuente en unidades de lienzo.
  final double size;

  @override
  String get type => typeName;

  @override
  int get weight => 16 + text.length ~/ 4;

  @override
  TextElement withId(String id) => copyWith(id: id);

  TextElement copyWith({String? id, double? x, double? y, double? w, String? text, Color? color, double? size}) =>
      TextElement(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        text: text ?? this.text,
        color: color ?? this.color,
        size: size ?? this.size,
        extra: extra,
      );

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'type': typeName,
    'x': x,
    'y': y,
    'w': w,
    'text': text,
    'color': BoardColors.format(color),
    'size': size,
    ...extra,
  };

  static const _keys = {'id', 'type', 'x', 'y', 'w', 'text', 'color', 'size'};

  static TextElement _fromJson(Map<String, Object?> j) {
    final text = j['text'];
    if (text is! String) throw const FormatException('text');
    return TextElement(
      id: _id(j),
      x: _num(j['x']),
      y: _num(j['y']),
      w: _num(j['w'], fallback: 240),
      text: text,
      color: BoardColors.parse(j['color']),
      size: _num(j['size'], fallback: 20),
      extra: _extra(j, _keys),
    );
  }
}

final class ImageElement extends BoardElement {
  const ImageElement({
    required super.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.attachmentId,
    super.extra,
  });

  static const typeName = 'image';

  final double x, y, w, h;

  /// Adjunto de la propia pizarra (`import_image(note_id = id de la pizarra)`).
  final String attachmentId;

  Rect get rect => Rect.fromLTWH(x, y, w, h);

  @override
  String get type => typeName;

  @override
  ImageElement withId(String id) => copyWith(id: id);

  ImageElement copyWith({String? id, double? x, double? y, double? w, double? h}) => ImageElement(
    id: id ?? this.id,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    attachmentId: attachmentId,
    extra: extra,
  );

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'type': typeName,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'attachment_id': attachmentId,
    ...extra,
  };

  static const _keys = {'id', 'type', 'x', 'y', 'w', 'h', 'attachment_id'};

  static ImageElement _fromJson(Map<String, Object?> j) {
    final att = j['attachment_id'];
    if (att is! String || att.isEmpty) throw const FormatException('attachment_id');
    return ImageElement(
      id: _id(j),
      x: _num(j['x']),
      y: _num(j['y']),
      w: _num(j['w']),
      h: _num(j['h']),
      attachmentId: att,
      extra: _extra(j, _keys),
    );
  }
}

/// Elemento de tipo desconocido (o con datos que esta versión no entiende). No se dibuja ni se
/// puede seleccionar, pero se conserva íntegro y en su posición Z al guardar.
final class UnknownElement extends BoardElement {
  UnknownElement(this.raw) : super(id: raw['id'] is String ? raw['id'] as String : '');

  final Map<String, Object?> raw;

  @override
  String get type => raw['type'] is String ? raw['type'] as String : '';

  @override
  UnknownElement withId(String id) => UnknownElement({...raw, 'id': id});

  @override
  Map<String, Object?> toJson() => raw;
}

// ─────────────────────────── utilidades de lectura ───────────────────────────

String _id(Map<String, Object?> j) {
  final id = j['id'];
  if (id is! String || id.isEmpty) throw const FormatException('id');
  return id;
}

double _num(Object? v, {double? fallback}) {
  if (v is num) {
    final d = v.toDouble();
    if (d.isFinite) return d;
  }
  if (fallback != null && v == null) return fallback;
  throw FormatException('número inválido: $v');
}

Map<String, Object?> _extra(Map<String, Object?> j, Set<String> known) {
  if (j.length <= known.length && j.keys.every(known.contains)) return const {};
  return {
    for (final e in j.entries)
      if (!known.contains(e.key)) e.key: e.value,
  };
}
