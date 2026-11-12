import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Fila con fondo de superficie, toque y pulsación larga con la posición global (para anclar el
/// menú contextual en Android). Mínimo 48 de alto; el contenido define el resto.
class PressableRow extends StatefulWidget {
  const PressableRow({super.key, required this.child, this.onTap, this.onLongPress, this.minHeight = 56, this.color});

  final Widget child;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onLongPress;
  final double minHeight;
  final Color? color;

  @override
  State<PressableRow> createState() => _PressableRowState();
}

class _PressableRowState extends State<PressableRow> {
  Offset? _lastDown;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.color ?? context.colors.surface,
      child: Listener(
        onPointerDown: (e) => _lastDown = e.position,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress == null
              ? null
              : () {
                  final box = context.findRenderObject() as RenderBox?;
                  final fallback = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
                  widget.onLongPress!(_lastDown ?? fallback);
                },
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: widget.minHeight < Insets.minTouch ? Insets.minTouch : widget.minHeight),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
