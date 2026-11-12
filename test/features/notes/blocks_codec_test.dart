import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/notes/blocks_codec.dart';

/// Generador determinista de ids para las pruebas.
String Function() _ids([String prefix = 'n']) {
  var i = 0;
  return () => '$prefix${++i}';
}

/// Ida y vuelta pasando por un documento Quill real (valida que el Delta es cargable).
List<NoteBlock> _roundTrip(List<NoteBlock> blocks) {
  final doc = Document.fromDelta(blocksToDelta(blocks));
  return deltaToBlocks(doc.toDelta(), previous: blocks, generateId: _ids());
}

const _sample = '''
[
  {"id": "h1", "type": "heading1", "text": "Tema 2 · Cinemática"},
  {"id": "h2", "type": "heading2", "text": "Velocidad"},
  {"id": "h3", "type": "heading3", "text": "Media"},
  {"id": "p1", "type": "paragraph", "text": "La velocidad es…"},
  {"id": "b1", "type": "bullet", "text": "Posición"},
  {"id": "b2", "type": "bullet", "text": "Desplazamiento", "indent": 1},
  {"id": "n1", "type": "numbered", "text": "Primer paso"},
  {"id": "n2", "type": "numbered", "text": "Subpaso", "indent": 2},
  {"id": "t1", "type": "todo", "text": "Repasar ejercicios", "checked": true},
  {"id": "t2", "type": "todo", "text": "Hacer resumen", "indent": 3},
  {"id": "q1", "type": "quote", "text": "Cita"},
  {"id": "d1", "type": "divider"},
  {"id": "i1", "type": "image", "attachment_id": "att-img"},
  {"id": "f1", "type": "pdf", "attachment_id": "att-pdf"},
  {"id": "k1", "type": "board_link", "note_id": "board-1"},
  {"id": "o1", "type": "paragraph", "text": "Texto de OCR\\ncon salto suave", "source_page_id": "page-1"},
  {"id": "e1", "type": "paragraph"}
]
''';

void main() {
  group('JSON', () {
    test('parse y serializa sin cambios (campos por defecto omitidos)', () {
      final blocks = parseBlocks(_sample);
      expect(blocks, hasLength(17));
      expect(jsonDecode(encodeBlocks(blocks)), jsonDecode(_sample));
    });

    test('cadena vacía = lista vacía', () {
      expect(parseBlocks(''), isEmpty);
      expect(parseBlocks('[]'), isEmpty);
      expect(encodeBlocks(const []), '[]');
    });

    test('JSON no válido lanza BlocksFormatException', () {
      expect(() => parseBlocks('{'), throwsA(isA<BlocksFormatException>()));
      expect(() => parseBlocks('{"a":1}'), throwsA(isA<BlocksFormatException>()));
      expect(() => parseBlocks('[1]'), throwsA(isA<BlocksFormatException>()));
    });

    test('ids duplicados o ausentes se regeneran', () {
      final blocks = parseBlocks('[{"id":"a","type":"paragraph","text":"x"},{"id":"a","type":"paragraph"},{"type":"quote"}]');
      final ids = blocks.map((b) => b.id).toList();
      expect(ids.first, 'a');
      expect(ids.toSet(), hasLength(3));
      expect(ids.every((i) => i.isNotEmpty), isTrue);
    });

    test('indent fuera de rango se acota y solo se emite en listas', () {
      final b = parseBlocks('[{"id":"a","type":"bullet","text":"x","indent":7},{"id":"b","type":"paragraph","text":"y","indent":2}]');
      expect(b[0].indent, 3);
      expect(b[0].toJson()['indent'], 3);
      expect(b[1].toJson().containsKey('indent'), isFalse);
    });

    test('checked solo se emite en todo y si es true', () {
      final b = parseBlocks('[{"id":"a","type":"todo","text":"x","checked":false},{"id":"b","type":"bullet","text":"y","checked":true}]');
      expect(b[0].toJson().containsKey('checked'), isFalse);
      expect(b[1].toJson().containsKey('checked'), isFalse);
    });

    test('campos extra y tipos desconocidos se conservan', () {
      const json = '[{"id":"a","type":"paragraph","text":"x","color":"red"},'
          '{"id":"u","type":"table","rows":[[1,2]],"text":"t"}]';
      final blocks = parseBlocks(json);
      expect(blocks[0].extra, {'color': 'red'});
      expect(blocks[1].type, BlockType.unknown);
      expect(jsonDecode(encodeBlocks(blocks)), jsonDecode(json));
    });
  });

  group('Delta', () {
    test('bloques → delta: atributos de línea y embeds', () {
      final delta = blocksToDelta(parseBlocks(_sample));
      final ops = delta.toList();
      // Líneas (texto, atributos) tal como las ve Quill.
      final lines = <(String, Map<String, dynamic>?)>[];
      var buf = StringBuffer();
      for (final o in ops) {
        if (o.data is! String) continue;
        final parts = (o.data as String).split('\n');
        for (var i = 0; i < parts.length; i++) {
          buf.write(parts[i]);
          if (i < parts.length - 1) {
            lines.add((buf.toString(), o.attributes));
            buf = StringBuffer();
          }
        }
      }
      ({Map<String, dynamic>? attributes}) lineEnd(String text) =>
          (attributes: lines.firstWhere((l) => l.$1 == text).$2);

      expect(lineEnd('Tema 2 · Cinemática').attributes, {'header': 1});
      expect(lineEnd('Velocidad').attributes, {'header': 2});
      expect(lineEnd('Media').attributes, {'header': 3});
      expect(lineEnd('La velocidad es…').attributes, isNull);
      expect(lineEnd('Posición').attributes, {'list': 'bullet'});
      expect(lineEnd('Desplazamiento').attributes, {'list': 'bullet', 'indent': 1});
      expect(lineEnd('Primer paso').attributes, {'list': 'ordered'});
      expect(lineEnd('Subpaso').attributes, {'list': 'ordered', 'indent': 2});
      expect(lineEnd('Repasar ejercicios').attributes, {'list': 'checked'});
      expect(lineEnd('Hacer resumen').attributes, {'list': 'unchecked', 'indent': 3});
      expect(lineEnd('Cita').attributes, {'blockquote': true});
      // Salto suave → U+2028 dentro de la misma línea.
      expect(lines.any((l) => l.$1 == 'Texto de OCR\u2028con salto suave'), isTrue);
      final embedTypes = [
        for (final o in ops)
          if (o.data is Map) (o.data as Map).keys.single,
      ];
      expect(embedTypes, [FolioEmbeds.divider, FolioEmbeds.image, FolioEmbeds.pdf, FolioEmbeds.board]);
      // Línea vacía final de cortesía.
      expect(ops.last.data as String, endsWith('\n\n'));
    });

    test('sin formato en línea: los atributos de texto se ignoran', () {
      final delta = Delta()
        ..insert('Hola ', {'bold': true})
        ..insert('mundo', {'italic': true, 'link': 'https://x'})
        ..insert('\n', {'header': 2})
        ..insert('\n');
      final blocks = deltaToBlocks(delta, generateId: _ids());
      expect(blocks.single.type, BlockType.heading2);
      expect(blocks.single.text, 'Hola mundo');
      expect(blocks.single.toJson().keys, unorderedEquals(['id', 'type', 'text']));
    });

    test('documento vacío ↔ lista vacía', () {
      expect(deltaToBlocks(Document().toDelta()), isEmpty);
      expect(blocksToDelta(const []).toList().single.data, '\n');
      expect(_roundTrip(const []), isEmpty);
    });

    test('cabeceras 4-6 se convierten en heading3; code-block en párrafo', () {
      final delta = Delta()
        ..insert('a')
        ..insert('\n', {'header': 5})
        ..insert('b')
        ..insert('\n', {'code-block': true})
        ..insert('\n');
      final blocks = deltaToBlocks(delta, generateId: _ids());
      expect(blocks.map((b) => b.type), [BlockType.heading3, BlockType.paragraph]);
    });

    test('lista tiene prioridad sobre cabecera; indent solo en listas y acotado a 3', () {
      final delta = Delta()
        ..insert('a')
        ..insert('\n', {'list': 'bullet', 'header': 1, 'indent': 5})
        ..insert('b')
        ..insert('\n', {'indent': 2})
        ..insert('\n');
      final blocks = deltaToBlocks(delta, generateId: _ids());
      expect(blocks[0].type, BlockType.bullet);
      expect(blocks[0].indent, 3);
      expect(blocks[1].type, BlockType.paragraph);
      expect(blocks[1].indent, 0);
    });

    test('texto y embed en la misma línea se separan en bloques', () {
      final img = NoteBlock(id: 'i', type: BlockType.image, attachmentId: 'a');
      final delta = Delta()
        ..insert('antes')
        ..insert({FolioEmbeds.image: FolioEmbeds.dataFor(img)})
        ..insert('después')
        ..insert('\n', {'list': 'bullet'});
      final blocks = deltaToBlocks(delta, generateId: _ids());
      expect(blocks.map((b) => b.type), [BlockType.bullet, BlockType.image, BlockType.bullet]);
      expect(blocks.map((b) => b.text), ['antes', '', 'después']);
      expect(blocks[1].id, 'i');
    });

    test('embeds desconocidos de Quill (p. ej. imagen estándar) se descartan', () {
      final delta = Delta()
        ..insert({'image': 'https://x/y.png'})
        ..insert('\n')
        ..insert('texto\n');
      final blocks = deltaToBlocks(delta, generateId: _ids());
      expect(blocks.single.text, 'texto');
    });

    test('documento sin salto final se cierra igualmente', () {
      final delta = Delta()..insert('abc');
      expect(deltaToBlocks(delta, generateId: _ids()).single.text, 'abc');
    });
  });

  group('Ida y vuelta', () {
    test('muestra completa: idéntica (ids, source_page_id, saltos suaves)', () {
      final blocks = parseBlocks(_sample);
      final back = _roundTrip(blocks);
      expect(back, blocks);
      expect(encodeBlocks(back), encodeBlocks(blocks));
    });

    test('termina en embed / termina en párrafo vacío / solo vacíos', () {
      for (final json in [
        '[{"id":"a","type":"paragraph","text":"x"},{"id":"i","type":"image","attachment_id":"z"}]',
        '[{"id":"a","type":"paragraph","text":"x"},{"id":"b","type":"paragraph"}]',
        '[{"id":"a","type":"paragraph"},{"id":"b","type":"paragraph"}]',
        '[{"id":"a","type":"bullet"}]',
        '[{"id":"d","type":"divider"},{"id":"e","type":"divider"}]',
      ]) {
        final blocks = parseBlocks(json);
        expect(encodeBlocks(_roundTrip(blocks)), encodeBlocks(blocks), reason: json);
      }
    });

    test('todas las combinaciones de tipo × sangría × marcado', () {
      final blocks = <NoteBlock>[];
      var n = 0;
      for (final t in BlockType.values.where((t) => t.hasText)) {
        for (final indent in [0, 1, 2, 3]) {
          for (final checked in [false, true]) {
            blocks.add(NoteBlock(id: 'b${n++}', type: t, text: 'texto $n', indent: t.isList ? indent : 0, checked: t == BlockType.todo && checked));
          }
        }
      }
      expect(encodeBlocks(_roundTrip(blocks)), encodeBlocks(blocks));
    });

    test('caracteres especiales: emojis, U+E000, comillas, tabulaciones, \\r\\n', () {
      final blocks = [
        const NoteBlock(id: 'a', type: BlockType.paragraph, text: 'Átomo 🧪 «comillas» "dobles"\tTab'),
        const NoteBlock(id: 'b', type: BlockType.quote, text: 'línea1\nlínea2\n\nlínea4'),
        const NoteBlock(id: 'c', type: BlockType.bullet, text: '  espacios  '),
      ];
      expect(encodeBlocks(_roundTrip(blocks)), encodeBlocks(blocks));
      final crlf = [const NoteBlock(id: 'x', type: BlockType.paragraph, text: 'a\r\nb')];
      expect(_roundTrip(crlf).single.text, 'a\nb');
    });

    test('bloque desconocido sobrevive dentro del documento', () {
      final blocks = parseBlocks('[{"id":"a","type":"paragraph","text":"x"},{"id":"u","type":"table","rows":[1]},{"id":"b","type":"paragraph","text":"y"}]');
      final back = _roundTrip(blocks);
      expect(jsonDecode(encodeBlocks(back)), jsonDecode(encodeBlocks(blocks)));
    });
  });

  group('Conservación de ids tras editar', () {
    late List<NoteBlock> original;
    late Document doc;

    setUp(() {
      original = parseBlocks(_sample);
      doc = Document.fromDelta(blocksToDelta(original));
    });

    List<NoteBlock> decode() => deltaToBlocks(doc.toDelta(), previous: original, generateId: _ids('new'));

    int offsetOf(String id) => blockRanges(original)[original.indexWhere((b) => b.id == id)].start;

    test('editar el texto de un bloque conserva su id y source_page_id', () {
      doc.insert(offsetOf('o1'), 'Corregido: ');
      final out = decode();
      final ocr = out.firstWhere((b) => b.text.startsWith('Corregido'));
      expect(ocr.id, 'o1');
      expect(ocr.sourcePageId, 'page-1');
      expect(out.map((b) => b.id), original.map((b) => b.id));
    });

    test('insertar una línea nueva genera id nuevo y no altera los demás', () {
      final at = offsetOf('p1');
      doc.insert(at, 'Nueva línea\n');
      final out = decode();
      expect(out, hasLength(original.length + 1));
      expect(out[3].text, 'Nueva línea');
      expect(out[3].id, startsWith('new'));
      expect(out[4].id, 'p1');
      expect(out.where((b) => b.id.startsWith('new')), hasLength(1));
    });

    test('partir un bloque (Intro en medio) conserva el id en la primera parte', () {
      final r = blockRanges(original)[original.indexWhere((b) => b.id == 'b2')];
      doc.insert(r.start + 5, '\n');
      final out = decode();
      final i = out.indexWhere((b) => b.id == 'b2');
      expect(out[i].text, 'Despl');
      expect(out[i + 1].text, 'azamiento');
      expect(out[i + 1].type, BlockType.bullet);
      expect(out[i + 1].indent, 1);
      expect(out[i + 1].id, startsWith('new'));
    });

    test('borrar un bloque y reordenar conserva los ids de los demás', () {
      final r = blockRanges(original)[original.indexWhere((b) => b.id == 'h2')];
      doc.delete(r.start, r.length + 1);
      final out = decode();
      expect(out.map((b) => b.id), original.where((b) => b.id != 'h2').map((b) => b.id));
    });

    test('cambiar el tipo (párrafo → título) conserva el id', () {
      final r = blockRanges(original)[original.indexWhere((b) => b.id == 'p1')];
      doc.format(r.start, 0, Attribute.h2);
      final out = decode();
      final b = out.firstWhere((b) => b.id == 'p1');
      expect(b.type, BlockType.heading2);
      expect(b.text, 'La velocidad es…');
    });

    test('marcar una tarea conserva el id', () {
      final r = blockRanges(original)[original.indexWhere((b) => b.id == 't2')];
      doc.format(r.start, 0, Attribute.checked);
      final out = decode();
      final b = out.firstWhere((b) => b.id == 't2');
      expect(b.checked, isTrue);
      expect(b.indent, 3);
    });

    test('mover un bloque idéntico lo reconoce por tipo+texto', () {
      final prev = [
        const NoteBlock(id: 'a', type: BlockType.paragraph, text: 'uno'),
        const NoteBlock(id: 'b', type: BlockType.paragraph, text: 'dos'),
        const NoteBlock(id: 'c', type: BlockType.paragraph, text: 'tres', sourcePageId: 'pg'),
      ];
      final moved = [prev[2], prev[0], prev[1]];
      final out = deltaToBlocks(blocksToDelta(moved), previous: prev, generateId: _ids('new'));
      // LCS mantiene a y b; c se reconoce por tipo+texto aunque haya cambiado de posición.
      expect(out.map((b) => b.text), ['tres', 'uno', 'dos']);
      expect(out.map((b) => b.id), ['c', 'a', 'b']);
      expect(out.first.sourcePageId, 'pg');
    });

    test('embed copiado/pegado recibe id nuevo; el original conserva el suyo', () {
      final img = original.firstWhere((b) => b.id == 'i1');
      final at = offsetOf('p1');
      doc.insert(at, BlockEmbed(FolioEmbeds.image, FolioEmbeds.dataFor(img)));
      final out = decode();
      final images = out.where((b) => b.type == BlockType.image).toList();
      expect(images, hasLength(2));
      expect(images.map((b) => b.attachmentId), ['att-img', 'att-img']);
      expect(images.last.id, 'i1');
      expect(images.first.id, startsWith('new'));
      expect(out.map((b) => b.id).toSet(), hasLength(out.length));
    });

    test('insertar un adjunto con Quill lo coloca en su propia línea', () {
      final pdf = NoteBlock(id: 'nuevo-pdf', type: BlockType.pdf, attachmentId: 'att-2');
      final r = blockRanges(original)[original.indexWhere((b) => b.id == 'p1')];
      // En mitad del texto: Quill parte la línea.
      doc.insert(r.start + 3, BlockEmbed(FolioEmbeds.pdf, FolioEmbeds.dataFor(pdf)));
      final out = decode();
      final i = out.indexWhere((b) => b.id == 'nuevo-pdf');
      expect(i, greaterThan(0));
      expect(out[i - 1].id, 'p1');
      expect(out[i - 1].text, 'La ');
      expect(out[i + 1].text, 'velocidad es…');
    });

    test('reescribir todo el documento con textos distintos reutiliza ids por posición', () {
      final prev = [
        const NoteBlock(id: 'a', type: BlockType.paragraph, text: 'uno'),
        const NoteBlock(id: 'b', type: BlockType.paragraph, text: 'dos'),
      ];
      final next = [
        const NoteBlock(id: 'x', type: BlockType.paragraph, text: 'ONE'),
        const NoteBlock(id: 'y', type: BlockType.paragraph, text: 'TWO'),
        const NoteBlock(id: 'z', type: BlockType.paragraph, text: 'THREE'),
      ];
      final out = deltaToBlocks(blocksToDelta(next), previous: prev, generateId: _ids('new'));
      expect(out.map((b) => b.id), ['a', 'b', 'new1']);
    });

    test('documentos grandes: alineación rápida y correcta', () {
      final prev = [for (var i = 0; i < 3000; i++) NoteBlock(id: 'id$i', type: BlockType.paragraph, text: 'línea $i')];
      final edited = [...prev]..insert(1500, const NoteBlock(id: 'tmp', type: BlockType.paragraph, text: 'insertada'));
      final sw = Stopwatch()..start();
      final out = deltaToBlocks(blocksToDelta(edited), previous: prev, generateId: _ids('new'));
      sw.stop();
      expect(out, hasLength(3001));
      expect(out[1500].id, 'new1');
      expect(out[1501].id, 'id1500');
      expect(out.last.id, 'id2999');
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('Rangos', () {
    test('blockRanges coincide con los offsets del documento Quill', () {
      final blocks = parseBlocks(_sample);
      final doc = Document.fromDelta(blocksToDelta(blocks));
      final plain = doc.toPlainText();
      final ranges = blockRanges(blocks);
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        final r = ranges[i];
        if (b.type.hasText) {
          expect(plain.substring(r.start, r.start + r.length), b.text.replaceAll('\n', softBreak));
        } else {
          expect(plain.substring(r.start, r.start + 1), Embed.kObjectReplacementCharacter);
        }
        expect(plain[r.start + r.length], '\n');
      }
    });
  });

  testWidgets('el Delta se puede mostrar en un QuillEditor sin errores', (tester) async {
    final controller = QuillController(
      document: Document.fromDelta(blocksToDelta(parseBlocks('[{"id":"a","type":"todo","text":"x"},{"id":"b","type":"quote","text":"q"}]'))),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(body: QuillEditor.basic(controller: controller)),
      ),
    );
    expect(find.byType(QuillEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
