import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Marcadores de coincidencia de los fragmentos de búsqueda (docs/CONTRATOS.md §5).
const matchStart = '\uE000';
const matchEnd = '\uE001';

/// Trozo de un fragmento: texto y si es coincidencia.
typedef HighlightPart = ({String text, bool match});

/// Divide un fragmento marcado con U+E000 … U+E001 en partes. Tolera marcadores desparejados
/// (un inicio sin fin resalta hasta el final; un fin sin inicio se ignora).
List<HighlightPart> parseHighlights(String snippet) {
  final parts = <HighlightPart>[];
  final buf = StringBuffer();
  var inMatch = false;
  void flush() {
    if (buf.isEmpty) return;
    final text = buf.toString();
    buf.clear();
    if (parts.isNotEmpty && parts.last.match == inMatch) {
      parts[parts.length - 1] = (text: parts.last.text + text, match: inMatch);
    } else {
      parts.add((text: text, match: inMatch));
    }
  }

  for (final rune in snippet.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == matchStart) {
      flush();
      inMatch = true;
    } else if (ch == matchEnd) {
      flush();
      inMatch = false;
    } else {
      buf.write(ch);
    }
  }
  flush();
  return parts;
}

/// Texto sin marcadores (para semántica/accesibilidad).
String stripHighlights(String snippet) => snippet.replaceAll(matchStart, '').replaceAll(matchEnd, '');

/// Texto con coincidencias resaltadas (fondo `highlight`, texto principal).
class HighlightedText extends StatelessWidget {
  const HighlightedText(this.snippet, {super.key, this.style, this.maxLines, this.overflow = TextOverflow.ellipsis});

  final String snippet;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = style ?? DefaultTextStyle.of(context).style;
    final matchStyle = base.copyWith(backgroundColor: c.highlight, color: c.textPrimary);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (final p in parseHighlights(snippet)) TextSpan(text: p.text, style: p.match ? matchStyle : null),
        ],
      ),
      maxLines: maxLines,
      overflow: overflow,
      semanticsLabel: stripHighlights(snippet),
    );
  }
}
