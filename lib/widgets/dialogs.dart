import 'package:flutter/material.dart';

/// Confirmación adaptativa (Cupertino en iOS, Material en Android).
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final r = await showAdaptiveDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        adaptiveAction(ctx, label: 'Cancelar', onPressed: () => Navigator.pop(ctx, false)),
        adaptiveAction(
          ctx,
          label: confirmLabel,
          destructive: destructive,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Pide un texto (nombre de carpeta, título…). Devuelve null si se cancela.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  required String confirmLabel,
}) async {
  final controller = TextEditingController(text: initial);
  final r = await showAdaptiveDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(title),
      content: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
      ),
      actions: [
        adaptiveAction(ctx, label: 'Cancelar', onPressed: () => Navigator.pop(ctx)),
        adaptiveAction(ctx, label: confirmLabel, onPressed: () => Navigator.pop(ctx, controller.text)),
      ],
    ),
  );
  // No se libera aquí: el diálogo sigue usándolo durante la animación de cierre.
  WidgetsBinding.instance.addPostFrameCallback((_) => Future<void>.delayed(const Duration(seconds: 1), controller.dispose));
  final t = r?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

Widget adaptiveAction(
  BuildContext context, {
  required String label,
  required VoidCallback onPressed,
  bool destructive = false,
}) {
  final theme = Theme.of(context);
  final isIOS = theme.platform == TargetPlatform.iOS || theme.platform == TargetPlatform.macOS;
  final style = destructive ? TextStyle(color: theme.colorScheme.error) : null;
  if (isIOS) {
    return TextButton(
      onPressed: onPressed,
      child: Text(label, style: style),
    );
  }
  return TextButton(
    onPressed: onPressed,
    child: Text(label, style: style),
  );
}
