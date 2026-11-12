import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/providers.dart';
import '../../platform/native.dart';
import '../../platform/paths.dart';
import '../../src/rust/api/attachments.dart' as att;
import '../../src/rust/api/types.dart';
import '../../widgets/empty_state.dart';
import '../capture/capture_entry.dart';
import '../capture/capture_errors.dart';
import '../search/search_service.dart';

/// Visor de un adjunto (imagen o PDF) con el texto de cada página: original ↔ texto extraído.
class AttachmentScreen extends ConsumerStatefulWidget {
  const AttachmentScreen({super.key, required this.attachmentId, this.page, this.highlight});

  final String attachmentId;
  final int? page;
  final String? highlight;

  @override
  ConsumerState<AttachmentScreen> createState() => _AttachmentScreenState();
}

class _AttachmentScreenState extends ConsumerState<AttachmentScreen> {
  Attachment? _attachment;
  List<AttachmentPage> _pages = const [];
  Object? _error;
  late final PageController _controller = PageController(initialPage: widget.page ?? 0);
  int _index = 0;
  final _renders = <int, Future<String?>>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _index = widget.page ?? 0;
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final a = await att.getAttachment(id: widget.attachmentId);
      final pages = await att.listAttachmentPages(attachmentId: widget.attachmentId);
      if (!mounted) return;
      setState(() {
        _attachment = a;
        _pages = pages;
        _error = null;
        _index = _index.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Imagen de la página: la foto original, o un render del PDF cacheado en disco.
  Future<String?> _imageFor(int index) {
    return _renders.putIfAbsent(index, () async {
      final a = _attachment!;
      if (a.kind == AttachmentKind.image) return a.path;
      final dir = await AppPaths.pdfCacheDir(a.id);
      final out = '${dir.path}${Platform.pathSeparator}$index.png';
      if (await File(out).exists()) return out;
      try {
        final r = await FolioNative.renderPdfPage(a.path, page: index, outPath: out, targetWidth: 1500);
        return r.path;
      } catch (_) {
        final page = _pages.where((p) => p.pageIndex == index).firstOrNull;
        return page?.imagePath;
      }
    });
  }

  AttachmentPage? get _page => _pages.where((p) => p.pageIndex == _index).firstOrNull;

  Future<void> _recognize() async {
    final a = _attachment;
    final page = _page;
    if (a == null || page == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (a.kind == AttachmentKind.pdf) {
        await recognizePdfPages(context, attachment: a, pages: _pages, pageIndexes: [page.pageIndex]);
      } else {
        final info = await safeOcrInfo();
        if (!info.available)
          throw Exception('El reconocimiento de texto no está disponible en este dispositivo.');
        final ocr = await FolioNative.recognizeText(a.path);
        await att.setPageOcr(pageId: page.id, input: ocr.toPageInput());
        ref.read(libraryRevisionProvider.notifier).bump();
      }
      await _load();
    } catch (e) {
      if (mounted) showErrorSnack(context, captureErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(AttachmentPage page) async {
    final controller = TextEditingController(text: page.text);
    final saved = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('Corregir texto'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar')),
            ],
          ),
          body: SafeArea(
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: ctx.text.bodyLarge,
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(Insets.lg),
                hintText: 'Texto de la página',
              ),
            ),
          ),
        ),
      ),
    );
    // No se libera aquí: el diálogo sigue usándolo durante la animación de cierre.
    WidgetsBinding.instance.addPostFrameCallback((_) => Future<void>.delayed(const Duration(seconds: 1), controller.dispose));
    if (saved == null || saved == page.text) return;
    try {
      await att.updatePageText(pageId: page.id, text: saved);
      ref.read(libraryRevisionProvider.notifier).bump();
      await _load();
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _attachment;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.broken_image_outlined,
          title: 'No se pudo abrir el adjunto',
          message: humanError(_error!),
          actionLabel: 'Reintentar',
          onAction: _load,
        ),
      );
    }
    if (a == null)
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator.adaptive()),
      );
    final count = a.kind == AttachmentKind.pdf ? a.pageCount : 1;
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(a.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
            if (count > 1) Text('Página ${_index + 1} de $count', style: context.text.labelSmall),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 6,
            child: PageView.builder(
              controller: _controller,
              itemCount: count,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (ctx, i) => FutureBuilder<String?>(
                future: _imageFor(i),
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator.adaptive());
                  }
                  final path = snap.data;
                  if (path == null) {
                    return const EmptyState(
                      compact: true,
                      icon: Icons.picture_as_pdf_outlined,
                      title: 'No se puede mostrar esta página',
                      message: 'El texto extraído sigue disponible abajo.',
                    );
                  }
                  return InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.md),
                        child: Image.file(
                          File(path),
                          fit: BoxFit.contain,
                          semanticLabel: 'Página ${i + 1} de ${a.fileName}',
                          errorBuilder: (_, _, _) =>
                              Icon(Icons.broken_image_outlined, size: 48, color: c.textTertiary),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Expanded(flex: 5, child: _textPanel(a)),
        ],
      ),
    );
  }

  Widget _textPanel(Attachment a) {
    final c = context.colors;
    final page = _page;
    final text = page?.text ?? '';
    final source = switch (page?.textSource) {
      TextSource.pdfText => 'Texto del PDF',
      TextSource.ocr => 'Texto reconocido (OCR)',
      TextSource.ocrEdited => 'Texto corregido a mano',
      _ => 'Sin texto',
    };
    final conf = page?.ocrConfidence;
    final low = page?.textSource == TextSource.ocr && conf != null && conf < 0.5;
    final spans = <TextSpan>[];
    final h = widget.highlight;
    if (text.isNotEmpty && h != null && h.trim().isNotEmpty) {
      final matches = ref.read(findInTextProvider)(text, h);
      var at = 0;
      for (final m in matches) {
        if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
        spans.add(
          TextSpan(
            text: text.substring(m.start, m.end),
            style: TextStyle(backgroundColor: c.highlight),
          ),
        );
        at = m.end;
      }
      if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    }
    return Material(
      color: c.surface,
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Insets.radiusSheet)),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.xs, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(source, style: context.text.titleSmall),
                        if (page?.textSource == TextSource.ocr && conf != null)
                          Text(
                            low
                                ? 'Reconocimiento poco fiable: revísalo'
                                : 'Fiabilidad ${(conf * 100).round()} %',
                            style: context.text.labelSmall?.copyWith(color: low ? c.danger : c.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  if (page != null && text.isNotEmpty)
                    TextButton(onPressed: () => _edit(page), child: const Text('Corregir')),
                  if (page != null)
                    TextButton(
                      onPressed: _busy ? null : _recognize,
                      child: Text(text.isEmpty ? 'Reconocer texto' : 'Volver a reconocer'),
                    ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: text.isEmpty
                  ? EmptyState(
                      compact: true,
                      icon: Icons.text_snippet_outlined,
                      title: _busy ? 'Reconociendo…' : 'Esta página no tiene texto',
                      message: 'El OCR reconoce texto impreso; la escritura a mano, las fórmulas y los dibujos pueden no reconocerse.',
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(Insets.lg),
                      child: SelectableText.rich(
                        spans.isEmpty ? TextSpan(text: text) : TextSpan(children: spans),
                        style: context.text.bodyLarge,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
