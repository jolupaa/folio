import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Grupo de filas con esquinas redondeadas sobre el fondo neutro (estilo lista insetada).
class GroupedSection extends StatelessWidget {
  const GroupedSection({super.key, this.header, this.trailing, required this.children, this.footer});

  final String? header;
  final Widget? trailing;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Divider(indent: Insets.lg + 40, height: 0.6, color: c.separator));
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.sm, Insets.xs, Insets.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(header!, style: context.text.titleMedium?.copyWith(fontSize: 20)),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(Insets.radiusGroup),
            child: Material(
              color: c.surface,
              child: Column(children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.sm, Insets.xs, 0),
              child: Text(footer!, style: context.text.bodySmall),
            ),
        ],
      ),
    );
  }
}
