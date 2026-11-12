import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:uuid/uuid.dart';

import '../../app/theme.dart';
import '../../core/providers.dart';
import '../../platform/native.dart';
import '../../platform/paths.dart';
import '../../src/rust/api/attachments.dart' as att;
import '../../src/rust/api/library.dart' as lib;
import '../../src/rust/api/types.dart';
import '../../widgets/adaptive_menu.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import 'capture_errors.dart';
import 'capture_gateway.dart';
import 'capture_models.dart';
import 'capture_session.dart';
import 'capture_sources.dart';
import 'crop_dialog.dart';
import 'ocr_overlay.dart';

/// Origen de la captura: cámara del sistema, galería o escáner de documentos (iOS VisionKit).
enum CaptureSource {
  camera,
  gallery,
  scanner;

  static CaptureSource fromName(String? name) =>
      CaptureSource.values.firstWhere((s) => s.name == name, orElse: () => CaptureSource.camera);

  PageOrigin get origin => switch (this) {
    camera => PageOrigin.camera,
    gallery => PageOrigin.gallery,
    scanner => PageOrigin.scanner,
  };
}

enum _Stage { images, text }

/// Flujo: cámara o importación → revisión de imagen → OCR → texto editable → guardar.
class CaptureFlowScreen extends ConsumerStatefulWidget {
  const CaptureFlowScreen({super.key, this.folderId, this.appendToNoteId, required this.source});

  final String? folderId;
  final String? appendToNoteId;
  final CaptureSource source;

  @override
  ConsumerState<CaptureFlowScreen> createState() => _CaptureFlowScreenState();
}

class _CaptureFlowScreenState extends ConsumerState<CaptureFlowScreen> {
  CaptureSession? _session;
  Directory? _workDir;
  OcrEngineInfo _ocr = const OcrEngineInfo.unavailable();
  _Stage _stage = _Stage.images;
  final _pageController = PageController();
  final _textControllers = <String, TextEditingController>{};
  int? _selectedLine;
  bool _saving = false;
  PageOrigin? _denied;
  String? _blockingMessage;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _session?.removeListener(_onSession);
    _session?.dispose();
    AppPaths.deleteDirQuietly(_workDir);
    _pageController.dispose();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    final dir = await AppPaths.tmpDir('capture/${const Uuid().v4()}');
    final info = await safeOcrInfo();
    if (!mounted) return;
    final session = CaptureSession(
      workDir: dir.path,
      process: rustProcessImage,
      recognize: (path) => FolioNative.recognizeText(path),
      ocrAvailable: info.available,
      describeError: captureErrorMessage,
    )..addListener(_onSession);
    setState(() {
      _workDir = dir;
      _ocr = info;
      _session = session;
    });
    final origin = (widget.source == CaptureSource.scanner && !scannerSupportedOnPlatform)
        ? PageOrigin.camera
        : widget.source.origin;
    final ok = await _acquire(origin);
    if (!ok && mounted && session.isEmpty && _denied == null && _blockingMessage == null) {
      Navigator.of(context).maybePop();
    }
  }

  void _onSession() {
    final session = _session;
    if (session == null || !mounted) return;
    // Sincroniza el texto reconocido con los campos que el usuario no está editando.
    for (final p in session.pages) {
      final c = _textControllers[p.id];
      if (c != null && c.text != p.text && !c.selection.isValid) c.text = p.text;
    }
    setState(() {});
  }

  TextEditingController _controllerFor(CapturePage p) =>
      _textControllers.putIfAbsent(p.id, () => TextEditingController(text: p.text));

  /// Pide imágenes y las añade. Devuelve true si se añadió alguna.
  Future<bool> _acquire(PageOrigin origin, {String? replacePageId}) async {
    final session = _session!;
    final result = await acquireImages(origin, multiple: replacePageId == null);
    if (!mounted) return false;
    switch (result) {
      case Acquired(:final paths):
        setState(() {
          _denied = null;
          _blockingMessage = null;
        });
        if (replacePageId != null) {
          await session.replaceImage(replacePageId, paths.first);
          _textControllers.remove(replacePageId)?.dispose();
          return true;
        }
        final r = await session.addImages(paths, origin);
        if (mounted && r.errors.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(captureErrorMessage(r.errors.first))));
        }
        if (mounted && r.added.isNotEmpty) {
          final last = session.length - 1;
          session.select(last);
          if (_pageController.hasClients) _pageController.jumpToPage(last);
          if (_stage == _Stage.text) session.runOcr();
        }
        return r.added.isNotEmpty;
      case AcquireCancelled():
        return false;
      case AcquireDenied(:final origin):
        if (session.isEmpty) {
          setState(() => _denied = origin);
        } else {
          _snack('Permiso denegado. Puedes activarlo en Ajustes.');
        }
        return false;
      case AcquireUnavailable(:final message) || AcquireFailed(:final message):
        if (session.isEmpty) {
          setState(() => _blockingMessage = message);
        } else {
          _snack(message);
        }
        return false;
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _addPage() async {
    final choice = await showAdaptiveMenu<PageOrigin>(
      context,
      title: 'Añadir página',
      actions: [
        const MenuAction(
          value: PageOrigin.camera,
          label: 'Hacer una foto',
          icon: Icons.photo_camera_outlined,
        ),
        const MenuAction(
          value: PageOrigin.gallery,
          label: 'Elegir de la galería',
          icon: Icons.photo_library_outlined,
        ),
        if (scannerSupportedOnPlatform)
          const MenuAction(
            value: PageOrigin.scanner,
            label: 'Escanear documento',
            icon: Icons.document_scanner_outlined,
          ),
      ],
    );
    if (choice != null && mounted) await _acquire(choice);
  }

  Future<void> _crop(CapturePage page) async {
    final rect = await showCropDialog(context, page: page);
    if (rect != null) await _session!.setCrop(page.id, rect.isFull ? null : rect.rect);
  }

  void _remove(int index) {
    final session = _session!;
    final removed = session.removeAt(index);
    if (removed == null) return;
    if (session.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Página eliminada'),
          action: SnackBarAction(label: 'Deshacer', onPressed: () => session.restore(removed, index)),
        ),
      );
  }

  void _goToText() {
    setState(() {
      _stage = _Stage.text;
      _selectedLine = null;
    });
    _session!.runOcr();
  }

  Future<bool> _confirmDiscard() async {
    final session = _session;
    if (session == null || session.isEmpty || _saving) return true;
    return confirmAction(
      context,
      title: '¿Descartar la captura?',
      message: 'Se perderán las páginas y el texto reconocido.',
      confirmLabel: 'Descartar',
      destructive: true,
    );
  }

  // ───────────── Guardar ─────────────

  Future<void> _save() async {
    final session = _session!;
    if (!session.canSave || _saving) return;
    String? appendTo = widget.appendToNoteId;
    var title = '';
    if (appendTo == null) {
      final choice = await showAdaptiveMenu<String>(
        context,
        title: 'Guardar apuntes',
        actions: const [
          MenuAction(value: 'new', label: 'Guardar como nota nueva', icon: Icons.note_add_outlined),
          MenuAction(value: 'append', label: 'Añadir a una nota existente', icon: Icons.post_add_rounded),
        ],
      );
      if (choice == null || !mounted) return;
      if (choice == 'append') {
        appendTo = await _pickNote();
        if (appendTo == null || !mounted) return;
      } else {
        final controller = TextEditingController();
        final ok = await showAdaptiveDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog.adaptive(
            title: const Text('Título de la nota'),
            content: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Opcional'),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
              ),
            ),
            actions: [
              adaptiveAction(ctx, label: 'Cancelar', onPressed: () => Navigator.pop(ctx, false)),
              adaptiveAction(ctx, label: 'Guardar', onPressed: () => Navigator.pop(ctx, true)),
            ],
          ),
        );
        title = controller.text.trim();
        // No se libera aquí: el diálogo sigue usándolo durante la animación de cierre.
        WidgetsBinding.instance.addPostFrameCallback((_) => Future<void>.delayed(const Duration(seconds: 1), controller.dispose));
        if (ok != true || !mounted) return;
      }
    }
    setState(() => _saving = true);
    try {
      final pages = session.toPageInputs();
      final note = appendTo != null
          ? await att.appendScanToNote(noteId: appendTo, pages: pages)
          : await att.createNoteFromScan(folderId: widget.folderId, title: title, pages: pages);
      ref.read(libraryRevisionProvider.notifier).bump();
      if (mounted) Navigator.of(context).pop(note.id);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('No se pudo guardar: ${captureErrorMessage(e)}');
      }
    }
  }

  Future<String?> _pickNote() async {
    final notes = (await lib.listNotes(
      scope: NoteListScope.all,
      folderId: null,
    )).where((n) => n.kind == NoteKind.text).toList();
    if (!mounted) return null;
    if (notes.isEmpty) {
      _snack('Todavía no hay notas a las que añadir.');
      return null;
    }
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.sm),
              child: Text('Añadir a una nota', style: ctx.text.titleMedium),
            ),
            for (final n in notes)
              ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: Text(
                  n.title.trim().isEmpty ? 'Sin título' : n.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: n.preview.isEmpty
                    ? null
                    : Text(n.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, n.id),
              ),
          ],
        ),
      ),
    );
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final c = context.colors;
    Widget body;
    if (_denied != null) {
      final camera = _denied == PageOrigin.camera || _denied == PageOrigin.scanner;
      body = EmptyState(
        icon: camera ? Icons.no_photography_outlined : Icons.image_not_supported_outlined,
        title: camera ? 'Folio no tiene acceso a la cámara' : 'Folio no tiene acceso a tus fotos',
        message:
            'Actívalo en Ajustes para ${camera ? 'fotografiar' : 'importar'} tus apuntes. '
            'Las imágenes se procesan en el dispositivo.',
        actionLabel: 'Abrir Ajustes',
        onAction: openAppSettings,
        secondaryLabel: camera ? 'Elegir de la galería' : 'Usar la cámara',
        onSecondary: () => _acquire(camera ? PageOrigin.gallery : PageOrigin.camera),
      );
    } else if (_blockingMessage != null) {
      body = EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'No se pudo abrir la captura',
        message: _blockingMessage,
        actionLabel: 'Elegir de la galería',
        onAction: () => _acquire(PageOrigin.gallery),
      );
    } else if (session == null || session.isEmpty) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator.adaptive(),
            const SizedBox(height: Insets.lg),
            Text(
              session != null && session.preparingCount > 0 ? 'Preparando las imágenes…' : 'Abriendo…',
              style: context.text.bodyMedium,
            ),
          ],
        ),
      );
    } else {
      body = _stage == _Stage.images ? _imagesStage(session) : _textStage(session);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_stage == _Stage.text && session != null && !session.isEmpty) {
          session.cancelOcr();
          setState(() => _stage = _Stage.images);
          return;
        }
        final nav = Navigator.of(context);
        if (await _confirmDiscard()) nav.pop();
      },
      child: Scaffold(
        backgroundColor: c.background,
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Cancelar',
            icon: const Icon(Icons.close_rounded),
            onPressed: () async {
              final nav = Navigator.of(context);
              if (await _confirmDiscard()) nav.pop();
            },
          ),
          title: Text(_stage == _Stage.images ? 'Revisar imágenes' : 'Revisar texto'),
          actions: [
            if (session != null && !session.isEmpty && _stage == _Stage.text)
              Padding(
                padding: const EdgeInsets.only(right: Insets.sm),
                child: FilledButton(
                  onPressed: session.canSave && !_saving ? _save : null,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Guardar'),
                ),
              ),
          ],
        ),
        body: SafeArea(child: body),
      ),
    );
  }

  Widget _pageImage(CapturePage page, {bool overlay = false}) {
    final image = FileImage(File(page.imagePath));
    final busy = _session!.isProcessing(page.id);
    return Stack(
      alignment: Alignment.center,
      children: [
        OcrImageOverlay(
          key: ValueKey('${page.id}-${page.revision}-${page.imagePath}'),
          image: image,
          aspectRatio: page.aspectRatio,
          lines: overlay ? (page.ocr?.lines ?? const []) : const [],
          showLines: overlay,
          selectedLine: overlay ? _selectedLine : null,
          onLineTap: overlay ? (i) => setState(() => _selectedLine = _selectedLine == i ? null : i) : null,
          semanticLabel: 'Página capturada',
        ),
        if (busy) const CircularProgressIndicator.adaptive(),
      ],
    );
  }

  Widget _thumbs(CaptureSession session) {
    final c = context.colors;
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        itemCount: session.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: Insets.sm),
        itemBuilder: (ctx, i) {
          if (i == session.length) {
            return Semantics(
              button: true,
              label: 'Añadir página',
              child: InkWell(
                onTap: _addPage,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 48,
                  decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.add_rounded, color: c.accent),
                ),
              ),
            );
          }
          final p = session.pages[i];
          final selected = i == session.selectedIndex;
          return Semantics(
            button: true,
            selected: selected,
            label: 'Página ${i + 1} de ${session.length}',
            child: GestureDetector(
              onTap: () {
                session.select(i);
                setState(() => _selectedLine = null);
                if (_pageController.hasClients) _pageController.jumpToPage(i);
              },
              child: Container(
                width: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selected ? c.accent : c.separator, width: selected ? 2 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(
                  File(p.imagePath),
                  key: ValueKey('${p.id}-${p.revision}'),
                  fit: BoxFit.cover,
                  cacheWidth: 144,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _imagesStage(CaptureSession session) {
    final page = session.selected!;
    final busy = session.isProcessing(page.id);
    Widget tool(IconData icon, String label, VoidCallback? onTap) => Expanded(
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: Insets.sm)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: session.length,
            onPageChanged: session.select,
            itemBuilder: (ctx, i) => Padding(
              padding: const EdgeInsets.all(Insets.lg),
              child: InteractiveViewer(maxScale: 4, child: Center(child: _pageImage(session.pages[i]))),
            ),
          ),
        ),
        Text('Página ${session.selectedIndex + 1} de ${session.length}', style: context.text.bodySmall),
        const SizedBox(height: Insets.sm),
        _thumbs(session),
        Row(
          children: [
            tool(Icons.rotate_90_degrees_cw_outlined, 'Girar', busy ? null : () => session.rotate(page.id)),
            tool(Icons.crop_rounded, 'Recortar', busy ? null : () => _crop(page)),
            tool(
              Icons.replay_rounded,
              'Repetir',
              busy
                  ? null
                  : () => _acquire(
                      page.origin == PageOrigin.gallery ? PageOrigin.gallery : PageOrigin.camera,
                      replacePageId: page.id,
                    ),
            ),
            tool(Icons.delete_outline_rounded, 'Eliminar', () => _remove(session.selectedIndex)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.xs, Insets.lg, Insets.lg),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: session.anyProcessing ? null : _goToText,
              icon: Icon(session.ocrAvailable ? Icons.text_fields_rounded : Icons.arrow_forward_rounded),
              label: Text(session.ocrAvailable ? 'Reconocer texto' : 'Continuar sin reconocimiento'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _banner({required IconData icon, required String text, Color? color, Widget? action}) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
      decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(Insets.radiusGroup)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? c.textSecondary),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(text, style: context.text.bodySmall?.copyWith(color: c.textPrimary)),
          ),
          ?action,
        ],
      ),
    );
  }

  Widget _textStage(CaptureSession session) {
    final c = context.colors;
    final page = session.selected!;
    final controller = _controllerFor(page);
    final index = session.ocrPageIndex;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    final banners = <Widget>[
      if (session.ocrRunning)
        Container(
          margin: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
          padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.xs, Insets.sm),
          decoration: BoxDecoration(
            color: c.accentSoft,
            borderRadius: BorderRadius.circular(Insets.radiusGroup),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.cancelRequested
                          ? 'Cancelando…'
                          : 'Reconociendo página ${(index ?? 0) + 1} de ${session.length}',
                      style: context.text.labelMedium?.copyWith(color: c.textPrimary),
                    ),
                    const SizedBox(height: Insets.xs),
                    LinearProgressIndicator(
                      value: session.ocrProgress,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: session.cancelRequested ? null : session.cancelOcr,
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      if (!session.ocrAvailable)
        _banner(
          icon: Icons.info_outline_rounded,
          text: 'El reconocimiento de texto no está disponible en este dispositivo. Puedes guardar las imágenes y escribir el texto a mano.',
        ),
      if (page.status == OcrStatus.failed)
        _banner(
          icon: Icons.error_outline_rounded,
          color: c.danger,
          text: page.error ?? 'No se pudo reconocer esta página.',
          action: TextButton(onPressed: () => session.retryOcr(page.id), child: const Text('Reintentar')),
        ),
      if (page.status == OcrStatus.skipped)
        _banner(
          icon: Icons.pause_circle_outline_rounded,
          text: 'Reconocimiento cancelado para esta página.',
          action: TextButton(onPressed: () => session.retryOcr(page.id), child: const Text('Reconocer')),
        ),
      if (page.recognizedEmpty)
        _banner(
          icon: Icons.search_off_rounded,
          text: 'No se ha encontrado texto en esta página. Puedes escribirlo o guardar solo la imagen.',
        ),
      if (page.isLowConfidence)
        _banner(
          icon: Icons.warning_amber_rounded,
          color: const Color(0xFFB26A00),
          text: 'Reconocimiento poco fiable en esta página. Revisa el texto con atención.',
        ),
    ];

    return Column(
      children: [
        ...banners,
        if (!keyboard)
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(Insets.lg),
              child: InteractiveViewer(maxScale: 5, child: Center(child: _pageImage(page, overlay: true))),
            ),
          ),
        if (!keyboard && session.length > 1) _thumbs(session),
        Expanded(
          flex: 6,
          child: Container(
            margin: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, Insets.sm),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(Insets.radiusGroup),
            ),
            child: Column(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('text-${page.id}'),
                    controller: controller,
                    onChanged: (v) => session.updateText(page.id, v),
                    enabled: page.status != OcrStatus.running,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    textCapitalization: TextCapitalization.sentences,
                    style: context.text.bodyLarge,
                    decoration: InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(Insets.lg),
                      hintText:
                          page.status == OcrStatus.running ||
                              page.status == OcrStatus.pending && session.ocrRunning
                          ? 'Reconociendo…'
                          : 'Texto de la página ${session.selectedIndex + 1}',
                    ),
                  ),
                ),
                if (_selectedLine != null && page.ocr != null && _selectedLine! < page.ocr!.lines.length)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.sm),
                    decoration: BoxDecoration(color: c.highlight.withValues(alpha: 0.5)),
                    child: Text(
                      'Línea seleccionada: «${page.ocr!.lines[_selectedLine!].text}»',
                      style: context.text.bodySmall?.copyWith(color: c.textPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (!keyboard)
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
            child: Text(
              'El OCR ${_ocr.handwriting ? 'puede reconocer algo de escritura a mano, pero' : 'reconoce sobre todo texto impreso:'} '
              'la escritura a mano, las fórmulas y los diagramas pueden no reconocerse bien. Revisa el resultado.',
              textAlign: TextAlign.center,
              style: context.text.labelSmall,
            ),
          ),
      ],
    );
  }
}
