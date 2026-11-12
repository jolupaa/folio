import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';

/// Acción revelada al deslizar una fila.
class SwipeAction {
  const SwipeAction({required this.icon, required this.label, required this.color, required this.onTap, this.foreground});

  final IconData icon;
  final String label;
  final Color color;
  final Color? foreground;
  final VoidCallback onTap;
}

/// Fila deslizable con acciones al inicio y al final (docs/DESIGN.md §5). Las acciones se exponen
/// también como acciones semánticas personalizadas (lectores de pantalla) y deben estar siempre en
/// el menú contextual de la fila.
class SwipeActions extends StatefulWidget {
  const SwipeActions({super.key, required this.child, this.leading = const [], this.trailing = const []});

  final Widget child;
  final List<SwipeAction> leading;
  final List<SwipeAction> trailing;

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

/// Fila abierta actualmente (solo una a la vez).
final _openRow = ValueNotifier<Object?>(null);

class _SwipeActionsState extends State<SwipeActions> with SingleTickerProviderStateMixin {
  static const _actionWidth = 76.0;

  /// Margen junto al borde izquierdo reservado al gesto «atrás» de iOS.
  static const _edgeGuard = 24.0;

  late final AnimationController _anim = AnimationController.unbounded(vsync: this);
  double get _leadingExtent => widget.leading.length * _actionWidth;
  double get _trailingExtent => widget.trailing.length * _actionWidth;

  @override
  void initState() {
    super.initState();
    _openRow.addListener(_onOtherOpened);
  }

  @override
  void dispose() {
    _openRow.removeListener(_onOtherOpened);
    if (_openRow.value == this) _openRow.value = null;
    _anim.dispose();
    super.dispose();
  }

  void _onOtherOpened() {
    if (_openRow.value != this && _anim.value != 0) _animateTo(0);
  }

  void _animateTo(double target) {
    final duration = Motion.of(context, Motion.fast);
    if (duration == Duration.zero) {
      _anim.value = target;
    } else {
      _anim.animateTo(target, duration: duration, curve: Motion.curve);
    }
    if (target != 0) {
      _openRow.value = this;
    } else if (_openRow.value == this) {
      _openRow.value = null;
    }
  }

  void _close() => _animateTo(0);

  void _onUpdate(DragUpdateDetails d) {
    var v = _anim.value + d.primaryDelta!;
    final maxLead = _leadingExtent;
    final maxTrail = -_trailingExtent;
    // Resistencia elástica más allá de la extensión de las acciones.
    if (v > maxLead) v = maxLead + (v - maxLead) * 0.3;
    if (v < maxTrail) v = maxTrail + (v - maxTrail) * 0.3;
    if (maxLead == 0 && v > 0) v = 0;
    if (maxTrail == 0 && v < 0) v = 0;
    _anim.value = v;
  }

  void _onEnd(DragEndDetails d) {
    final v = _anim.value;
    final velocity = d.primaryVelocity ?? 0;
    if (v > 0) {
      final open = v > _leadingExtent / 2 || velocity > 600;
      _animateTo(open && velocity > -600 ? _leadingExtent : 0);
    } else if (v < 0) {
      final open = -v > _trailingExtent / 2 || velocity < -600;
      _animateTo(open && velocity < 600 ? -_trailingExtent : 0);
    }
    if (_anim.value != 0) HapticFeedback.selectionClick();
  }

  Widget _buildAction(SwipeAction a) {
    final fg = a.foreground ?? Colors.white;
    return SizedBox(
      width: _actionWidth,
      child: Material(
        color: a.color,
        child: InkWell(
          onTap: () {
            _close();
            a.onTap();
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(a.icon, color: fg, size: 22),
              const SizedBox(height: 2),
              Text(
                a.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final semanticsActions = <CustomSemanticsAction, VoidCallback>{
      for (final a in [...widget.leading, ...widget.trailing]) CustomSemanticsAction(label: a.label): a.onTap,
    };
    return Semantics(
      customSemanticsActions: semanticsActions,
      child: RawGestureDetector(
        gestures: {
          _EdgeAwareHorizontalDrag: GestureRecognizerFactoryWithHandlers<_EdgeAwareHorizontalDrag>(
            () => _EdgeAwareHorizontalDrag(_edgeGuard),
            (r) => r
              ..onUpdate = _onUpdate
              ..onEnd = _onEnd,
          ),
        },
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _anim,
            child: widget.child,
            builder: (context, child) {
              final v = _anim.value;
              return Stack(
                children: [
                  if (v > 0)
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: Row(children: [for (final a in widget.leading) _buildAction(a), const Spacer()]),
                      ),
                    ),
                  if (v < 0)
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: Row(children: [const Spacer(), for (final a in widget.trailing) _buildAction(a)]),
                      ),
                    ),
                  Transform.translate(
                    offset: Offset(v, 0),
                    child: v == 0
                        ? child
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _close,
                            child: AbsorbPointer(child: child),
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

class _EdgeAwareHorizontalDrag extends HorizontalDragGestureRecognizer {
  _EdgeAwareHorizontalDrag(this.edge);
  final double edge;

  @override
  bool isPointerAllowed(PointerEvent event) => event.position.dx > edge && super.isPointerAllowed(event);
}
