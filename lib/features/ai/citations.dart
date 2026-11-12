/// Análisis de referencias numeradas `[n]` en textos generados por la IA (docs/CONTRATOS.md §3–4).
///
/// Reconoce `[1]`, `[12]` y listas `[1, 2]` / `[1; 2]`. No trata como cita un enlace Markdown
/// (`[1](url)`), una definición de referencia (`[1]: …`) ni el texto dentro de código.
library;

/// Esquema de los enlaces internos que apuntan a una cita (`cite:3`).
const citationScheme = 'cite';

final _refPattern = RegExp(r'\[(\d{1,3}(?:\s*[,;]\s*\d{1,3})*)\](?!\()');

/// true si la coincidencia es una definición de referencia Markdown (`[1]: https://…` a inicio
/// de línea), que no es una cita.
bool _isReferenceDefinition(String text, Match m) {
  if (m.end >= text.length || text[m.end] != ':') return false;
  final lineStart = m.start == 0 ? 0 : text.lastIndexOf('\n', m.start - 1) + 1;
  return text.substring(lineStart, m.start).trim().isEmpty;
}

/// Trozo de un texto con citas: texto literal o referencia a una o varias citas.
sealed class CitedSegment {
  const CitedSegment();
}

final class PlainSegment extends CitedSegment {
  const PlainSegment(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is PlainSegment && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'PlainSegment($text)';
}

final class CitationSegment extends CitedSegment {
  const CitationSegment(this.numbers, this.raw);

  /// Números citados, en el orden en que aparecen (sin duplicados).
  final List<int> numbers;

  /// Texto original (p. ej. «[1, 2]»).
  final String raw;

  @override
  bool operator ==(Object other) => other is CitationSegment && other.raw == raw && _listEq(other.numbers, numbers);
  @override
  int get hashCode => Object.hash(raw, Object.hashAll(numbers));
  @override
  String toString() => 'CitationSegment($numbers)';
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _numbersOf(String inner) {
  final out = <int>[];
  for (final part in inner.split(RegExp(r'[,;]'))) {
    final n = int.tryParse(part.trim());
    if (n != null && n > 0 && !out.contains(n)) out.add(n);
  }
  return out;
}

/// Divide un texto plano en trozos de texto y referencias. Si se indica `known`, las referencias
/// cuyos números no estén en el conjunto se dejan como texto literal.
List<CitedSegment> splitCitations(String text, {Set<int>? known}) {
  final out = <CitedSegment>[];
  var last = 0;
  for (final m in _refPattern.allMatches(text)) {
    if (_isReferenceDefinition(text, m)) continue;
    var numbers = _numbersOf(m.group(1)!);
    if (known != null) numbers = numbers.where(known.contains).toList();
    if (numbers.isEmpty) continue;
    if (m.start > last) out.add(PlainSegment(text.substring(last, m.start)));
    out.add(CitationSegment(numbers, m.group(0)!));
    last = m.end;
  }
  if (last < text.length) out.add(PlainSegment(text.substring(last)));
  // Une trozos de texto contiguos (cuando se descartaron referencias desconocidas).
  final merged = <CitedSegment>[];
  for (final s in out) {
    if (s is PlainSegment && merged.isNotEmpty && merged.last is PlainSegment) {
      merged[merged.length - 1] = PlainSegment((merged.last as PlainSegment).text + s.text);
    } else {
      merged.add(s);
    }
  }
  return merged;
}

/// Números citados en el texto, en orden de primera aparición.
List<int> citedNumbers(String text) {
  final out = <int>[];
  for (final s in splitCitations(text)) {
    if (s is CitationSegment) {
      for (final n in s.numbers) {
        if (!out.contains(n)) out.add(n);
      }
    }
  }
  return out;
}

/// Convierte las referencias `[n]` de un texto Markdown en enlaces `cite:n` para que se puedan
/// tocar. Respeta los bloques de código (``` y ~~~) y el código en línea. Si se indica `known`,
/// solo enlaza los números conocidos.
String linkCitationsInMarkdown(String markdown, {Set<int>? known}) {
  final lines = markdown.split('\n');
  final out = StringBuffer();
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (fence != null) {
      out.write(line);
      if (trimmed.startsWith(fence)) fence = null;
    } else if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      fence = trimmed.substring(0, 3);
      out.write(line);
    } else {
      out.write(_linkLine(line, known));
    }
    if (i < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

String _linkLine(String line, Set<int>? known) {
  // Alterna fuera/dentro de código en línea delimitado por comillas invertidas.
  final parts = line.split('`');
  if (parts.length.isEven) {
    // Comilla sin cerrar: no hay código en línea real.
    return _linkPlain(line, known);
  }
  final b = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) b.write('`');
    b.write(i.isEven ? _linkPlain(parts[i], known) : parts[i]);
  }
  return b.toString();
}

String _linkPlain(String text, Set<int>? known) {
  final b = StringBuffer();
  for (final s in splitCitations(text, known: known)) {
    switch (s) {
      case PlainSegment(:final text):
        b.write(text);
      case CitationSegment(:final numbers):
        for (final n in numbers) {
          b.write('[\\[$n\\]]($citationScheme:$n)');
        }
    }
  }
  return b.toString();
}

/// Número de cita a partir del destino de un enlace (`cite:3` → 3).
int? citationFromHref(String? href) {
  if (href == null || !href.startsWith('$citationScheme:')) return null;
  return int.tryParse(href.substring(citationScheme.length + 1));
}

/// Quita las referencias `[n]` (útil para títulos o lectura en voz alta).
String stripCitations(String text) {
  final b = StringBuffer();
  for (final s in splitCitations(text)) {
    if (s is PlainSegment) b.write(s.text);
  }
  return b
      .toString()
      .replaceAllMapped(RegExp(r'[ \t]+([.,;:!?])'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ');
}
