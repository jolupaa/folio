import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/library.dart' as lib;
import '../../src/rust/api/types.dart';
import '../../widgets/adaptive_menu.dart';
import '../../widgets/empty_state.dart';
import '../ai/ai_entry.dart';
import '../capture/capture_entry.dart';
import '../library/folder_picker.dart';
import '../search/bottom_search_bar.dart';
import '../search/search_service.dart';
import 'blocks_codec.dart';

enum _NoteMenu { pin, move, trash }

enum _SaveState { idle, dirty, saving, saved, error }

/// Editor de una nota de texto: título, bloques (flutter_quill), adjuntos, guardado automático,
/// búsqueda dentro de la nota y acceso a la IA.
class NoteScreen extends ConsumerStatefulWidget {
  const NoteScreen({super.key, required this.noteId, this.highlight, this.blockId});

  final String noteId;
  final String? highlight;
  final String? blockId;

  @override
  ConsumerState<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends ConsumerState<NoteScreen> {
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  final _editorFocus = FocusNode();
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  final _editorKey = GlobalKey<QuillEditorState>();
  late final AppLifecycleListener _lifecycle;

  QuillController? _quill;
  StreamSubscription<DocChange>? _changes;
  Note? _note;
  Object? _loadError;
  List<NoteBlock> _blocks = const [];
  Map<String, Attachment> _attachments = const {};
  int _revision = 0;
  bool _pinned = false;
  String? _folderId;

  Timer? _debounce;
  _SaveState _save = _SaveState.idle;
  Future<void> _saveChain = Future.value();
  bool _loading = false;

  // Búsqueda dentro de la nota.
  List<TextMatch> _matches = const [];
  int _matchIndex = 0;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _flush, onPause: _flush);
    _title.addListener(_onTitleChanged);
    _editorFocus.addListener(_onFocus);
    _titleFocus.addListener(_onFocus);
    _load(initial: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_save == _SaveState.dirty) _saveNow();
    _lifecycle.dispose();
    _changes?.cancel();
    _quill?.dispose();
    _title.dispose();
    _titleFocus.dispose();
    _editorFocus.dispose();
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  bool get _editing => _editorFocus.hasFocus || _titleFocus.hasFocus;

  // ───────────── Carga y guardado ─────────────

  Future<void> _load({bool initial = false}) async {
    try {
      final note = await lib.getNote(id: widget.noteId);
      if (!mounted) return;
      final blocks = parseBlocks(note.bodyJson);
      final quill = QuillController(
        document: Document.fromDelta(blocksToDelta(blocks)),
        selection: const TextSelection.collapsed(offset: 0),
      );
      await _changes?.cancel();
      final old = _quill;
      _loading = true;
      _title.text = note.title;
      _loading = false;
      setState(() {
        _note = note;
        _loadError = null;
        _blocks = blocks;
        _attachments = {for (final a in note.attachments) a.id: a};
        _revision = note.revision;
        _pinned = note.pinned;
        _folderId = note.folderId;
        _quill = quill;
        _save = _SaveState.idle;
      });
      _changes = quill.document.changes.listen((_) => _markDirty());
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      if (initial) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _applyInitialTarget(note, blocks));
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _applyInitialTarget(Note note, List<NoteBlock> blocks) {
    final quill = _quill;
    if (quill == null || !mounted) return;
    if (widget.blockId != null) {
      final i = blocks.indexWhere((b) => b.id == widget.blockId);
      if (i >= 0) {
        final r = blockRanges(blocks)[i];
        _select(r.start, r.start + r.length);
        return;
      }
    }
    final h = widget.highlight;
    if (h != null && h.trim().isNotEmpty) {
      final found = ref.read(findInTextProvider)(quill.document.toPlainText(), h);
      if (found.isNotEmpty) {
        _select(found.first.start, found.first.end);
      } else if (note.title.isEmpty && blocks.isEmpty) {
        // nada que resaltar
      }
      return;
    }
    if (note.title.isEmpty && blocks.isEmpty) _titleFocus.requestFocus();
  }

  void _onTitleChanged() {
    if (!_loading && _note != null && _title.text != _note!.title) _markDirty();
  }

  void _markDirty() {
    if (_loading || _quill == null) return;
    if (_save != _SaveState.dirty && mounted) setState(() => _save = _SaveState.dirty);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _saveNow);
  }

  void _flush() {
    _debounce?.cancel();
    if (_save == _SaveState.dirty) _saveNow();
  }

  /// Guarda el estado actual. Las llamadas se encadenan para no solaparse.
  Future<void> _saveNow() {
    final quill = _quill;
    if (quill == null) return Future.value();
    final title = _title.text;
    final blocks = deltaToBlocks(quill.document.toDelta(), previous: _blocks);
    final body = encodeBlocks(blocks);
    _blocks = blocks;
    final revisionNotifier = ref.read(libraryRevisionProvider.notifier);
    if (mounted) setState(() => _save = _SaveState.saving);
    return _saveChain = _saveChain.then((_) async {
      try {
        final r = await lib.saveNote(
          id: widget.noteId,
          title: title,
          bodyJson: body,
          baseRevision: _revision,
        );
        _revision = r.revision;
        revisionNotifier.bump();
        if (mounted && _save == _SaveState.saving) setState(() => _save = _SaveState.saved);
      } catch (e) {
        if (mounted) {
          setState(() => _save = _SaveState.error);
          showErrorSnack(context, e, prefix: 'No se pudo guardar');
        }
      }
    });
  }

  Future<void> _saveAndWait() async {
    _debounce?.cancel();
    if (_save == _SaveState.dirty) await _saveNow();
    await _saveChain;
  }

  // ───────────── Selección y búsqueda ─────────────

  void _select(int start, int end) {
    final quill = _quill;
    if (quill == null) return;
    final max = quill.document.length - 1;
    final s = start.clamp(0, max);
    final e = end.clamp(0, max);
    final wasEditing = _editorFocus.hasFocus;
    quill.updateSelection(TextSelection(baseOffset: s, extentOffset: e), ChangeSource.local);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Resaltar un resultado no debe abrir el teclado ni pasar a modo edición.
      if (!wasEditing && _editorFocus.hasFocus) _editorFocus.unfocus();
      try {
        _editorKey.currentState?.editableTextKey.currentState?.bringIntoView(TextPosition(offset: s));
      } catch (_) {
        // Sin desplazamiento automático: la selección sigue marcada.
      }
    });
  }

  void _onQuery(String query) {
    final quill = _quill;
    if (quill == null) return;
    final matches = query.trim().isEmpty
        ? const <TextMatch>[]
        : ref.read(findInTextProvider)(quill.document.toPlainText(), query);
    setState(() {
      _matches = matches;
      _matchIndex = 0;
    });
    if (matches.isNotEmpty) _select(matches.first.start, matches.first.end);
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + delta) % _matches.length);
    final m = _matches[_matchIndex];
    _select(m.start, m.end);
  }

  // ───────────── Formato ─────────────

  Map<String, Attribute> get _lineAttrs => _quill?.getSelectionStyle().attributes ?? const {};

  void _cycleHeading() {
    final quill = _quill!;
    final level = _lineAttrs[Attribute.header.key]?.value as int?;
    for (final Attribute a in [Attribute.ul, Attribute.blockQuote]) {
      if (_lineAttrs.containsKey(a.key)) quill.formatSelection(Attribute.clone(a, null));
    }
    quill.formatSelection(switch (level) {
      null => Attribute.h1,
      1 => Attribute.h2,
      2 => Attribute.h3,
      _ => Attribute.clone(Attribute.header, null),
    });
    setState(() {});
  }

  void _toggleList(Attribute<String?> attr) {
    final quill = _quill!;
    final current = _lineAttrs[Attribute.list.key]?.value as String?;
    final same = current == attr.value || (attr == Attribute.unchecked && current == 'checked');
    if (_lineAttrs.containsKey(Attribute.header.key))
      quill.formatSelection(Attribute.clone(Attribute.header, null));
    if (_lineAttrs.containsKey(Attribute.blockQuote.key))
      quill.formatSelection(Attribute.clone(Attribute.blockQuote, null));
    quill.formatSelection(same ? Attribute.clone(Attribute.list, null) : attr);
    setState(() {});
  }

  void _toggleQuote() {
    final quill = _quill!;
    final on = _lineAttrs.containsKey(Attribute.blockQuote.key);
    for (final Attribute a in [Attribute.header, Attribute.list]) {
      if (_lineAttrs.containsKey(a.key)) quill.formatSelection(Attribute.clone(a, null));
    }
    quill.formatSelection(on ? Attribute.clone(Attribute.blockQuote, null) : Attribute.blockQuote);
    setState(() {});
  }

  void _indent(int delta) {
    final quill = _quill!;
    if (!_lineAttrs.containsKey(Attribute.list.key)) return;
    final level = ((_lineAttrs[Attribute.indent.key]?.value as int?) ?? 0) + delta;
    quill.formatSelection(
      level <= 0 ? Attribute.clone(Attribute.indent, null) : Attribute.getIndentLevel(level.clamp(1, 3)),
    );
    setState(() {});
  }

  /// Inserta un bloque embebido en una línea propia en la posición del cursor.
  void _insertEmbed(NoteBlock block) {
    final quill = _quill!;
    final doc = quill.document;
    var index = quill.selection.isValid ? quill.selection.extentOffset : doc.length - 1;
    index = index.clamp(0, doc.length - 1);
    final plain = doc.toPlainText();
    // Si el cursor está en una línea con texto, el adjunto va en una línea nueva debajo.
    final lineEnd = plain.indexOf('\n', index);
    final lineStart = index == 0 ? 0 : plain.lastIndexOf('\n', index - 1) + 1;
    final end = lineEnd < 0 ? doc.length - 1 : lineEnd;
    if (end > lineStart) {
      quill.replaceText(end, 0, '\n', null);
      index = end + 1;
    } else {
      index = lineStart;
    }
    quill.replaceText(
      index,
      0,
      BlockEmbed(FolioEmbeds.typeFor(block.type), FolioEmbeds.dataFor(block)),
      null,
    );
    quill.replaceText(index + 1, 0, '\n', TextSelection.collapsed(offset: index + 2));
  }

  Future<void> _attach(AttachKind kind) async {
    await _saveAndWait();
    if (!mounted) return;
    final att = await pickAndAttach(context, noteId: widget.noteId, kind: kind);
    if (att == null || !mounted) return;
    setState(() => _attachments = {..._attachments, att.id: att});
    _insertEmbed(
      NoteBlock(
        id: newBlockId(),
        type: kind == AttachKind.pdf ? BlockType.pdf : BlockType.image,
        attachmentId: att.id,
      ),
    );
    await _saveAndWait();
  }

  Future<void> _scan() async {
    await _saveAndWait();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    final id = await startCapture(context, appendToNoteId: widget.noteId);
    if (id != null && mounted) await _load();
  }

  Future<void> _attachMenu() async {
    final choice = await showAdaptiveMenu<String>(
      context,
      title: 'Añadir a la nota',
      actions: const [
        MenuAction(value: 'scan', label: 'Escanear apuntes (con OCR)', icon: Icons.document_scanner_rounded),
        MenuAction(value: 'image', label: 'Foto o imagen', icon: Icons.image_outlined),
        MenuAction(value: 'pdf', label: 'PDF', icon: Icons.picture_as_pdf_outlined),
        MenuAction(value: 'board_new', label: 'Nueva pizarra', icon: Icons.draw_rounded),
        MenuAction(value: 'board_link', label: 'Enlazar una pizarra', icon: Icons.link_rounded),
        MenuAction(value: 'divider', label: 'Línea divisoria', icon: Icons.horizontal_rule_rounded),
      ],
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'scan':
        await _scan();
      case 'image':
        await _attach(AttachKind.image);
      case 'pdf':
        await _attach(AttachKind.pdf);
      case 'divider':
        _insertEmbed(NoteBlock(id: newBlockId(), type: BlockType.divider));
      case 'board_new':
        try {
          final board = await lib.createNote(folderId: _folderId, kind: NoteKind.board, title: '');
          _insertEmbed(NoteBlock(id: newBlockId(), type: BlockType.boardLink, noteId: board.id));
          await _saveAndWait();
          if (mounted) await context.openNote(board.id, kind: NoteKind.board);
          ref.invalidate(_boardTitleProvider(board.id));
        } catch (e) {
          if (mounted) showErrorSnack(context, e);
        }
      case 'board_link':
        await _linkBoard();
    }
  }

  Future<void> _linkBoard() async {
    final all = await lib.listNotes(scope: NoteListScope.all, folderId: null);
    final boards = all.where((n) => n.kind == NoteKind.board).toList();
    if (!mounted) return;
    if (boards.isEmpty) {
      showInfoSnack(context, 'Todavía no hay pizarras. Crea una con «Nueva pizarra».');
      return;
    }
    final picked = await showModalBottomSheet<NoteSummary>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.sm),
              child: Text('Enlazar una pizarra', style: ctx.text.titleMedium),
            ),
            for (final b in boards)
              ListTile(
                leading: const Icon(Icons.draw_outlined),
                title: Text(b.title.trim().isEmpty ? 'Pizarra sin título' : b.title),
                onTap: () => Navigator.pop(ctx, b),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      _insertEmbed(NoteBlock(id: newBlockId(), type: BlockType.boardLink, noteId: picked.id));
    }
  }

  // ───────────── Menú ─────────────

  Future<void> _menu(Offset? anchor) async {
    final choice = await showAdaptiveMenu<_NoteMenu>(
      context,
      anchor: anchor,
      actions: [
        MenuAction(
          value: _NoteMenu.pin,
          label: _pinned ? 'Dejar de fijar' : 'Fijar',
          icon: _pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        ),
        const MenuAction(value: _NoteMenu.move, label: 'Mover a…', icon: Icons.drive_file_move_outlined),
        const MenuAction(
          value: _NoteMenu.trash,
          label: 'Mover a la papelera',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (choice == null || !mounted) return;
    final revision = ref.read(libraryRevisionProvider.notifier);
    try {
      switch (choice) {
        case _NoteMenu.pin:
          await lib.setNotePinned(id: widget.noteId, pinned: !_pinned);
          setState(() => _pinned = !_pinned);
          revision.bump();
        case _NoteMenu.move:
          final dest = await pickFolderDestination(
            context,
            title: 'Mover nota',
            currentFolderId: _folderId,
            currentIsRoot: _folderId == null,
          );
          if (dest == null || !mounted) return;
          await lib.moveNote(id: widget.noteId, folderId: dest.folderId);
          setState(() => _folderId = dest.folderId);
          revision.bump();
          if (mounted) showInfoSnack(context, 'Movida a ${dest.label}');
        case _NoteMenu.trash:
          await _saveAndWait();
          await lib.trashNote(id: widget.noteId);
          revision.bump();
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).maybePop();
          messenger.showSnackBar(
            SnackBar(
              content: const Text('Nota movida a la papelera'),
              action: SnackBarAction(
                label: 'Deshacer',
                onPressed: () async {
                  await lib.restoreFromTrash(kind: TrashKind.note, id: widget.noteId);
                  revision.bump();
                },
              ),
            ),
          );
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  String? get _selectedText {
    final quill = _quill;
    if (quill == null || quill.selection.isCollapsed || !quill.selection.isValid) return null;
    final t = quill.document
        .getPlainText(quill.selection.start, quill.selection.end - quill.selection.start)
        .trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _openAi() async {
    final selected = _selectedText;
    await _saveAndWait();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    await showAiActions(context, scope: Scopes.note(widget.noteId), selectedText: selected);
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final quill = _quill;
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudo abrir la nota',
          message: humanError(_loadError!),
          actionLabel: 'Reintentar',
          onAction: () => _load(initial: true),
        ),
      );
    }
    if (quill == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator.adaptive()),
      );
    }

    final saveLabel = switch (_save) {
      _SaveState.saving || _SaveState.dirty => 'Guardando…',
      _SaveState.saved => 'Guardado',
      _SaveState.error => 'Sin guardar',
      _SaveState.idle => '',
    };

    return PopScope(
      onPopInvokedWithResult: (didPop, _) => _flush(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: AnimatedOpacity(
            opacity: saveLabel.isEmpty ? 0 : 1,
            duration: Motion.of(context, Motion.fast),
            child: Text(
              saveLabel,
              style: context.text.bodySmall?.copyWith(
                color: _save == _SaveState.error ? c.danger : c.textSecondary,
              ),
            ),
          ),
          actions: [
            if (_editing)
              TextButton(onPressed: () => FocusScope.of(context).unfocus(), child: const Text('Listo'))
            else
              IconButton(
                tooltip: 'Asistente de IA sobre esta nota',
                icon: const Icon(Icons.auto_awesome_rounded),
                onPressed: _openAi,
              ),
            Builder(
              builder: (ctx) => IconButton(
                tooltip: 'Opciones de la nota',
                icon: const Icon(Icons.more_horiz_rounded),
                onPressed: () {
                  final box = ctx.findRenderObject() as RenderBox?;
                  _menu(box?.localToGlobal(box.size.bottomCenter(Offset.zero)));
                },
              ),
            ),
          ],
        ),
        body: BottomSearchBar(
          scope: Scopes.searchNote(widget.noteId),
          placeholder: 'Buscar en esta nota',
          controller: _searchController,
          compactResults: true,
          hitFilter: (h) => h.matchedIn == MatchField.attachment,
          onQueryChanged: _onQuery,
          onSubmitted: (_) => _step(1),
          onActiveChanged: (active) => setState(() {
            _searching = active;
            if (!active) _matches = const [];
          }),
          onHitTap: (hit, query) {
            if (hit.attachmentId != null) {
              context.openAttachment(hit.attachmentId!, page: hit.pageIndex, highlight: query);
            }
          },
          accessory: _searching && _searchController.text.trim().isNotEmpty
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _matches.isEmpty ? 'Sin resultados' : '${_matchIndex + 1} de ${_matches.length}',
                      style: context.text.bodySmall,
                    ),
                    IconButton(
                      tooltip: 'Anterior',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      onPressed: _matches.isEmpty ? null : () => _step(-1),
                    ),
                    IconButton(
                      tooltip: 'Siguiente',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      onPressed: _matches.isEmpty ? null : () => _step(1),
                    ),
                  ],
                )
              : null,
          bottomOverride: _editing ? _FormatBar(state: this) : null,
          body: ListView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            padding: const EdgeInsets.fromLTRB(
              Insets.gutter + Insets.xs,
              Insets.sm,
              Insets.gutter + Insets.xs,
              120,
            ),
            children: [
              TextField(
                controller: _title,
                focusNode: _titleFocus,
                style: context.text.headlineSmall?.copyWith(fontSize: 26, fontWeight: FontWeight.w700),
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _editorFocus.requestFocus(),
                decoration: InputDecoration(
                  hintText: 'Título',
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintStyle: context.text.headlineSmall?.copyWith(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: c.textTertiary,
                  ),
                ),
              ),
              const SizedBox(height: Insets.sm),
              QuillEditor(
                key: _editorKey,
                controller: quill,
                focusNode: _editorFocus,
                scrollController: _scroll,
                config: QuillEditorConfig(
                  scrollable: false,
                  placeholder: 'Escribe aquí…',
                  minHeight: 320,
                  textCapitalization: TextCapitalization.sentences,
                  embedBuilders: [
                    _AttachmentEmbed(FolioEmbeds.image, this),
                    _AttachmentEmbed(FolioEmbeds.pdf, this),
                    _BoardEmbed(),
                    _DividerEmbed(),
                    _UnknownEmbed(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Barra de formato sobre el teclado (sustituye a la de búsqueda mientras se edita).
class _FormatBar extends StatelessWidget {
  const _FormatBar({required this.state});
  final _NoteScreenState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final attrs = state._lineAttrs;
    final list = attrs[Attribute.list.key]?.value as String?;
    final inEditor = state._editorFocus.hasFocus;
    Widget btn(
      IconData icon,
      String tooltip,
      VoidCallback onTap, {
      bool active = false,
      bool enabled = true,
    }) => IconButton(
      tooltip: tooltip,
      isSelected: active,
      onPressed: enabled ? onTap : null,
      style: IconButton.styleFrom(
        backgroundColor: active ? c.accentSoft : null,
        foregroundColor: active ? c.accent : c.textPrimary,
      ),
      icon: Icon(icon),
    );
    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.separator, width: 0.6)),
        ),
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          children: [
            btn(
              Icons.title_rounded,
              'Título (H1, H2, H3, texto)',
              state._cycleHeading,
              active: attrs.containsKey(Attribute.header.key),
              enabled: inEditor,
            ),
            btn(
              Icons.format_list_bulleted_rounded,
              'Lista con viñetas',
              () => state._toggleList(Attribute.ul),
              active: list == 'bullet',
              enabled: inEditor,
            ),
            btn(
              Icons.format_list_numbered_rounded,
              'Lista numerada',
              () => state._toggleList(Attribute.ol),
              active: list == 'ordered',
              enabled: inEditor,
            ),
            btn(
              Icons.checklist_rounded,
              'Lista de tareas',
              () => state._toggleList(Attribute.unchecked),
              active: list == 'checked' || list == 'unchecked',
              enabled: inEditor,
            ),
            btn(
              Icons.format_quote_rounded,
              'Cita',
              state._toggleQuote,
              active: attrs.containsKey(Attribute.blockQuote.key),
              enabled: inEditor,
            ),
            btn(
              Icons.format_indent_decrease_rounded,
              'Reducir sangría',
              () => state._indent(-1),
              enabled: inEditor && list != null,
            ),
            btn(
              Icons.format_indent_increase_rounded,
              'Aumentar sangría',
              () => state._indent(1),
              enabled: inEditor && list != null,
            ),
            VerticalDivider(width: Insets.lg, indent: 12, endIndent: 12, color: c.separator),
            btn(Icons.attach_file_rounded, 'Adjuntar, escanear o enlazar', state._attachMenu),
            btn(Icons.document_scanner_outlined, 'Escanear apuntes', state._scan),
            IconButton(
              tooltip: 'Asistente de IA',
              onPressed: state._openAi,
              icon: Icon(Icons.auto_awesome_rounded, color: c.accent),
            ),
          ],
        ),
      ),
    );
  }
}

NoteBlock? _blockOf(EmbedContext e) {
  try {
    final data = e.node.value.data;
    final json = data is String ? jsonDecode(data) : data;
    return json is Map ? NoteBlock.fromJson(Map<String, Object?>.from(json)) : null;
  } catch (_) {
    return null;
  }
}

class _EmbedCard extends StatelessWidget {
  const _EmbedCard({required this.icon, required this.title, this.subtitle, this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Material(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(Insets.radiusGroup),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
              child: Row(
                children: [
                  Icon(icon, color: c.accent),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.titleSmall,
                        ),
                        if (subtitle != null) Text(subtitle!, style: context.text.bodySmall),
                      ],
                    ),
                  ),
                  if (onTap != null) Icon(Icons.chevron_right_rounded, color: c.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentEmbed extends EmbedBuilder {
  _AttachmentEmbed(this.key, this.state);
  @override
  final String key;
  final _NoteScreenState state;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final block = _blockOf(embedContext);
    final att = block?.attachmentId == null ? null : state._attachments[block!.attachmentId];
    if (att == null) {
      return const _EmbedCard(icon: Icons.broken_image_outlined, title: 'Adjunto no disponible');
    }
    void open() => context.openAttachment(att.id);
    if (att.kind == AttachmentKind.pdf) {
      return _EmbedCard(
        icon: Icons.picture_as_pdf_outlined,
        title: att.fileName,
        subtitle: att.pageCount == 1 ? 'PDF · 1 página' : 'PDF · ${att.pageCount} páginas',
        onTap: open,
      );
    }
    final ratio = (att.width != null && att.height != null && att.height! > 0)
        ? att.width! / att.height!
        : 4 / 3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Semantics(
        button: true,
        label: 'Imagen adjunta ${att.fileName}. Toca para ver el original y su texto.',
        child: GestureDetector(
          onTap: open,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Insets.radiusGroup),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: AspectRatio(
                aspectRatio: ratio.clamp(0.5, 3.0),
                child: Image.file(
                  File(att.path),
                  fit: BoxFit.cover,
                  cacheWidth: 1080,
                  errorBuilder: (_, _, _) => const _EmbedCard(
                    icon: Icons.broken_image_outlined,
                    title: 'No se pudo mostrar la imagen',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _boardTitleProvider = FutureProvider.autoDispose.family<String?, String>((ref, id) async {
  ref.watch(libraryRevisionProvider);
  try {
    final n = await lib.getNote(id: id);
    return n.title;
  } catch (_) {
    return null;
  }
});

class _BoardEmbed extends EmbedBuilder {
  @override
  String get key => FolioEmbeds.board;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final id = _blockOf(embedContext)?.noteId;
    if (id == null) return const _EmbedCard(icon: Icons.link_off_rounded, title: 'Pizarra no disponible');
    return Consumer(
      builder: (context, ref, _) {
        final title = ref.watch(_boardTitleProvider(id));
        final exists = title.hasValue && title.value != null;
        return _EmbedCard(
          icon: Icons.draw_outlined,
          title: title.isLoading
              ? 'Pizarra'
              : !exists
              ? 'Pizarra eliminada'
              : (title.value!.trim().isEmpty ? 'Pizarra sin título' : title.value!),
          subtitle: exists ? 'Pizarra enlazada' : null,
          onTap: exists ? () => context.openNote(id, kind: NoteKind.board) : null,
        );
      },
    );
  }
}

class _DividerEmbed extends EmbedBuilder {
  @override
  String get key => FolioEmbeds.divider;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Insets.md),
    child: Divider(color: context.colors.separator, thickness: 1),
  );
}

class _UnknownEmbed extends EmbedBuilder {
  @override
  String get key => FolioEmbeds.unknown;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const _EmbedCard(icon: Icons.extension_outlined, title: 'Contenido no compatible con esta versión');
}
