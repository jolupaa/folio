import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Cabecera con título grande que colapsa al desplazar (estilo iOS, válido en ambas plataformas):
/// el título grande forma parte del contenido y el título pequeño aparece en la barra al pasarlo.
class LargeTitleScrollView extends StatefulWidget {
  const LargeTitleScrollView({
    super.key,
    required this.title,
    required this.slivers,
    this.above,
    this.below,
    this.actions = const [],
    this.onRefresh,
    this.controller,
  });

  final String title;

  /// Línea discreta sobre el título (p. ej. ruta de carpetas).
  final Widget? above;

  /// Contenido bajo el título (p. ej. acción de IA compacta).
  final Widget? below;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;

  @override
  State<LargeTitleScrollView> createState() => _LargeTitleScrollViewState();
}

class _LargeTitleScrollViewState extends State<LargeTitleScrollView> {
  ScrollController? _own;
  ScrollController get _controller => widget.controller ?? (_own ??= ScrollController());
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(LargeTitleScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _own)?.removeListener(_onScroll);
      _controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _own?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final collapsed = _controller.hasClients && _controller.offset > 40;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final scroll = CustomScrollView(
      controller: _controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: c.background,
          scrolledUnderElevation: 0.5,
          title: ExcludeSemantics(
            excluding: !_collapsed,
            child: AnimatedOpacity(
              opacity: _collapsed ? 1 : 0,
              duration: Motion.of(context, Motion.fast),
              child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          actions: [...widget.actions, const SizedBox(width: Insets.xs)],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Insets.gutter + Insets.xs, 0, Insets.gutter, Insets.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?widget.above,
                Semantics(
                  header: true,
                  child: Text(widget.title, style: context.text.displaySmall),
                ),
                ?widget.below,
              ],
            ),
          ),
        ),
        ...widget.slivers,
        const SliverToBoxAdapter(child: SizedBox(height: Insets.xl)),
      ],
    );
    if (widget.onRefresh == null) return scroll;
    return RefreshIndicator.adaptive(onRefresh: widget.onRefresh!, edgeOffset: kToolbarHeight, child: scroll);
  }
}
