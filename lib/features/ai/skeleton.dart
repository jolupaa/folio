import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Esqueleto discreto de lista mientras se cargan datos (docs/DESIGN.md §8: nada de spinners a
/// pantalla completa).
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6, this.label = 'Cargando', this.leading = true});

  final int rows;
  final String label;
  final bool leading;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: ListView.builder(
          itemCount: rows,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: Insets.sm),
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.gutter, vertical: Insets.md),
            child: Row(
              children: [
                if (leading) ...[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(8)),
                  ),
                  const SizedBox(width: Insets.lg),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: 0.55 + (i % 3) * 0.12,
                        child: _Bar(height: 14, color: c.surfaceAlt),
                      ),
                      const SizedBox(height: Insets.sm),
                      FractionallySizedBox(widthFactor: 0.35, child: _Bar(height: 10, color: c.surfaceAlt)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bloque de párrafos simulados (contenido de texto en carga).
class SkeletonParagraphs extends StatelessWidget {
  const SkeletonParagraphs({super.key, this.lines = 8, this.label = 'Cargando'});

  final int lines;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(Insets.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FractionallySizedBox(widthFactor: 0.6, child: _Bar(height: 22, color: c.surfaceAlt)),
              const SizedBox(height: Insets.lg),
              for (var i = 0; i < lines; i++) ...[
                FractionallySizedBox(
                  widthFactor: i % 4 == 3 ? 0.5 : 0.92 - (i % 2) * 0.08,
                  child: _Bar(height: 12, color: c.surfaceAlt),
                ),
                const SizedBox(height: Insets.md),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height, required this.color});
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
  );
}
