import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'elements.dart';

/// Vista guardada con la escena: `x`,`y` = punto del lienzo que aparece en la esquina superior
/// izquierda de la pantalla; `scale` = zoom (0.25–4).
@immutable
class BoardViewport {
  const BoardViewport({this.x = 0, this.y = 0, this.scale = 1});

  static const minScale = 0.25;
  static const maxScale = 4.0;
  static const identity = BoardViewport();

  final double x, y, scale;

  Offset get origin => Offset(x, y);

  /// Pantalla (coordenadas locales del lienzo) → lienzo.
  Offset toCanvas(Offset screen) => Offset(screen.dx / scale + x, screen.dy / scale + y);

  /// Lienzo → pantalla.
  Offset toScreen(Offset canvas) => Offset((canvas.dx - x) * scale, (canvas.dy - y) * scale);

  Rect rectToScreen(Rect r) => Rect.fromPoints(toScreen(r.topLeft), toScreen(r.bottomRight));

  /// Región del lienzo visible en una vista de tamaño `size`.
  Rect visibleRect(Size size) => Rect.fromLTWH(x, y, size.width / scale, size.height / scale);

  static double clampScale(double s) => s.clamp(minScale, maxScale);

  /// Zoom a `newScale` manteniendo fijo el punto de pantalla `focal`.
  BoardViewport zoomAt(Offset focal, double newScale) {
    final s = clampScale(newScale);
    final c = toCanvas(focal);
    return BoardViewport(x: c.dx - focal.dx / s, y: c.dy - focal.dy / s, scale: s);
  }

  /// Desplaza el contenido `screenDelta` píxeles de pantalla.
  BoardViewport panBy(Offset screenDelta) =>
      BoardViewport(x: x - screenDelta.dx / scale, y: y - screenDelta.dy / scale, scale: scale);

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'scale': scale};

  static BoardViewport fromJson(Object? json) {
    if (json is! Map) return identity;
    double read(Object? v, double fb) => v is num && v.toDouble().isFinite ? v.toDouble() : fb;
    return BoardViewport(
      x: read(json['x'], 0),
      y: read(json['y'], 0),
      scale: clampScale(read(json['scale'], 1)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BoardViewport && other.x == x && other.y == y && other.scale == scale;

  @override
  int get hashCode => Object.hash(x, y, scale);

  @override
  String toString() => 'BoardViewport($x, $y, ×$scale)';
}

/// La escena se creó con un formato posterior que esta versión no sabe editar sin perder datos.
class UnsupportedSceneVersion implements Exception {
  const UnsupportedSceneVersion(this.version);
  final int version;
  @override
  String toString() => 'Versión de pizarra no compatible: $version';
}

/// Escena de pizarra v1 (docs/CONTRATOS.md §2).
@immutable
class BoardScene {
  const BoardScene({
    this.version = currentVersion,
    this.background = 'plain',
    this.viewport = BoardViewport.identity,
    this.elements = const [],
    this.extra = const {},
  });

  static const currentVersion = 1;

  final int version;
  final String background;
  final BoardViewport viewport;

  /// Orden del array = orden Z (último encima).
  final List<BoardElement> elements;

  /// Claves de primer nivel desconocidas (se conservan).
  final Map<String, Object?> extra;

  static const _keys = {'version', 'background', 'viewport', 'elements'};

  BoardScene copyWith({BoardViewport? viewport, List<BoardElement>? elements}) => BoardScene(
    version: version,
    background: background,
    viewport: viewport ?? this.viewport,
    elements: elements ?? this.elements,
    extra: extra,
  );

  /// Lee el JSON guardado. Cadena vacía → escena vacía. Lanza [FormatException] si no es un
  /// objeto JSON válido y [UnsupportedSceneVersion] si la versión es posterior a la v1.
  static BoardScene decode(String source) {
    if (source.trim().isEmpty) return const BoardScene();
    final Object? root;
    try {
      root = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException('JSON de pizarra inválido: ${e.message}');
    }
    if (root is! Map<String, Object?>) throw const FormatException('La escena no es un objeto JSON');
    return fromJson(root);
  }

  static BoardScene fromJson(Map<String, Object?> json) {
    final v = json['version'];
    final version = v is num ? v.toInt() : currentVersion;
    if (version > currentVersion) throw UnsupportedSceneVersion(version);
    final rawElements = json['elements'];
    final elements = <BoardElement>[];
    if (rawElements is List) {
      for (final e in rawElements) {
        if (e is Map<String, Object?>) {
          elements.add(BoardElement.fromJson(e));
        } else if (e is Map) {
          elements.add(BoardElement.fromJson(e.cast<String, Object?>()));
        }
      }
    }
    return BoardScene(
      version: currentVersion,
      background: json['background'] is String ? json['background'] as String : 'plain',
      viewport: BoardViewport.fromJson(json['viewport']),
      elements: List.unmodifiable(elements),
      extra: {
        for (final e in json.entries)
          if (!_keys.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'background': background,
    'viewport': viewport.toJson(),
    'elements': [for (final e in elements) e.toJson()],
    ...extra,
  };

  /// JSON compacto. Reutiliza la codificación cacheada de cada elemento (los elementos son
  /// inmutables), así que un guardado tras un cambio pequeño solo codifica lo nuevo.
  String encode() {
    final b = StringBuffer()
      ..write('{"version":')
      ..write(version)
      ..write(',"background":')
      ..write(jsonEncode(background))
      ..write(',"viewport":')
      ..write(jsonEncode(viewport.toJson()))
      ..write(',"elements":[');
    for (var i = 0; i < elements.length; i++) {
      if (i > 0) b.write(',');
      b.write(encodeElement(elements[i]));
    }
    b.write(']');
    for (final e in extra.entries) {
      b
        ..write(',')
        ..write(jsonEncode(e.key))
        ..write(':')
        ..write(jsonEncode(e.value));
    }
    b.write('}');
    return b.toString();
  }

  static final _encoded = Expando<String>('boardElementJson');

  static String encodeElement(BoardElement e) => _encoded[e] ??= jsonEncode(e.toJson());

  /// Precarga la codificación de un elemento (p. ej. calculada en otro isolate al abrir).
  static void primeEncoded(BoardElement e, String json) => _encoded[e] = json;
}

/// Resultado de leer una escena fuera del hilo de UI: la escena y la codificación de cada elemento.
class DecodedScene {
  const DecodedScene(this.scene, this.encodedElements);
  final BoardScene scene;
  final List<String> encodedElements;

  /// Hace que [BoardScene.encode] reutilice la codificación calculada.
  BoardScene prime() {
    for (var i = 0; i < scene.elements.length && i < encodedElements.length; i++) {
      BoardScene.primeEncoded(scene.elements[i], encodedElements[i]);
    }
    return scene;
  }
}

/// Decodifica y precalcula el JSON de cada elemento (pensado para `Isolate.run`).
DecodedScene decodeSceneWithCache(String source) {
  final scene = BoardScene.decode(source);
  return DecodedScene(scene, [for (final e in scene.elements) jsonEncode(e.toJson())]);
}
