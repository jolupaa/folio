import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';

/// Acción de un menú contextual adaptativo.
class MenuAction<T> {
  const MenuAction({required this.value, required this.label, required this.icon, this.destructive = false, this.enabled = true});

  final T value;
  final String label;
  final IconData icon;
  final bool destructive;
  final bool enabled;
}

/// Menú contextual adaptativo: hoja de acciones Cupertino en iOS; menú emergente Material en
/// Android, anclado a [anchor] (posición global de la pulsación) o al widget de [context].
/// Devuelve el valor elegido o null si se cancela.
Future<T?> showAdaptiveMenu<T>(
  BuildContext context, {
  required List<MenuAction<T>> actions,
  String? title,
  String? message,
  Offset? anchor,
}) async {
  final visible = actions.where((a) => a.enabled).toList();
  if (visible.isEmpty) return null;
  HapticFeedback.selectionClick();
  if (context.isCupertino) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final a in visible)
            CupertinoActionSheetAction(
              isDestructiveAction: a.destructive,
              onPressed: () => Navigator.pop(ctx, a.value),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(a.icon, size: 22, color: a.destructive ? CupertinoColors.destructiveRed.resolveFrom(ctx) : null),
                  const SizedBox(width: Insets.sm),
                  Flexible(child: Text(a.label)),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancelar'),
        ),
      ),
    );
  }

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  RelativeRect position;
  final box = context.findRenderObject() as RenderBox?;
  if (overlay == null) {
    position = RelativeRect.fill;
  } else if (anchor != null) {
    final local = overlay.globalToLocal(anchor);
    position = RelativeRect.fromRect(local & const Size(1, 1), Offset.zero & overlay.size);
  } else if (box != null && box.hasSize) {
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    position = RelativeRect.fromRect(Rect.fromPoints(topLeft, bottomRight), Offset.zero & overlay.size);
  } else {
    position = RelativeRect.fill;
  }
  final c = context.colors;
  return showMenu<T>(
    context: context,
    position: position,
    color: c.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Insets.radiusButton)),
    items: [
      if (title != null)
        PopupMenuItem<T>(
          enabled: false,
          height: 36,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium),
        ),
      for (final a in visible)
        PopupMenuItem<T>(
          value: a.value,
          child: Row(
            children: [
              Icon(a.icon, size: 22, color: a.destructive ? c.danger : c.accent),
              const SizedBox(width: Insets.md),
              Flexible(
                child: Text(a.label, style: a.destructive ? TextStyle(color: c.danger) : null),
              ),
            ],
          ),
        ),
    ],
  );
}
