import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/search.dart' as rs;
import '../../src/rust/api/types.dart';

/// Búsqueda textual (FTS5) en un ámbito. Inyectable para pruebas.
typedef SearchFunction = Future<SearchResults> Function(String query, SearchScope scope, int limit);

/// Coincidencias de `query` en `text` (offsets UTF-16). Inyectable para pruebas.
typedef FindInTextFunction = List<TextMatch> Function(String text, String query);

final searchFunctionProvider = Provider<SearchFunction>(
  (ref) => (query, scope, limit) => rs.search(query: query, scope: scope, limit: limit),
);

final findInTextProvider = Provider<FindInTextFunction>(
  (ref) => (text, query) => rs.findInText(text: text, query: query),
);
