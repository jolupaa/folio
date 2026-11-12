import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Esqueleto discreto de un grupo de filas (estado de carga, docs/DESIGN.md §8). Aparece con un
/// pequeño retardo para no parpadear en cargas rápidas.
class SkeletonGroup extends StatefulWidget {
  const SkeletonGroup({super.key, this.rows = 3, this.twoLine = false, this.header = false});

  final int rows;
  final bool twoLine;
  final bool header;

  @override
  State<SkeletonGroup> createState() => _SkeletonGroupState();
}

class _SkeletonGroupState extends State<SkeletonGroup> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(6)),
    );
    return Semantics(
      label: 'Cargando',
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: Motion.of(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.header)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.sm, Insets.xs, Insets.sm),
                  child: bar(120, 18),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(Insets.radiusGroup),
                child: ColoredBox(
                  color: c.surface,
                  child: Column(
                    children: [
                      for (var i = 0; i < widget.rows; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: 14),
                          child: Row(
                            children: [
                              bar(24, 24),
                              const SizedBox(width: Insets.lg),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    FractionallySizedBox(widthFactor: 0.55, child: bar(double.infinity, 14)),
                                    if (widget.twoLine) ...[
                                      const SizedBox(height: 8),
                                      FractionallySizedBox(widthFactor: 0.85, child: bar(double.infinity, 12)),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
