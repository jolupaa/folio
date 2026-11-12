import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/providers.dart';
import '../../platform/native.dart';
import '../../platform/paths.dart';
import '../../src/rust/api/attachments.dart' as att;
import '../../src/rust/api/types.dart';
import '../../widgets/adaptive_menu.dart';
import 'capture_errors.dart';
import 'capture_flow.dart';
import 'capture_models.dart';
import 'capture_sources.dart';

/// Inicia el flujo cámara/galería/escáner → revisión → OCR → texto editable → guardar.
/// Devuelve el id de la nota creada o actualizada (o null si se cancela).
Future<String?> startCapture(
  BuildContext context, {
  String? folderId,
  String? appendToNoteId,
  CaptureSource source = CaptureSource.camera,
}) {
  final q = <String, String>{'source': source.name, 'folder': ?folderId, 'append': ?appendToNoteId};
  return context.push<String>(Uri(path: '/capture', queryParameters: q).toString());
}

enum AttachKind { image, pdf }

void _snack(BuildContext context, String message) {
  if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
}

void _bump(BuildContext context) {
  if (context.mounted)
    ProviderScope.containerOf(context, listen: false).read(libraryRevisionProvider.notifier).bump();
}

/// Selecciona e importa un adjunto en una nota. PDF: extrae la capa de texto y reconoce (OCR) las
/// páginas escaneadas con progreso cancelable. Devuelve el adjunto creado o null si se cancela.
Future<Attachment?> pickAndAttach(
  BuildContext context, {
  required String noteId,
  required AttachKind kind,
}) async {
  try {
    if (kind == AttachKind.image) {
      final origin = await showAdaptiveMenu<PageOrigin>(
        context,
        title: 'Añadir imagen',
        actions: const [
          MenuAction(
            value: PageOrigin.gallery,
            label: 'Elegir de la galería',
            icon: Icons.photo_library_outlined,
          ),
          MenuAction(value: PageOrigin.camera, label: 'Hacer una foto', icon: Icons.photo_camera_outlined),
        ],
      );
      if (origin == null) return null;
      final result = await acquireImages(origin, multiple: false);
      switch (result) {
        case Acquired(:final paths):
          final path = paths.first;
          final a = await att.importImage(
            noteId: noteId,
            sourcePath: path,
            fileName: path.split(Platform.pathSeparator).last,
          );
          if (context.mounted) _bump(context);
          return a;
        case AcquireCancelled():
          return null;
        case AcquireDenied():
          if (context.mounted) _snack(context, 'Permiso denegado. Puedes activarlo en Ajustes.');
          return null;
        case AcquireUnavailable(:final message) || AcquireFailed(:final message):
          if (context.mounted) _snack(context, message);
          return null;
      }
    }

    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
    final file = picked.firstOrNull;
    final path = file?.path;
    if (file == null || path == null) return null;
    if (!context.mounted) return null;
    final result = await _withBusy(
      context,
      'Importando el PDF…',
      () => att.importPdf(noteId: noteId, sourcePath: path, fileName: file.name),
    );
    if (context.mounted) _bump(context);
    if (result.pagesNeedingOcr.isNotEmpty && context.mounted) {
      await recognizePdfPages(
        context,
        attachment: result.attachment,
        pages: result.pages,
        pageIndexes: result.pagesNeedingOcr.toList(),
      );
    }
    return result.attachment;
  } catch (e) {
    if (context.mounted) _snack(context, 'No se pudo importar: ${captureErrorMessage(e)}');
    return null;
  }
}

Future<T> _withBusy<T>(BuildContext context, String message, Future<T> Function() run) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator.adaptive(),
            const SizedBox(width: Insets.lg),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
  try {
    return await run();
  } finally {
    nav.pop();
  }
}

/// Reconoce con OCR las páginas indicadas de un PDF (render nativo → OCR → Rust), mostrando un
/// diálogo de progreso cancelable. Devuelve el nº de páginas reconocidas.
Future<int> recognizePdfPages(
  BuildContext context, {
  required Attachment attachment,
  required List<AttachmentPage> pages,
  required List<int> pageIndexes,
}) async {
  final info = await safeOcrInfo();
  if (!context.mounted) return 0;
  if (!info.available) {
    _snack(
      context,
      'Este PDF tiene páginas escaneadas, pero el reconocimiento de texto no está disponible en este dispositivo.',
    );
    return 0;
  }
  final progress = ValueNotifier<int>(0);
  var cancelled = false;
  var done = 0;
  String? error;
  final nav = Navigator.of(context, rootNavigator: true);
  var dialogOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Reconociendo texto'),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, i, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Página ${(i + 1).clamp(1, pageIndexes.length)} de ${pageIndexes.length} sin texto seleccionable',
              ),
              const SizedBox(height: Insets.md),
              LinearProgressIndicator(value: pageIndexes.isEmpty ? null : i / pageIndexes.length),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              dialogOpen = false;
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    ),
  );
  try {
    final dir = await AppPaths.pdfCacheDir(attachment.id);
    for (var i = 0; i < pageIndexes.length && !cancelled; i++) {
      progress.value = i;
      final index = pageIndexes[i];
      final page = pages.where((p) => p.pageIndex == index).firstOrNull;
      if (page == null) continue;
      try {
        final out = '${dir.path}${Platform.pathSeparator}ocr_$index.png';
        await FolioNative.renderPdfPage(attachment.path, page: index, outPath: out, targetWidth: 1700);
        if (cancelled) break;
        final ocr = await FolioNative.recognizeText(out);
        if (cancelled) break;
        await att.setPageOcr(
          pageId: page.id,
          input: ocr.toPageInput(imagePath: out),
        );
        done++;
      } catch (e) {
        error = captureErrorMessage(e);
      }
    }
  } finally {
    if (dialogOpen) nav.pop();
    progress.dispose();
  }
  if (context.mounted) {
    _bump(context);
    if (error != null && done < pageIndexes.length && !cancelled) {
      _snack(context, 'Algunas páginas no se pudieron reconocer: $error');
    } else if (cancelled) {
      _snack(context, 'Reconocimiento cancelado. Puedes retomarlo desde el adjunto.');
    }
  }
  return done;
}
