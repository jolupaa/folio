// Prueba real de IA en dispositivo/emulador (larga; descarga ~1,9 GB):
//   flutter test integration_test/ai_device_test.dart -d <dispositivo>
// Descarga los modelos con el gestor de la app, verifica SHA-256, indexa, pregunta y genera
// materiales. Después espera a que se active el MODO AVIÓN (marca FOLIO_AIRPLANE_NOW en el log)
// y repite pregunta + resumen sin red.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/src/rust/api/ai.dart' as ai;
import 'package:folio/src/rust/api/app.dart' as app;
import 'package:folio/src/rust/api/library.dart' as lib;
import 'package:folio/src/rust/api/models.dart' as models;
import 'package:folio/src/rust/api/study.dart' as study;
import 'package:folio/src/rust/api/types.dart';
import 'package:folio/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// ignore: avoid_print
void log(String s) => print('FOLIO_AI $s');

Future<void> download(String id) async {
  final sw = Stopwatch()..start();
  var lastPct = -10;
  await for (final e in models.downloadModel(modelId: id)) {
    final pct = e.totalBytes == 0 ? 0 : (e.downloadedBytes * 100 ~/ e.totalBytes);
    if (e.kind == DownloadEventKind.progress && pct >= lastPct + 10) {
      lastPct = pct;
      log('descarga $id $pct% (${(e.bytesPerSecond / 1e6).toStringAsFixed(1)} MB/s)');
    }
    if (e.kind == DownloadEventKind.verifying) log('verificando $id');
    if (e.kind == DownloadEventKind.failed) fail('descarga $id: ${e.message}');
    if (e.kind == DownloadEventKind.completed) {
      log('instalado $id en ${sw.elapsed.inSeconds}s');
      return;
    }
  }
}

Future<AiEvent> run(String label, Stream<AiEvent> stream) async {
  final sw = Stopwatch()..start();
  int? firstMs;
  AiEvent? last;
  await for (final e in stream) {
    if (e.kind == AiEventKind.token) firstMs ??= sw.elapsedMilliseconds;
    if (e.kind == AiEventKind.progress) log('  · ${e.text}');
    last = e;
  }
  log('$label → ${last!.kind} en ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s (primer texto ${firstMs == null ? '-' : (firstMs / 1000).toStringAsFixed(1)}s)');
  log('  ${last.text.replaceAll('\n', ' ⏎ ')}');
  return last;
}

Future<bool> online() async {
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    final req = await c.getUrl(Uri.parse('https://huggingface.co/robots.txt')).timeout(const Duration(seconds: 6));
    final res = await req.close().timeout(const Duration(seconds: 6));
    await res.drain<void>();
    c.close(force: true);
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('descarga, IA local y modo avión', timeout: const Timeout(Duration(minutes: 60)), (tester) async {
    await tester.runAsync(() async {
      await RustLib.init();
      final data = await getApplicationSupportDirectory();
      final cache = await getTemporaryDirectory();
      await app.initApp(dataDir: data.path, cacheDir: cache.path);
      final device = await models.deviceInfo();
      log('dispositivo: RAM ${(device.totalRamBytes / 1e9).toStringAsFixed(1)} GB, ${device.cpuCores} núcleos, ${device.arch}');

      for (final id in ['qwen3-embedding-0.6b-q8', 'qwen3.5-2b-q4km']) {
        final m = (await models.listModels()).firstWhere((m) => m.id == id);
        if (m.status != ModelStatus.installed) await download(id);
      }
      await models.setActiveLlm(modelId: 'qwen3.5-2b-q4km');
      final status = await ai.aiStatus();
      expect(status.llmInstalled && status.embeddingInstalled, isTrue);

      final tag = DateTime.now().millisecondsSinceEpoch;
      final folder = await lib.createFolder(name: 'Física IA $tag');
      Future<void> note(String title, List<String> ps) async {
        final n = await lib.createNote(folderId: folder.id, kind: NoteKind.text, title: title);
        final body = '[${[for (var i = 0; i < ps.length; i++) '{"id":"b$i","type":"paragraph","text":"${ps[i]}"}'].join(',')}]';
        await lib.saveNote(id: n.id, title: title, bodyJson: body, baseRevision: n.revision);
      }

      await note('Cinemática', [
        'La velocidad media es el desplazamiento dividido entre el tiempo empleado y se mide en metros por segundo.',
        'La aceleración es el cambio de velocidad por unidad de tiempo y se mide en metros por segundo al cuadrado.',
        'En la caída libre los cuerpos aceleran con g = 9,8 m/s² cerca de la superficie de la Tierra.',
      ]);
      await note('Leyes de Newton', [
        'Segunda ley: la fuerza neta es igual a la masa por la aceleración. La fuerza se mide en newtons.',
        'Tercera ley: a toda acción le corresponde una reacción igual y de sentido contrario.',
      ]);
      final scope = AiScope(kind: ScopeKind.folder, ids: [folder.id]);

      final sw = Stopwatch()..start();
      while (true) {
        final s = await ai.describeScope(scope: scope);
        if (s.pendingNotes == 0 && s.chunkCount > 0 && s.embeddedChunkCount == s.chunkCount) break;
        if (sw.elapsed > const Duration(minutes: 5)) fail('índice lento: ${s.chunkCount}/${s.embeddedChunkCount} pendientes ${s.pendingNotes}');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      log('índice con embeddings listo en ${sw.elapsed.inSeconds}s');

      var a = await run('pregunta (con red)', ai.ask(scope: scope, question: '¿En qué unidad se mide la fuerza según la segunda ley de Newton?'));
      expect(a.kind, AiEventKind.done);
      expect(a.text.toLowerCase(), contains('newton'));
      expect(a.citations, isNotEmpty);

      final cards = await run(
        'flashcards',
        ai.generateStudy(
          kind: StudyKind.flashcards,
          scope: scope,
          options: const StudyOptions(detail: DetailLevel.brief, count: 4, quizMix: QuizMix.mixed),
        ),
      );
      expect(cards.kind, AiEventKind.done);
      final item = await study.getStudyItem(id: cards.resultId!);
      expect(item.contentJson, contains('"cards"'));

      // ── Modo avión ──
      log('FOLIO_AIRPLANE_NOW');
      final wait = Stopwatch()..start();
      while (await online()) {
        if (wait.elapsed > const Duration(minutes: 4)) fail('no se activó el modo avión');
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      log('sin red: confirmado');
      await ai.releaseAiMemory(); // fuerza recarga del modelo desde disco, sin red

      a = await run('pregunta (modo avión)', ai.ask(scope: scope, question: '¿Cuánto vale la aceleración en la caída libre?'));
      expect(a.kind, AiEventKind.done);
      expect(a.insufficient, isFalse);
      expect(a.citations, isNotEmpty);
      log('  ¿incluye el dato 9,8?: ${a.text.contains('9,8')}');
      final sum = await run(
        'resumen (modo avión)',
        ai.generateStudy(
          kind: StudyKind.summary,
          scope: scope,
          options: const StudyOptions(detail: DetailLevel.brief, count: 5, quizMix: QuizMix.mixed),
        ),
      );
      expect(sum.kind, AiEventKind.done);
      log('FOLIO_DONE');
    });
  });
}
