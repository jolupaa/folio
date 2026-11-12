import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/navigation.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/highlighted_text.dart';
import 'search_service.dart';

/// Pausa entre pulsaciones antes de lanzar la búsqueda incremental.
const searchDebounce = Duration(milliseconds: 120);

/// Contenido de pantalla + barra de búsqueda persistente en la parte inferior (docs/DESIGN.md §7).
///
/// - La barra respeta el área segura y sube con el teclado (`viewInsets`); el teclado solo se abre
///   al tocarla. La pantalla que la usa debe tener `Scaffold(resizeToAvoidBottomInset: false)`.
/// - Al activarla, el panel de resultados aparece sobre la barra (cubre [body]); con
///   [compactResults] solo ocupa la parte inferior y solo si hay resultados (búsqueda en una nota).
/// - Chip «Toda la biblioteca» para ampliar el ámbito mientras dure la búsqueda.
/// - [bottomOverride] sustituye la barra (p. ej. barra de formato en edición) sin reconstruir [body].
class BottomSearchBar extends ConsumerStatefulWidget {
  const BottomSearchBar({
    super.key,
    required this.body,
    required this.scope,
    required this.placeholder,
    this.trailing,
    this.controller,
    this.focusNode,
    this.allowWiden,
    this.compactResults = false,
    this.compactTitle = 'Coincidencias en adjuntos',
    this.hitFilter,
    this.onHitTap,
    this.onQueryChanged,
    this.onSubmitted,
    this.accessory,
    this.bottomOverride,
    this.onActiveChanged,
    this.limit = 50,
  });

  final Widget body;
  final SearchScope scope;

  /// «Buscar en todas las notas», «Buscar en Física», «Buscar en esta nota».
  final String placeholder;

  /// Acción a la derecha de la barra cuando no se busca (p. ej. botón componer).
  final Widget? trailing;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Muestra el chip «Toda la biblioteca». Por defecto, si el ámbito no es ya la biblioteca.
  final bool? allowWiden;
  final bool compactResults;
  final String compactTitle;
  final bool Function(SearchHit hit)? hitFilter;

  /// Por defecto abre la nota resaltando la consulta.
  final void Function(SearchHit hit, String query)? onHitTap;

  /// Se llama en cada cambio de texto (sin esperar), p. ej. para buscar dentro de la nota.
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onSubmitted;

  /// Widget dentro de la píldora cuando hay texto (p. ej. «2 de 5» y flechas).
  final Widget? accessory;
  final Widget? bottomOverride;
  final ValueChanged<bool>? onActiveChanged;
  final int limit;

  @override
  ConsumerState<BottomSearchBar> createState() => BottomSearchBarState();
}

class BottomSearchBarState extends ConsumerState<BottomSearchBar> {
  late TextEditingController _controller;
  late FocusNode _focus;
  bool _ownsController = false;
  bool _ownsFocus = false;

  Timer? _debounce;
  int _requestSeq = 0;
  bool _widened = false;
  bool _loading = false;
  Object? _error;
  SearchResults? _results;
  String _lastQuery = '';
  bool _active = false;

  String get query => _controller.text.trim();
  bool get isActive => _active;
  bool get _allowWiden => widget.allowWiden ?? widget.scope.kind != SearchScopeKind.library_;
  SearchScope get _effectiveScope => _widened ? const SearchScope(kind: SearchScopeKind.library_) : widget.scope;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    _ownsFocus = widget.focusNode == null;
    _focus = widget.focusNode ?? FocusNode(debugLabel: 'BottomSearchBar');
    _controller.addListener(_onTextChanged);
    _focus.addListener(_updateActive);
    _lastQuery = query;
    _active = _focus.hasFocus || _controller.text.isNotEmpty;
    if (_lastQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch();
      });
    }
  }

  void _detach() {
    _controller.removeListener(_onTextChanged);
    _focus.removeListener(_updateActive);
    if (_ownsController) _controller.dispose();
    if (_ownsFocus) _focus.dispose();
  }

  @override
  void didUpdateWidget(BottomSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.focusNode != widget.focusNode) {
      _detach();
      _attach();
    }
    if (oldWidget.scope != widget.scope && query.isNotEmpty) _runSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _detach();
    super.dispose();
  }

  /// Enfoca la barra (abre el teclado).
  void focus() => _focus.requestFocus();

  /// Cierra la búsqueda: limpia el texto, quita el foco y restablece el ámbito.
  void cancel() {
    _debounce?.cancel();
    _requestSeq++;
    _controller.clear();
    _focus.unfocus();
    setState(() {
      _widened = false;
      _results = null;
      _error = null;
      _loading = false;
    });
    _updateActive();
  }

  void _updateActive() {
    final active = _focus.hasFocus || _controller.text.isNotEmpty;
    if (active != _active) {
      setState(() => _active = active);
      widget.onActiveChanged?.call(active);
    } else {
      setState(() {});
    }
  }

  void _onTextChanged() {
    final q = query;
    _updateActive();
    if (q == _lastQuery) return;
    _lastQuery = q;
    widget.onQueryChanged?.call(q);
    _debounce?.cancel();
    if (q.isEmpty) {
      _requestSeq++;
      setState(() {
        _results = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(searchDebounce, _runSearch);
  }

  Future<void> _runSearch() async {
    _debounce?.cancel();
    final q = query;
    final seq = ++_requestSeq;
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(searchFunctionProvider)(q, _effectiveScope, widget.limit);
      if (!mounted || seq != _requestSeq) return; // respuesta vieja: se descarta
      setState(() {
        _results = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _toggleWiden() {
    setState(() => _widened = !_widened);
    if (query.isNotEmpty) _runSearch();
  }

  void _openHit(SearchHit hit) {
    final q = query;
    _focus.unfocus();
    if (widget.onHitTap != null) {
      widget.onHitTap!(hit, q);
    } else {
      context.openNote(hit.noteId, kind: hit.noteKind, highlight: q);
    }
  }

  List<SearchHit> get _hits {
    final hits = _results?.hits ?? const <SearchHit>[];
    final f = widget.hitFilter;
    return f == null ? hits : hits.where(f).toList();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = math.max(media.viewInsets.bottom, media.padding.bottom);
    final override = widget.bottomOverride;
    final showPanel = override == null && _active;

    return PopScope(
      canPop: !showPanel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showPanel) cancel();
      },
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: widget.body),
                if (showPanel && !widget.compactResults) Positioned.fill(child: _buildFullPanel(context)),
                if (showPanel && widget.compactResults)
                  Positioned(left: 0, right: 0, bottom: 0, child: _buildCompactPanel(context)),
              ],
            ),
          ),
          if (override != null)
            Padding(
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: override,
            )
          else
            _buildBar(context, bottomInset),
        ],
      ),
    );
  }

  Widget _buildBar(BuildContext context, double bottomInset) {
    final c = context.colors;
    final hasText = _controller.text.isNotEmpty;
    return Material(
      color: c.background,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator, width: 0.6))),
        child: Padding(
          padding: EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.sm, Insets.sm + bottomInset),
          child: Row(
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(Insets.radiusButton),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: Insets.md),
                        ExcludeSemantics(child: Icon(Icons.search_rounded, size: 22, color: c.textSecondary)),
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            textInputAction: TextInputAction.search,
                            onSubmitted: widget.onSubmitted,
                            style: context.text.bodyLarge,
                            maxLines: 1,
                            decoration: InputDecoration(
                              hintText: widget.placeholder,
                              hintMaxLines: 1,
                              filled: false,
                              isCollapsed: true,
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                        if (hasText && widget.accessory != null) widget.accessory!,
                        if (hasText)
                          IconButton(
                            tooltip: 'Borrar texto',
                            onPressed: () {
                              _controller.clear();
                              _focus.requestFocus();
                            },
                            icon: Icon(Icons.cancel_rounded, size: 20, color: c.textTertiary),
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
                          )
                        else
                          const SizedBox(width: Insets.md),
                      ],
                    ),
                  ),
                ),
              ),
              if (_active)
                TextButton(onPressed: cancel, child: const Text('Cancelar'))
              else if (widget.trailing != null) ...[
                const SizedBox(width: Insets.xs),
                widget.trailing!,
              ] else
                const SizedBox(width: Insets.sm),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScopeChips(BuildContext context) {
    if (!_allowWiden) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xs),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilterChip(
          label: const Text('Toda la biblioteca'),
          selected: _widened,
          onSelected: (_) => _toggleWiden(),
          avatar: _widened ? null : Icon(Icons.travel_explore_rounded, size: 18, color: context.colors.accent),
          showCheckmark: true,
          tooltip: _widened ? 'Volver a buscar solo en el ámbito actual' : 'Ampliar la búsqueda a toda la biblioteca',
        ),
      ),
    );
  }

  Widget _buildFullPanel(BuildContext context) {
    final c = context.colors;
    final q = query;
    final hits = _hits;
    Widget content;
    if (_error != null) {
      content = EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'No se pudo buscar',
        message: humanError(_error!),
        actionLabel: 'Reintentar',
        onAction: _runSearch,
        compact: true,
      );
    } else if (q.isEmpty) {
      content = EmptyState(
        icon: Icons.manage_search_rounded,
        title: 'Escribe para buscar',
        message: 'Títulos, texto de las notas y texto reconocido en fotos y PDF.',
        compact: true,
      );
    } else if (_results == null || (_loading && _results!.query != q && hits.isEmpty)) {
      content = const SizedBox.shrink();
    } else if (hits.isEmpty) {
      content = EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Sin resultados',
        message: 'No hay coincidencias para «$q».',
        actionLabel: _allowWiden && !_widened ? 'Buscar en toda la biblioteca' : null,
        onAction: _allowWiden && !_widened ? _toggleWiden : null,
        compact: true,
      );
    } else {
      content = ListView.separated(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: Insets.lg),
        itemCount: hits.length + 1,
        separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : Divider(indent: Insets.gutter + 44, height: 0.6, color: c.separator),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.xs, Insets.gutter, Insets.xs),
              child: Semantics(
                liveRegion: true,
                child: Text(Fmt.count(hits.length, 'resultado', 'resultados'), style: context.text.bodySmall),
              ),
            );
          }
          final hit = hits[i - 1];
          return SearchHitTile(hit: hit, onTap: () => _openHit(hit));
        },
      );
    }
    return Material(
      color: c.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildScopeChips(context),
          SizedBox(
            height: 2,
            child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildCompactPanel(BuildContext context) {
    final c = context.colors;
    final hits = _hits;
    if (query.isEmpty || hits.isEmpty) return const SizedBox.shrink();
    final maxHeight = MediaQuery.sizeOf(context).height * 0.32;
    return Material(
      color: c.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Insets.radiusGroup)),
        side: BorderSide(color: c.separator, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.md, Insets.gutter, Insets.xs),
              child: Semantics(
                header: true,
                child: Text('${widget.compactTitle} · ${hits.length}', style: context.text.labelMedium),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: hits.length,
                itemBuilder: (context, i) => SearchHitTile(hit: hits[i], onTap: () => _openHit(hits[i]), dense: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fila de resultado: título, fragmento resaltado, ubicación y tipo.
class SearchHitTile extends StatelessWidget {
  const SearchHitTile({super.key, required this.hit, required this.onTap, this.dense = false});

  final SearchHit hit;
  final VoidCallback onTap;
  final bool dense;

  static String locationLabel(SearchHit hit) {
    final parts = <String>[Fmt.location(hit.location)];
    if (hit.matchedIn == MatchField.attachment) {
      final name = hit.attachmentName;
      if (name != null && name.isNotEmpty) parts.add(name);
      if (hit.pageIndex != null) parts.add('Página ${hit.pageIndex! + 1}');
    }
    return parts.join(' · ');
  }

  static ({IconData icon, String label}) kindOf(SearchHit hit) {
    if (hit.matchedIn == MatchField.attachment) {
      final pdf = (hit.attachmentName ?? '').toLowerCase().endsWith('.pdf');
      return (icon: pdf ? Icons.picture_as_pdf_rounded : Icons.image_rounded, label: pdf ? 'PDF adjunto' : 'Imagen adjunta');
    }
    if (hit.noteKind == NoteKind.board) return (icon: Icons.draw_rounded, label: 'Pizarra');
    return (icon: Icons.description_rounded, label: 'Nota');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final kind = kindOf(hit);
    final title = hit.title.trim().isEmpty ? 'Sin título' : hit.title.trim();
    final location = locationLabel(hit);
    final snippet = hit.snippet.trim();
    return Semantics(
      button: true,
      label: '$title. ${kind.label}. ${stripHighlights(snippet)}. $location',
      excludeSemantics: true,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: dense ? 56 : 68),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Insets.gutter, vertical: dense ? Insets.sm : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(8)),
                    child: Icon(kind.icon, size: 18, color: c.accent),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleMedium),
                      if (snippet.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        HighlightedText(
                          snippet,
                          maxLines: 2,
                          style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(location, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
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
