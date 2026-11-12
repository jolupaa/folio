import 'dart:typed_data';
import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';

/// Opciones de suavizado de perfect_freehand para cada herramienta.
StrokeOptions strokeOptions({required double width, required bool highlighter, required bool complete}) =>
    StrokeOptions(
      size: width,
      // El marcador tiene grosor constante; el lápiz varía con la presión.
      thinning: highlighter ? 0 : 0.55,
      smoothing: 0.5,
      streamline: highlighter ? 0.5 : 0.4,
      simulatePressure: false,
      isComplete: complete,
    );

/// Contorno del trazo (polígono) a partir de tripletas `x, y, presión`.
List<Offset> strokeOutline(
  Float64List points, {
  required double width,
  required bool highlighter,
  bool complete = true,
  int? count,
}) {
  final n = count ?? points.length ~/ 3;
  if (n == 0) return const [];
  final input = List<PointVector>.generate(
    n,
    (i) => PointVector(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]),
    growable: false,
  );
  return getStroke(input, options: strokeOptions(width: width, highlighter: highlighter, complete: complete));
}

/// Trayecto suave (curvas cuadráticas por los puntos medios) para rellenar el contorno.
Path outlineToPath(List<Offset> outline) {
  final path = Path()..fillType = PathFillType.nonZero;
  if (outline.isEmpty) return path;
  if (outline.length < 3) {
    final c = outline.first;
    path.addOval(Rect.fromCircle(center: c, radius: 0.5));
    return path;
  }
  path.moveTo(outline[0].dx, outline[0].dy);
  for (var i = 0; i < outline.length; i++) {
    final p = outline[i];
    final q = outline[(i + 1) % outline.length];
    path.quadraticBezierTo(p.dx, p.dy, (p.dx + q.dx) / 2, (p.dy + q.dy) / 2);
  }
  path.close();
  return path;
}
