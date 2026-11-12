import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_menu.dart';
import '../../widgets/empty_state.dart';
import '../ai/ai_entry.dart';
import 'board_repository.dart';
import 'controller/board_autosave.dart';
import 'controller/board_controller.dart';
import 'model/board_color.dart';
import 'model/elements.dart';
import 'model/scene.dart';
import 'render/board_image_cache.dart';
import 'render/board_renderer.dart';
import 'widgets/board_canvas.dart';

const _aiHintKey = 'board_ai_hint_seen';

/// Pizarra: lienzo con desplazamiento y zoom, herramientas, deshacer/rehacer y guardado automático.
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key, required this.noteId, this.repository});

  final String noteId;
  final BoardRepository? repository;

  @override
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  late final BoardRepository _repo = widget.repository ?? RustBoardRepository();
  final _canvasKey = GlobalKey<BoardCanvasState>();
  final _titleController = TextEditingController();
  late final AppLifecycleListener _lifecycle;

  BoardController? _controller;
  BoardImageCache? _images;
  BoardRenderer? _renderer;
  BoardAutosave? _autosave;
  Object? _error;
  int _savedSceneRev = 0;
  int _savedTitleRev = 0;
  double _lastViewportScale = 1;
  Offset _lastViewportOrigin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _flush, onPause: _flush);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    final autosave = _autosave;
    final controller = _controller;
    final renderer = _renderer;
    final images = _images;
    // Último guardado antes de liberar (no se espera: la escena ya está serializada dentro).
    if (autosave != null) {
      controller?.finishTextEdit(restoreTool: false);
      autosave.flush().whenComplete(() {
        autosave.dispose();
        controller?.dispose();
        renderer?.dispose();
        images?.dispose();
      });
    }
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final board = await _repo.load(widget.noteId);
      if (!mounted) return;
      final scene = BoardScene.decode(board.sceneJson);
      final controller = BoardController(scene: scene, title: board.title);
      final images = BoardImageCache(resolvePath: _repo.attachmentPath);
      final renderer = BoardRenderer(images: images, theme: _paintTheme());
      final revision = ref.read(libraryRevisionProvider.notifier);
      final autosave = BoardAutosave(
        save: () async {
          await _repo.save(widget.noteId, controller.title, controller.encodeScene());
          revision.bump();
        },
      );
      _titleController.text = board.title;
      _savedSceneRev = controller.sceneRevision;
      _savedTitleRev = controller.titleRevision;
      _lastViewportScale = scene.viewport.scale;
      _lastViewportOrigin = scene.viewport.origin;
      controller.addListener(_onController);
      controller.viewport.addListener(_onViewport);
      autosave.addListener(_onAutosave);
      setState(() {
        _controller = controller;
        _images = images;
        _renderer = renderer;
        _autosave = autosave;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  BoardPaintTheme _paintTheme() {
    final c = context.colors;
    return BoardPaintTheme(
      brightness: Theme.of(context).brightness,
      textStyle: Theme.of(context).textTheme.bodyLarge ?? const TextStyle(),
      placeholderFill: c.surfaceAlt,
      placeholderStroke: c.separator,
      placeholderIcon: c.textTertiary,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _renderer?.theme = _paintTheme();
  }

  void _onController() {
    final c = _controller!;
    if (c.sceneRevision != _savedSceneRev || c.titleRevision != _savedTitleRev || c.isEditingText) {
      _savedSceneRev = c.sceneRevision;
      _savedTitleRev = c.titleRevision;
      _autosave?.markDirty();
    }
    if (mounted) setState(() {});
  }

  void _onViewport() {
    final v = _controller!.viewport.value;
    if (v.scale != _lastViewportScale || v.origin != _lastViewportOrigin) {
      _lastViewportScale = v.scale;
      _lastViewportOrigin = v.origin;
      // La vista también se guarda (reabrir en el mismo punto), con el mismo retardo.
      _autosave?.markDirty();
    }
  }

  void _onAutosave() {
    final a = _autosave;
    if (a != null && a.status == SaveStatus.error && mounted) {
      showErrorSnack(context, a.lastError ?? 'error', prefix: 'No se pudo guardar la pizarra');
    }
    if (mounted) setState(() {});
  }

  void _flush() {
    _controller?.finishTextEdit(restoreTool: false);
    _autosave?.flush();
  }

  Future<void> _insertImage() async {
    final controller = _controller!;
    final source = await showAdaptiveMenu<ImageSource>(
      context,
      title: 'Insertar imagen',
      actions: const [
        MenuAction(
          value: ImageSource.gallery,
          label: 'Elegir de la galería',
          icon: Icons.photo_library_outlined,
        ),
        MenuAction(value: ImageSource.camera, label: 'Hacer una foto', icon: Icons.photo_camera_outlined),
      ],
    );
    if (source == null) return;
    try {
      final x = await ImagePicker().pickImage(source: source, requestFullMetadata: false);
      if (x == null) return;
      final att = await _repo.importImage(widget.noteId, x.path, x.path.split(Platform.pathSeparator).last);
      final size = MediaQuery.sizeOf(context);
      final v = controller.viewport.value;
      final center = v.toCanvas(Offset(size.width / 2, size.height / 2));
      final ratio = (att.width != null && att.height != null && att.height! > 0)
          ? att.width! / att.height!
          : 4 / 3;
      final w = (size.width * 0.6) / v.scale;
      final h = w / ratio;
      final el = ImageElement(
        id: controller.newId(),
        x: center.dx - w / 2,
        y: center.dy - h / 2,
        w: w,
        h: h,
        attachmentId: att.id,
      );
      controller
        ..addElement(el)
        ..tool = BoardTool.select
        ..select([el.id]);
    } catch (e) {
      if (mounted) showErrorSnack(context, e, prefix: 'No se pudo insertar la imagen');
    }
  }

  Future<void> _openAi() async {
    _flush();
    final seen = await _repo.getSetting(_aiHintKey);
    if (!mounted) return;
    if (seen == null) {
      await showAdaptiveDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog.adaptive(
          title: const Text('IA en la pizarra'),
          content: const Text(
            'La IA solo usa el texto escrito con la herramienta Texto. Los dibujos y la escritura a mano no se interpretan.',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Entendido'))],
        ),
      );
      await _repo.setSetting(_aiHintKey, '1');
      if (!mounted) return;
    }
    await showAiActions(context, scope: Scopes.note(widget.noteId));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final controller = _controller;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudo abrir la pizarra',
          message: humanError(_error!),
          actionLabel: 'Reintentar',
          onAction: _load,
        ),
      );
    }
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator.adaptive()),
      );
    }
    final autosave = _autosave!;
    final saving = autosave.status == SaveStatus.saving || autosave.isDirty;
    return PopScope(
      onPopInvokedWithResult: (_, _) => _flush(),
      child: Scaffold(
        backgroundColor: c.surface,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: c.surface,
          titleSpacing: 0,
          title: TextField(
            controller: _titleController,
            onChanged: (v) => controller.title = v,
            textCapitalization: TextCapitalization.sentences,
            style: context.text.titleMedium,
            decoration: InputDecoration(
              hintText: 'Pizarra sin título',
              filled: false,
              border: InputBorder.none,
              isDense: true,
              suffixText: autosave.status == SaveStatus.error
                  ? 'Sin guardar'
                  : (saving ? 'Guardando…' : null),
              suffixStyle: context.text.labelSmall?.copyWith(
                color: autosave.status == SaveStatus.error ? c.danger : c.textSecondary,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Deshacer',
              icon: const Icon(Icons.undo_rounded),
              onPressed: controller.canUndo ? controller.undo : null,
            ),
            IconButton(
              tooltip: 'Rehacer',
              icon: const Icon(Icons.redo_rounded),
              onPressed: controller.canRedo ? controller.redo : null,
            ),
            IconButton(
              tooltip: 'Asistente de IA',
              icon: const Icon(Icons.auto_awesome_rounded),
              onPressed: _openAi,
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: BoardCanvas(
                key: _canvasKey,
                controller: controller,
                renderer: _renderer!,
                images: _images!,
              ),
            ),
            Positioned(
              top: Insets.sm,
              right: Insets.sm,
              child: ValueListenableBuilder<BoardViewport>(
                valueListenable: controller.viewport,
                builder: (_, v, _) => Material(
                  color: c.surfaceAlt.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _canvasKey.currentState?.zoomTo(1),
                    child: Semantics(
                      button: true,
                      label: 'Zoom ${(v.scale * 100).round()} por ciento. Toca para volver al 100.',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
                        child: Text('${(v.scale * 100).round()} %', style: context.text.labelMedium),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                minimum: const EdgeInsets.all(Insets.md),
                child: Center(
                  child: _Toolbar(controller: controller, onImage: _insertImage),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Barra flotante: herramientas, y encima las opciones de la herramienta activa o de la selección.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller, required this.onImage});
  final BoardController controller;
  final VoidCallback onImage;

  static const _icons = {
    BoardTool.pen: Icons.edit_rounded,
    BoardTool.highlighter: Icons.border_color_rounded,
    BoardTool.eraser: Icons.auto_fix_normal_rounded,
    BoardTool.select: Icons.highlight_alt_rounded,
    BoardTool.text: Icons.title_rounded,
    BoardTool.shape: Icons.category_outlined,
  };
  static const _shapeIcons = {
    ShapeKind.rect: Icons.crop_square_rounded,
    ShapeKind.ellipse: Icons.circle_outlined,
    ShapeKind.line: Icons.horizontal_rule_rounded,
    ShapeKind.arrow: Icons.arrow_right_alt_rounded,
  };
  static const _shapeLabels = {
    ShapeKind.rect: 'Rectángulo',
    ShapeKind.ellipse: 'Elipse',
    ShapeKind.line: 'Línea',
    ShapeKind.arrow: 'Flecha',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tool = controller.tool;
    final brightness = Theme.of(context).brightness;
    final spec = toolSizeSpecs[tool];

    Widget surface(Widget child) => Material(
      color: c.surface,
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs, vertical: 2),
        child: child,
      ),
    );

    Widget swatch(int i, {required bool selected, required VoidCallback onTap}) {
      final color = boardPalette[i].forBrightness(brightness);
      return Semantics(
        button: true,
        selected: selected,
        label: 'Color ${boardPalette[i].label}',
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: SizedBox(
            width: 40,
            height: 44,
            child: Center(
              child: Container(
                width: selected ? 28 : 22,
                height: selected ? 28 : 22,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? c.accent : c.separator, width: selected ? 3 : 1),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final options = <Widget>[];
    if (tool == BoardTool.select && controller.hasSelection) {
      options.add(
        surface(
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Duplicar',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: controller.duplicateSelection,
                ),
                IconButton(
                  tooltip: 'Eliminar la selección',
                  icon: Icon(Icons.delete_outline_rounded, color: c.danger),
                  onPressed: controller.deleteSelection,
                ),
                for (var i = 0; i < boardPalette.length; i++)
                  swatch(i, selected: false, onTap: () => controller.recolorSelection(i)),
              ],
            ),
          ),
        ),
      );
    } else if (tool == BoardTool.select) {
      options.add(
        surface(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in SelectionMode.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: ChoiceChip(
                    label: Text(m.label),
                    selected: controller.selectionMode == m,
                    onSelected: (_) => controller.selectionMode = m,
                  ),
                ),
              TextButton(
                onPressed: controller.elements.isEmpty ? null : controller.selectAll,
                child: const Text('Todo'),
              ),
            ],
          ),
        ),
      );
    } else {
      if (tool == BoardTool.shape) {
        options.add(
          surface(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final k in ShapeKind.values)
                  IconButton(
                    tooltip: _shapeLabels[k],
                    isSelected: controller.shapeKind == k,
                    style: IconButton.styleFrom(
                      backgroundColor: controller.shapeKind == k ? c.accentSoft : null,
                    ),
                    icon: Icon(_shapeIcons[k]),
                    onPressed: () => controller.shapeKind = k,
                  ),
              ],
            ),
          ),
        );
      }
      if (spec != null) {
        final size = controller.sizeOf(tool);
        options.add(
          surface(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < spec.presets.length; i++)
                  Semantics(
                    button: true,
                    selected: size == spec.presets[i],
                    label: '${tool.label}: ${spec.labels[i]}',
                    child: InkResponse(
                      onTap: () => controller.setSize(tool, spec.presets[i]),
                      radius: 22,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Container(
                            width: 8.0 + i * 7,
                            height: 8.0 + i * 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: size == spec.presets[i] ? c.accent : c.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width: 130,
                  child: Slider(
                    value: size.clamp(spec.min, spec.max),
                    min: spec.min,
                    max: spec.max,
                    semanticFormatterCallback: (v) => '${v.round()} ${spec.unit}',
                    onChanged: (v) => controller.setSize(tool, v),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      if (tool.hasColor) {
        options.add(
          surface(
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < boardPalette.length; i++)
                    swatch(
                      i,
                      selected: controller.colorIndexOf(tool) == i,
                      onTap: () => controller.setColorIndex(tool, i),
                    ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: o,
            ),
          surface(
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in BoardTool.values)
                    IconButton(
                      tooltip: t.label,
                      isSelected: tool == t,
                      style: IconButton.styleFrom(
                        backgroundColor: tool == t ? c.accentSoft : null,
                        foregroundColor: tool == t ? c.accent : c.textPrimary,
                      ),
                      icon: Icon(_icons[t]),
                      onPressed: () => controller.tool = t,
                    ),
                  IconButton(
                    tooltip: 'Insertar imagen',
                    style: IconButton.styleFrom(foregroundColor: c.textPrimary),
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: onImage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
