// Recorrido completo en dispositivo/emulador con el puente Rust real y el OCR nativo real
// (sin modelos de IA): carpeta → apuntes fotografiados (imagen generada) → OCR → nota → búsqueda
// por ámbito → pizarra → papelera → estados de IA sin modelo → interfaz.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/app.dart';
import 'package:folio/platform/native.dart';
import 'package:folio/src/rust/api/ai.dart' as ai;
import 'package:folio/src/rust/api/app.dart' as app;
import 'package:folio/src/rust/api/attachments.dart' as att;
import 'package:folio/src/rust/api/boards.dart' as boards;
import 'package:folio/src/rust/api/library.dart' as lib;
import 'package:folio/src/rust/api/models.dart' as models;
import 'package:folio/src/rust/api/search.dart' as search;
import 'package:folio/src/rust/api/types.dart';
import 'package:folio/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

Future<String> renderTextImage(String dir, List<String> lines) async {
  final recorder = ui.PictureRecorder();
  const w = 1400.0, h = 900.0;
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  var y = 80.0;
  for (final line in lines) {
    final tp = TextPainter(
      text: TextSpan(text: line, style: const TextStyle(color: Colors.black, fontSize: 54, fontWeight: FontWeight.w500)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w - 160);
    tp.paint(canvas, Offset(80, y));
    y += tp.height + 36;
  }
  final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$dir/apuntes_${DateTime.now().microsecondsSinceEpoch}.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file.path;
}

SearchScope folderScope(String id) => SearchScope(kind: SearchScopeKind.folder, id: id);
const libraryScope = SearchScope(kind: SearchScopeKind.library_);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final tag = DateTime.now().millisecondsSinceEpoch.toString();
  late String tmp;

  setUpAll(() async {
    await initializeDateFormatting('es');
    await RustLib.init();
    final data = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    tmp = cache.path;
    final info = await app.initApp(dataDir: data.path, cacheDir: cache.path);
    expect(info.schemaVersion, greaterThanOrEqualTo(1));
  });

  testWidgets('carpeta → OCR real → nota → búsqueda por ámbito → pizarra → papelera', (tester) async {
    final fisica = await lib.createFolder(name: 'Física $tag');
    final tema = await lib.createFolder(parentId: fisica.id, name: 'Tema 1');
    final quimica = await lib.createFolder(name: 'Química $tag');

    // Nota escrita.
    final note = await lib.createNote(folderId: quimica.id, kind: NoteKind.text, title: 'Enlaces');
    final saved = await lib.saveNote(
      id: note.id,
      title: 'Enlaces',
      bodyJson: '[{"id":"b1","type":"paragraph","text":"El enlace covalente comparte electrones zq$tag."}]',
      baseRevision: note.revision,
    );
    expect(saved.conflict, isFalse);

    // «Fotografía» de apuntes: imagen con texto impreso → OCR nativo del dispositivo.
    final ocrInfo = await FolioNative.ocrInfo();
    expect(ocrInfo.available, isTrue, reason: 'motor OCR disponible sin descargas');
    final imagePath = await tester.runAsync(
      () => renderTextImage(tmp, ['Apuntes de dinámica', 'La energía cinética depende', 'de la masa y de la velocidad.']),
    );
    final ocr = (await tester.runAsync(() => FolioNative.recognizeText(imagePath!)))!;
    // ignore: avoid_print
    print('OCR[${ocr.engine}] conf=${ocr.effectiveConfidence} líneas=${ocr.lines.length}: ${ocr.text.replaceAll('\n', ' | ')}');
    expect(ocr.text.toLowerCase(), contains('masa'));
    expect(ocr.lines, isNotEmpty);
    expect(ocr.lines.every((l) => l.x >= 0 && l.y >= 0 && l.x + l.w <= 1.001 && l.y + l.h <= 1.001), isTrue);

    // Corrección manual + guardar como nota en la subcarpeta.
    final corrected = '${ocr.text}\nCorregido a mano wx$tag';
    final scanned = await att.createNoteFromScan(
      folderId: tema.id,
      title: '',
      pages: [ocr.toPageInput(imagePath: imagePath, text: corrected)],
    );
    expect(scanned.attachments, hasLength(1));
    expect(File(scanned.attachments.first.path).existsSync(), isTrue, reason: 'la imagen se copia al almacenamiento de la app');
    final pages = await att.listAttachmentPages(attachmentId: scanned.attachments.first.id);
    expect(pages.single.textSource, TextSource.ocrEdited);
    expect(pages.single.lines, isNotEmpty, reason: 'se conserva la relación texto ↔ imagen');
    expect(scanned.bodyJson, contains(pages.single.id), reason: 'los bloques apuntan a la página de origen');

    // Búsqueda por ámbito (sin tildes y por prefijo).
    var r = await search.search(query: 'energia cinet', scope: folderScope(fisica.id), limit: 20);
    expect(r.hits.map((h) => h.noteId), contains(scanned.id), reason: 'carpeta incluye subcarpetas');
    expect(r.hits.first.location, ['Física $tag', 'Tema 1']);
    r = await search.search(query: 'energia cinet', scope: folderScope(quimica.id), limit: 20);
    expect(r.hits, isEmpty, reason: 'no se filtra contenido de otra carpeta');
    r = await search.search(query: 'wx$tag', scope: libraryScope, limit: 20);
    expect(r.hits.single.noteId, scanned.id);
    r = await search.search(query: 'zq$tag', scope: SearchScope(kind: SearchScopeKind.note, id: scanned.id), limit: 20);
    expect(r.hits, isEmpty);

    // Mover actualiza el ámbito.
    await lib.moveNote(id: note.id, folderId: tema.id);
    r = await search.search(query: 'zq$tag', scope: folderScope(fisica.id), limit: 20);
    expect(r.hits.single.noteId, note.id);

    // Pizarra con texto.
    final board = await lib.createNote(folderId: fisica.id, kind: NoteKind.board, title: 'Esquema');
    await boards.saveBoard(
      noteId: board.id,
      title: 'Esquema',
      sceneJson:
          '{"version":1,"viewport":{"x":10,"y":20,"scale":1.5},"elements":[{"id":"t1","type":"text","x":10,"y":10,"w":200,"text":"Diagrama de fuerzas pz$tag","color":"#1C1B19FF","size":20},{"id":"s1","type":"stroke","tool":"pen","color":"#1C1B19FF","width":3,"points":[0,0,0.5,10,10,0.5]}]}',
    );
    final reopened = await boards.getBoard(noteId: board.id);
    expect(reopened.sceneJson, contains('"scale":1.5'));
    expect(reopened.sceneJson, contains('stroke'));
    r = await search.search(query: 'pz$tag', scope: folderScope(fisica.id), limit: 20);
    expect(r.hits.single.noteKind, NoteKind.board);

    // Papelera: borrar saca de la búsqueda; restaurar la devuelve.
    await lib.trashNote(id: scanned.id);
    r = await search.search(query: 'wx$tag', scope: libraryScope, limit: 20);
    expect(r.hits, isEmpty);
    expect((await lib.listTrash()).map((t) => t.id), contains(scanned.id));
    await lib.restoreFromTrash(kind: TrashKind.note, id: scanned.id);
    r = await search.search(query: 'wx$tag', scope: libraryScope, limit: 20);
    expect(r.hits.single.noteId, scanned.id);

    // IA: catálogo, dispositivo y estado «sin modelo» (si no hay ninguno instalado).
    final catalog = await models.listModels();
    expect(catalog.length, 3);
    final device = await models.deviceInfo();
    // ignore: avoid_print
    print('DEVICE ram=${device.totalRamBytes} cores=${device.cpuCores} rec=${device.recommendedLlmId} notas=${device.notes}');
    final status = await ai.aiStatus();
    if (!status.llmInstalled) {
      final events = await tester.runAsync(
        () => ai.ask(scope: AiScope(kind: ScopeKind.note, ids: [scanned.id]), question: '¿De qué depende la energía cinética?').toList(),
      );
      expect(events!.last.kind, AiEventKind.error);
      expect(events.last.text, contains('Instala un modelo'));
    }
    final scope = await ai.describeScope(scope: AiScope(kind: ScopeKind.folder, ids: [fisica.id]));
    expect(scope.noteCount, 3);
  });

  testWidgets('interfaz: biblioteca, búsqueda inferior y nota', (tester) async {
    final folder = await lib.createFolder(name: 'Biología $tag');
    final n = await lib.createNote(folderId: folder.id, kind: NoteKind.text, title: 'Célula $tag');
    await lib.saveNote(
      id: n.id,
      title: 'Célula $tag',
      bodyJson: '[{"id":"b1","type":"heading1","text":"Orgánulos"},{"id":"b2","type":"todo","text":"Repasar mitocondrias","checked":true}]',
      baseRevision: n.revision,
    );

    await tester.pumpWidget(const ProviderScope(child: FolioApp()));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Folio'), findsWidgets);
    expect(find.text('Carpetas'), findsOneWidget);
    expect(find.text('Buscar en todas las notas'), findsOneWidget);

    // Búsqueda inferior en toda la biblioteca.
    await tester.tap(find.text('Buscar en todas las notas'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'mitocondr');
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(find.textContaining('Célula $tag'), findsWidgets);
    await tester.tap(find.textContaining('Célula $tag').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Se abre la nota con su contenido.
    // ignore: avoid_print
    print('TEXTOS: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText()).take(40).toList()}');
    expect(find.text('Buscar en esta nota'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Célula $tag'), findsOneWidget);
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(editor.controller.document.toPlainText(), contains('Orgánulos'));
    expect(editor.controller.document.toPlainText(), contains('Repasar mitocondrias'));
  });
}
