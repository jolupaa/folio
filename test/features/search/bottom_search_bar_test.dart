import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/theme.dart';
import 'package:folio/core/navigation.dart';
import 'package:folio/features/search/bottom_search_bar.dart';
import 'package:folio/features/search/search_service.dart';
import 'package:folio/src/rust/api/types.dart';
import 'package:folio/widgets/highlighted_text.dart';

SearchHit _hit({
  String id = 'n1',
  String title = 'Cinemática',
  String snippet = 'La \uE000velo\uE001cidad media…',
  MatchField matchedIn = MatchField.body,
  List<String> location = const ['Física', 'Tema 2'],
  String? attachmentName,
  int? pageIndex,
  NoteKind kind = NoteKind.text,
}) => SearchHit(
  noteId: id,
  noteKind: kind,
  title: title,
  snippet: snippet,
  matchedIn: matchedIn,
  location: location,
  pageId: pageIndex == null ? null : 'p',
  attachmentId: attachmentName == null ? null : 'a',
  attachmentName: attachmentName,
  pageIndex: pageIndex,
  updatedAt: 0,
  score: 1,
);

/// Buscador falso: registra llamadas y responde con lo que diga [respond].
class _FakeSearch {
  _FakeSearch([this.respond]);
  final List<(String, SearchScope)> calls = [];
  Future<SearchResults> Function(String q, SearchScope s)? respond;

  Future<SearchResults> call(String q, SearchScope s, int limit) {
    calls.add((q, s));
    return respond?.call(q, s) ?? Future.value(SearchResults(query: q, hits: [_hit()], elapsedMs: 1));
  }
}

Widget _app(_FakeSearch fake, Widget child, {Brightness brightness = Brightness.light}) => ProviderScope(
  overrides: [searchFunctionProvider.overrideWithValue(fake.call)],
  child: MaterialApp(
    theme: buildTheme(brightness),
    home: Scaffold(resizeToAvoidBottomInset: false, body: child),
  ),
);

Widget _bar({SearchScope scope = Scopes.searchLibrary, String placeholder = 'Buscar en todas las notas', Widget? trailing}) =>
    BottomSearchBar(
      scope: scope,
      placeholder: placeholder,
      trailing: trailing,
      body: const Center(child: Text('CONTENIDO')),
    );

/// Spans de texto con fondo de resaltado dentro de los RichText visibles.
List<TextSpan> _highlightedSpans(WidgetTester tester, Color highlight) {
  final out = <TextSpan>[];
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    rt.text.visitChildren((span) {
      if (span is TextSpan && span.style?.backgroundColor == highlight && (span.text ?? '').isNotEmpty) out.add(span);
      return true;
    });
  }
  return out;
}

void main() {
  group('parseHighlights', () {
    test('marca coincidencias y tolera marcadores desparejados', () {
      expect(parseHighlights('a \uE000b\uE001 c'), [
        (text: 'a ', match: false),
        (text: 'b', match: true),
        (text: ' c', match: false),
      ]);
      expect(parseHighlights('\uE000todo'), [(text: 'todo', match: true)]);
      expect(parseHighlights('fin\uE001 suelto'), [(text: 'fin suelto', match: false)]);
      expect(parseHighlights(''), isEmpty);
      expect(stripHighlights('x\uE000y\uE001z'), 'xyz');
    });
  });

  group('BottomSearchBar', () {
    testWidgets('muestra el ámbito como placeholder y no abre el teclado al aparecer', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar(scope: Scopes.searchFolder('f1'), placeholder: 'Buscar en Física')));
      expect(find.text('Buscar en Física'), findsOneWidget);
      expect(find.text('CONTENIDO'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isFalse);
      expect(find.text('Toda la biblioteca'), findsNothing);
      expect(fake.calls, isEmpty);
    });

    testWidgets('al enfocar muestra el panel y el chip «Toda la biblioteca» en carpetas', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar(scope: Scopes.searchFolder('f1'), placeholder: 'Buscar en Física')));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('Toda la biblioteca'), findsOneWidget);
      expect(find.text('Escribe para buscar'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
    });

    testWidgets('en la biblioteca no hay chip para ampliar', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar()));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('Toda la biblioteca'), findsNothing);
    });

    testWidgets('el botón componer se muestra en reposo y se sustituye por «Cancelar» al buscar', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar(trailing: IconButton(onPressed: () {}, icon: const Icon(Icons.edit_square), tooltip: 'Nueva'))));
      expect(find.byTooltip('Nueva'), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byTooltip('Nueva'), findsNothing);
      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      expect(find.byTooltip('Nueva'), findsOneWidget);
      expect(find.text('Escribe para buscar'), findsNothing);
    });

    testWidgets('resultados con coincidencias resaltadas, ubicación y debounce', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar()));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'v');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 've');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 'velo');
      expect(fake.calls, isEmpty, reason: 'debounce: aún no se busca');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(fake.calls, hasLength(1));
      expect(fake.calls.single.$1, 'velo');
      expect(fake.calls.single.$2, Scopes.searchLibrary);

      expect(find.text('Cinemática'), findsOneWidget);
      expect(find.text('Física › Tema 2'), findsOneWidget);
      expect(find.text('1 resultado'), findsOneWidget);
      final spans = _highlightedSpans(tester, FolioColors.light.highlight);
      expect(spans.map((s) => s.text), ['velo']);
    });

    testWidgets('resaltado con el token de tema oscuro', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar(), brightness: Brightness.dark));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'velo');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(_highlightedSpans(tester, FolioColors.dark.highlight).map((s) => s.text), ['velo']);
    });

    testWidgets('coincidencias en adjuntos muestran nombre y página (1-based)', (tester) async {
      final fake = _FakeSearch(
        (q, s) async => SearchResults(
          query: q,
          hits: [_hit(matchedIn: MatchField.attachment, attachmentName: 'apuntes.pdf', pageIndex: 2, location: const [])],
          elapsedMs: 1,
        ),
      );
      await tester.pumpWidget(_app(fake, _bar()));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'velo');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(find.text('Notas · apuntes.pdf · Página 3'), findsOneWidget);
      expect(find.byIcon(Icons.picture_as_pdf_rounded), findsOneWidget);
    });

    testWidgets('descarta respuestas viejas (número de petición)', (tester) async {
      final pending = <String, Completer<SearchResults>>{};
      final fake = _FakeSearch((q, s) => (pending[q] = Completer<SearchResults>()).future);
      await tester.pumpWidget(_app(fake, _bar()));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'ci');
      await tester.pump(searchDebounce);
      await tester.enterText(find.byType(TextField), 'cine');
      await tester.pump(searchDebounce);
      expect(fake.calls.map((c) => c.$1), ['ci', 'cine']);

      pending['cine']!.complete(SearchResults(query: 'cine', hits: [_hit(title: 'Nueva')], elapsedMs: 1));
      await tester.pump();
      pending['ci']!.complete(SearchResults(query: 'ci', hits: [_hit(title: 'Vieja')], elapsedMs: 1));
      await tester.pump();
      expect(find.text('Nueva'), findsOneWidget);
      expect(find.text('Vieja'), findsNothing);
    });

    testWidgets('el chip amplía el ámbito y vuelve a buscar en toda la biblioteca', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar(scope: Scopes.searchFolder('f1'), placeholder: 'Buscar en Física')));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'velo');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(fake.calls.last.$2, Scopes.searchFolder('f1'));
      await tester.tap(find.text('Toda la biblioteca'));
      await tester.pump();
      await tester.pump();
      expect(fake.calls.last.$2, Scopes.searchLibrary);
      expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
    });

    testWidgets('sin resultados: mensaje y atajo para ampliar', (tester) async {
      final fake = _FakeSearch((q, s) async => SearchResults(query: q, hits: const [], elapsedMs: 1));
      await tester.pumpWidget(_app(fake, _bar(scope: Scopes.searchFolder('f1'), placeholder: 'Buscar en Física')));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(find.text('Sin resultados'), findsOneWidget);
      expect(find.text('No hay coincidencias para «zzz».'), findsOneWidget);
      expect(find.text('Buscar en toda la biblioteca'), findsOneWidget);
    });

    testWidgets('error de búsqueda con reintento', (tester) async {
      var fail = true;
      final fake = _FakeSearch((q, s) async {
        if (fail) throw Exception('índice no disponible');
        return SearchResults(query: q, hits: [_hit()], elapsedMs: 1);
      });
      await tester.pumpWidget(_app(fake, _bar()));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'velo');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(find.text('No se pudo buscar'), findsOneWidget);
      expect(find.text('índice no disponible'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Cinemática'), findsOneWidget);
    });

    testWidgets('la barra sube con el teclado (viewInsets)', (tester) async {
      final fake = _FakeSearch();
      await tester.pumpWidget(_app(fake, _bar()));
      final before = tester.getBottomLeft(find.byType(TextField)).dy;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      final after = tester.getBottomLeft(find.byType(TextField)).dy;
      expect(before - after, closeTo(300 / tester.view.devicePixelRatio, 1));
    });

    testWidgets('modo compacto: solo resultados filtrados y sin cubrir el contenido', (tester) async {
      final fake = _FakeSearch(
        (q, s) async => SearchResults(
          query: q,
          hits: [
            _hit(title: 'Texto'),
            _hit(title: 'Adjunto', matchedIn: MatchField.attachment, attachmentName: 'foto.jpg', pageIndex: 0),
          ],
          elapsedMs: 1,
        ),
      );
      SearchHit? tapped;
      await tester.pumpWidget(
        _app(
          fake,
          BottomSearchBar(
            scope: Scopes.searchNote('n1'),
            placeholder: 'Buscar en esta nota',
            compactResults: true,
            hitFilter: (h) => h.matchedIn == MatchField.attachment,
            onHitTap: (h, q) => tapped = h,
            accessory: const Text('1 de 3'),
            body: const Center(child: Text('CONTENIDO')),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'velo');
      await tester.pump(searchDebounce);
      await tester.pump();
      expect(find.text('CONTENIDO'), findsOneWidget);
      expect(find.text('1 de 3'), findsOneWidget);
      expect(find.text('Texto'), findsNothing);
      expect(find.text('Adjunto'), findsOneWidget);
      expect(find.text('Coincidencias en adjuntos · 1'), findsOneWidget);
      await tester.tap(find.text('Adjunto'));
      expect(tapped?.title, 'Adjunto');
    });
  });
}
