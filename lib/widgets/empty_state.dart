import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Estado vacío/aviso: icono en círculo suave + título + una línea + acción (docs/DESIGN.md §8).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? Insets.lg : Insets.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compact ? 56 : 72,
                height: compact ? 56 : 72,
                decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
                child: Icon(icon, size: compact ? 26 : 32, color: c.accent),
              ),
              SizedBox(height: compact ? Insets.md : Insets.lg),
              Text(title, textAlign: TextAlign.center, style: context.text.titleMedium),
              if (message != null) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: Insets.lg),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
              if (secondaryLabel != null && onSecondary != null)
                TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ),
        ),
      ),
    );
  }
}
