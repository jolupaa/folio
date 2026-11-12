import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../platform/native.dart';

/// Imagen de una página con las líneas reconocidas dibujadas encima.
///
/// - Tocar una línea llama a [onLineTap] (la pantalla la resalta en el texto).
/// - [selectedLine] se dibuja resaltada; [matchedLines] (coincidencias de búsqueda) también.
/// - Las líneas de baja confianza (< 0,5) llevan borde discontinuo: el estado no depende solo del color.
class OcrImageOverlay extends StatelessWidget {
  const OcrImageOverlay({
    super.key,
    required this.image,
    required this.aspectRatio,
    this.lines = const [],
    this.selectedLine,
    this.matchedLines = const {},
    this.onLineTap,
    this.showLines = true,
    this.semanticLabel,
  });

  final ImageProvider image;

  /// Ancho / alto de la imagen.
  final double aspectRatio;
  final List<OcrTextLine> lines;
  final int? selectedLine;
  final Set<int> matchedLines;
  final ValueChanged<int>? onLineTap;
  final bool showLines;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1.0;
    final label =
        semanticLabel ??
        (lines.isEmpty
            ? 'Imagen de la página'
            : 'Imagen de la página con ${lines.length} líneas reconocidas');
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: Semantics(
          image: true,
          label: label,
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final h = box.maxHeight;
              return Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: c.separator, width: 0.6),
                    ),
                    child: Image(
                      image: image,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (context, error, stack) => ColoredBox(
                        color: c.surfaceAlt,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.broken_image_rounded, color: c.textSecondary),
                              const SizedBox(height: Insets.xs),
                              Text('No se pudo cargar la imagen', style: context.text.bodySmall),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (showLines)
                    for (var i = 0; i < lines.length; i++)
                      if (lines[i].hasBox)
                        Positioned(
                          left: lines[i].x * w,
                          top: lines[i].y * h,
                          width: lines[i].w * w,
                          height: lines[i].h * h,
                          child: ExcludeSemantics(
                            child: _LineBox(
                              line: lines[i],
                              selected: i == selectedLine,
                              matched: matchedLines.contains(i),
                              onTap: onLineTap == null ? null : () => onLineTap!(i),
                            ),
                          ),
                        ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LineBox extends StatelessWidget {
  const _LineBox({required this.line, required this.selected, required this.matched, this.onTap});

  final OcrTextLine line;
  final bool selected;
  final bool matched;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final low = line.isLowConfidence;
    final Color fill;
    final Color stroke;
    final double width;
    if (selected) {
      fill = c.highlight.withValues(alpha: 0.55);
      stroke = c.accent;
      width = 2;
    } else if (matched) {
      fill = c.highlight.withValues(alpha: 0.6);
      stroke = c.highlight;
      width = 1.2;
    } else if (low) {
      fill = c.danger.withValues(alpha: 0.08);
      stroke = c.danger;
      width = 1.2;
    } else {
      fill = c.accent.withValues(alpha: 0.08);
      stroke = c.accent.withValues(alpha: 0.55);
      width = 1;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: CustomPaint(
        painter: _BoxPainter(fill: fill, stroke: stroke, strokeWidth: width, dashed: low && !selected),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({required this.fill, required this.stroke, required this.strokeWidth, required this.dashed});

  final Color fill;
  final Color stroke;
  final double strokeWidth;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
    canvas.drawRRect(rrect, Paint()..color = fill);
    final paint = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    if (!dashed) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    final path = Path()..addRRect(rrect);
    const dash = 4.0;
    const gap = 3.0;
    for (final ui.PathMetric metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.fill != fill || old.stroke != stroke || old.strokeWidth != strokeWidth || old.dashed != dashed;
}
