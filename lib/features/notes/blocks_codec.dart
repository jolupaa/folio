import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show Embeddable;
import 'package:flutter_quill/quill_delta.dart';
import 'package:uuid/uuid.dart';

/// Conversión entre el cuerpo de nota en bloques (docs/CONTRATOS.md §1) y el documento Delta
/// de flutter_quill.
///
/// Reglas:
/// - Cada bloque de texto es una línea Quill; su tipo se expresa con atributos de línea
///   (`header` 1-3, `list` bullet/ordered/checked/unchecked + `indent`, `blockquote`).
/// - Los saltos suaves (`\n` dentro de `text`) se representan con U+2028 (LINE SEPARATOR), que
///   Flutter dibuja como salto de línea sin partir el bloque. Ocupa 1 unidad UTF-16, igual que `\n`.
/// - Adjuntos, divisor, enlaces a pizarra y tipos desconocidos son embeds de bloque propios cuyo
///   dato es el JSON completo del bloque (conserva id y campos adicionales).
/// - Sin formato en línea: los atributos en línea se ignoran.
/// - El documento siempre termina con una línea vacía extra (para poder escribir tras un adjunto);
///   al decodificar se descarta la última línea si es un párrafo vacío.
/// - Al decodificar, los ids (y `source_page_id` y campos extra) se conservan alineando las líneas
///   con los bloques anteriores: primero por tipo+texto idénticos (subsecuencia común más larga) y,
///   entre anclas, por posición. Las líneas nuevas reciben UUID v4.

/// Tipos de bloque del contrato.
enum BlockType {
  heading1('heading1'),
  heading2('heading2'),
  heading3('heading3'),
  paragraph('paragraph'),
  bullet('bullet'),
  numbered('numbered'),
  todo('todo'),
  quote('quote'),
  divider('divider'),
  image('image'),
  pdf('pdf'),
  boardLink('board_link'),

  /// Tipo futuro no reconocido: se conserva tal cual.
  unknown('');

  const BlockType(this.wire);
  final String wire;

  static BlockType fromWire(String? wire) {
    for (final t in values) {
      if (t != unknown && t.wire == wire) return t;
    }
    return unknown;
  }

  bool get hasText => switch (this) {
    heading1 || heading2 || heading3 || paragraph || bullet || numbered || todo || quote => true,
    _ => false,
  };

  bool get isList => this == bullet || this == numbered || this == todo;

  bool get isHeading => this == heading1 || this == heading2 || this == heading3;
}

/// Claves que gestiona la UI; el resto se conserva en [NoteBlock.extra].
const _knownKeys = {'id', 'type', 'text', 'indent', 'checked', 'attachment_id', 'note_id', 'source_page_id'};

/// Bloque del cuerpo de una nota.
@immutable
class NoteBlock {
  const NoteBlock({
    required this.id,
    required this.type,
    this.text = '',
    this.indent = 0,
    this.checked = false,
    this.attachmentId,
    this.noteId,
    this.sourcePageId,
    this.extra = const {},
    this.raw,
  });

  final String id;
  final BlockType type;
  final String text;

  /// 0..3, solo listas.
  final int indent;

  /// Solo `todo`.
  final bool checked;

  /// `image` / `pdf`.
  final String? attachmentId;

  /// `board_link`: id de la pizarra.
  final String? noteId;

  /// Página de adjunto de origen (OCR).
  final String? sourcePageId;

  /// Campos no gestionados por la UI (compatibilidad futura): se reescriben tal cual.
  final Map<String, Object?> extra;

  /// JSON original completo de un bloque de tipo desconocido.
  final Map<String, Object?>? raw;

  factory NoteBlock.fromJson(Map<String, Object?> json) {
    final type = BlockType.fromWire(json['type'] as String?);
    final id = (json['id'] as String?) ?? '';
    if (type == BlockType.unknown) {
      return NoteBlock(id: id, type: type, raw: Map<String, Object?>.of(json));
    }
    final extra = <String, Object?>{
      for (final e in json.entries)
        if (!_knownKeys.contains(e.key)) e.key: e.value,
    };
    final rawIndent = json['indent'];
    return NoteBlock(
      id: id,
      type: type,
      text: (json['text'] as String?) ?? '',
      indent: rawIndent is num ? rawIndent.toInt().clamp(0, 3) : 0,
      checked: json['checked'] == true,
      attachmentId: json['attachment_id'] as String?,
      noteId: json['note_id'] as String?,
      sourcePageId: json['source_page_id'] as String?,
      extra: extra,
    );
  }

  /// JSON del contrato: los campos opcionales se omiten cuando valen su valor por defecto.
  Map<String, Object?> toJson() {
    if (type == BlockType.unknown) {
      return {...?raw, 'id': id};
    }
    return {
      'id': id,
      'type': type.wire,
      if (type.hasText && text.isNotEmpty) 'text': text,
      if (type.isList && indent > 0) 'indent': indent.clamp(0, 3),
      if (type == BlockType.todo && checked) 'checked': true,
      if ((type == BlockType.image || type == BlockType.pdf) && attachmentId != null)
        'attachment_id': attachmentId,
      if (type == BlockType.boardLink && noteId != null) 'note_id': noteId,
      if (sourcePageId != null) 'source_page_id': sourcePageId,
      ...extra,
    };
  }

  NoteBlock copyWith({
    String? id,
    BlockType? type,
    String? text,
    int? indent,
    bool? checked,
    String? sourcePageId,
    Map<String, Object?>? extra,
  }) => NoteBlock(
    id: id ?? this.id,
    type: type ?? this.type,
    text: text ?? this.text,
    indent: indent ?? this.indent,
    checked: checked ?? this.checked,
    attachmentId: attachmentId,
    noteId: noteId,
    sourcePageId: sourcePageId ?? this.sourcePageId,
    extra: extra ?? this.extra,
    raw: raw,
  );

  @override
  bool operator ==(Object other) => other is NoteBlock && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'NoteBlock(${jsonEncode(toJson())})';
}

/// Tipos de embed de Quill usados por Folio (dato = JSON del bloque).
abstract final class FolioEmbeds {
  static const image = 'folio_image';
  static const pdf = 'folio_pdf';
  static const board = 'folio_board';
  static const divider = 'folio_divider';
  static const unknown = 'folio_unknown';

  static const all = {image, pdf, board, divider, unknown};

  static String typeFor(BlockType t) => switch (t) {
    BlockType.image => image,
    BlockType.pdf => pdf,
    BlockType.boardLink => board,
    BlockType.divider => divider,
    _ => unknown,
  };

  /// Dato del embed para un bloque.
  static String dataFor(NoteBlock b) => jsonEncode(b.toJson());

  /// Bloque representado por el dato de un embed (o null si no es válido).
  static NoteBlock? blockFrom(String type, Object? data) {
    if (!all.contains(type)) return null;
    Object? decoded = data;
    if (data is String) {
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    final block = NoteBlock.fromJson(Map<String, Object?>.from(decoded));
    return block;
  }
}

/// Separador de saltos suaves dentro de un bloque.
const softBreak = '\u2028';

/// Error de formato del cuerpo de la nota (no se debe sobrescribir el contenido).
class BlocksFormatException implements Exception {
  BlocksFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parsea el JSON de bloques. Acepta "" como lista vacía.
List<NoteBlock> parseBlocks(String bodyJson) {
  if (bodyJson.trim().isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(bodyJson);
  } on FormatException catch (e) {
    throw BlocksFormatException('Cuerpo de nota no válido: ${e.message}');
  }
  if (decoded is! List) throw BlocksFormatException('Cuerpo de nota no válido: se esperaba una lista');
  final out = <NoteBlock>[];
  final seen = <String>{};
  for (final item in decoded) {
    if (item is! Map) throw BlocksFormatException('Cuerpo de nota no válido: bloque mal formado');
    var block = NoteBlock.fromJson(Map<String, Object?>.from(item));
    if (block.id.isEmpty || !seen.add(block.id)) {
      // Ids ausentes o duplicados: se regeneran para cumplir el contrato al guardar.
      block = block.copyWith(id: newBlockId());
      seen.add(block.id);
    }
    out.add(block);
  }
  return out;
}

String encodeBlocks(List<NoteBlock> blocks) => jsonEncode([for (final b in blocks) b.toJson()]);

const _uuid = Uuid();
String newBlockId() => _uuid.v4();

// ─────────────────────────── Bloques → Delta ───────────────────────────

Map<String, Object?>? _lineAttributes(NoteBlock b) {
  final indent = b.indent.clamp(0, 3);
  return switch (b.type) {
    BlockType.heading1 => {'header': 1},
    BlockType.heading2 => {'header': 2},
    BlockType.heading3 => {'header': 3},
    BlockType.bullet => {'list': 'bullet', if (indent > 0) 'indent': indent},
    BlockType.numbered => {'list': 'ordered', if (indent > 0) 'indent': indent},
    BlockType.todo => {'list': b.checked ? 'checked' : 'unchecked', if (indent > 0) 'indent': indent},
    BlockType.quote => {'blockquote': true},
    _ => null,
  };
}

String _toEditorText(String text) =>
    text.replaceAll('\r\n', softBreak).replaceAll('\n', softBreak).replaceAll('\r', softBreak);

/// Documento Delta para unos bloques. Siempre termina con una línea vacía adicional.
Delta blocksToDelta(List<NoteBlock> blocks) {
  final delta = Delta();
  for (final b in blocks) {
    if (b.type.hasText) {
      final text = _toEditorText(b.text);
      if (text.isNotEmpty) delta.insert(text);
      delta.insert('\n', _lineAttributes(b));
    } else {
      delta.insert({FolioEmbeds.typeFor(b.type): FolioEmbeds.dataFor(b)});
      delta.insert('\n');
    }
  }
  delta.insert('\n');
  return delta;
}

// ─────────────────────────── Delta → bloques ───────────────────────────

/// Línea decodificada: texto con su tipo, o un bloque embebido.
class _Line {
  _Line.text(this.type, this.text, this.indent, this.checked) : embed = null;
  _Line.embed(NoteBlock this.embed) : type = embed.type, text = '', indent = 0, checked = false;

  final BlockType type;
  final String text;
  final int indent;
  final bool checked;
  final NoteBlock? embed;

  bool get isEmbed => embed != null;

  String get key => isEmbed ? 'e\u0000${embed!.id}' : 't\u0000${type.wire}\u0000$text';
}

int _intAttr(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

_Line _textLine(String text, Map<String, dynamic>? attrs) {
  final t = text.replaceAll(softBreak, '\n');
  final list = attrs?['list'];
  if (list is String) {
    final indent = _intAttr(attrs?['indent']).clamp(0, 3);
    return switch (list) {
      'ordered' => _Line.text(BlockType.numbered, t, indent, false),
      'checked' => _Line.text(BlockType.todo, t, indent, true),
      'unchecked' => _Line.text(BlockType.todo, t, indent, false),
      _ => _Line.text(BlockType.bullet, t, indent, false),
    };
  }
  final header = attrs?['header'];
  if (header != null) {
    final level = _intAttr(header);
    if (level >= 1) {
      return _Line.text(
        switch (level) {
          1 => BlockType.heading1,
          2 => BlockType.heading2,
          _ => BlockType.heading3,
        },
        t,
        0,
        false,
      );
    }
  }
  if (attrs?['blockquote'] == true) return _Line.text(BlockType.quote, t, 0, false);
  return _Line.text(BlockType.paragraph, t, 0, false);
}

NoteBlock? _embedBlock(Object? data) {
  String? type;
  Object? payload;
  if (data is Embeddable) {
    type = data.type;
    payload = data.data;
  } else if (data is Map && data.length == 1) {
    type = data.keys.first as String?;
    payload = data.values.first;
  }
  if (type == null) return null;
  return FolioEmbeds.blockFrom(type, payload);
}

List<_Line> _decodeLines(Delta delta) {
  final lines = <_Line>[];
  // Elementos de la línea en curso: String (texto) o NoteBlock (embed).
  final items = <Object>[];
  final buffer = StringBuffer();
  // La línea contenía solo embeds ajenos a Folio (se descartan sin dejar una línea vacía).
  var droppedEmbed = false;

  void flushText() {
    if (buffer.isNotEmpty) {
      items.add(buffer.toString());
      buffer.clear();
    }
  }

  void endLine(Map<String, dynamic>? attrs) {
    flushText();
    if (items.isEmpty) {
      if (!droppedEmbed) lines.add(_textLine('', attrs));
    } else {
      for (final item in items) {
        if (item is String) {
          lines.add(_textLine(item, attrs));
        } else {
          lines.add(_Line.embed(item as NoteBlock));
        }
      }
    }
    items.clear();
    droppedEmbed = false;
  }

  for (final op in delta.toList()) {
    if (!op.isInsert) continue;
    final data = op.data;
    if (data is String) {
      final parts = data.split('\n');
      for (var i = 0; i < parts.length; i++) {
        // Los embeds en línea de otros orígenes (U+FFFC) no aportan texto.
        buffer.write(parts[i].replaceAll('\uFFFC', ''));
        if (i < parts.length - 1) endLine(op.attributes);
      }
    } else {
      final block = _embedBlock(data);
      if (block != null) {
        flushText();
        items.add(block);
      } else {
        droppedEmbed = true;
      }
    }
  }
  flushText();
  if (items.isNotEmpty) endLine(null);

  // Línea final vacía de cortesía.
  if (lines.isNotEmpty) {
    final last = lines.last;
    if (!last.isEmbed && last.type == BlockType.paragraph && last.text.isEmpty) lines.removeLast();
  }
  return lines;
}

/// Pares (índice nuevo → índice anterior) alineados por clave idéntica (subsecuencia común más larga).
Map<int, int> _alignByKey(List<String> prev, List<String> next) {
  final result = <int, int>{};
  var start = 0;
  while (start < prev.length && start < next.length && prev[start] == next[start]) {
    result[start] = start;
    start++;
  }
  var endPrev = prev.length;
  var endNext = next.length;
  while (endPrev > start && endNext > start && prev[endPrev - 1] == next[endNext - 1]) {
    endPrev--;
    endNext--;
    result[endNext] = endPrev;
  }
  final n = endPrev - start;
  final m = endNext - start;
  if (n == 0 || m == 0) return result;
  // Límite de memoria/tiempo: documentos enormes reescritos casi por completo → solo posición.
  if (n * m > 4000000) return result;
  final w = m + 1;
  final dp = Int32List((n + 1) * w);
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i * w + j] = prev[start + i] == next[start + j]
          ? dp[(i + 1) * w + j + 1] + 1
          : (dp[(i + 1) * w + j] >= dp[i * w + j + 1] ? dp[(i + 1) * w + j] : dp[i * w + j + 1]);
    }
  }
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (prev[start + i] == next[start + j]) {
      result[start + j] = start + i;
      i++;
      j++;
    } else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return result;
}

/// Convierte el documento Delta del editor en bloques, conservando ids de [previous].
List<NoteBlock> deltaToBlocks(
  Delta delta, {
  List<NoteBlock> previous = const [],
  String Function()? generateId,
}) {
  final makeId = generateId ?? newBlockId;
  final lines = _decodeLines(delta);
  final prevKeys = [
    for (final b in previous) b.type.hasText ? 't\u0000${b.type.wire}\u0000${b.text}' : 'e\u0000${b.id}',
  ];
  final nextKeys = [for (final l in lines) l.key];
  final matched = _alignByKey(prevKeys, nextKeys);

  // Asignación: índice de línea → bloque anterior del que hereda id/source_page_id/extra.
  final inherit = <int, NoteBlock>{...matched.map((ni, pi) => MapEntry(ni, previous[pi]))};
  final consumed = <int>{...matched.values};

  // Bloques movidos (cortar/pegar una línea): mismo tipo+texto fuera de la alineación.
  final leftovers = <String, List<int>>{};
  for (var k = 0; k < previous.length; k++) {
    if (!consumed.contains(k) && previous[k].type.hasText) (leftovers[prevKeys[k]] ??= []).add(k);
  }
  for (var k = 0; k < lines.length; k++) {
    if (lines[k].isEmbed || inherit.containsKey(k)) continue;
    final candidates = leftovers[nextKeys[k]];
    if (candidates == null || candidates.isEmpty) continue;
    final pi = candidates.removeAt(0);
    inherit[k] = previous[pi];
    consumed.add(pi);
  }

  // Entre anclas consecutivas, empareja por posición las líneas de texto restantes (ediciones).
  final anchors = matched.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  var gapNext = 0; // primer índice nuevo del hueco
  var gapPrev = 0; // primer índice anterior del hueco
  void pairGap(int nextEnd, int prevEnd) {
    final newText = [
      for (var k = gapNext; k < nextEnd; k++)
        if (!lines[k].isEmbed && !inherit.containsKey(k)) k,
    ];
    final oldText = [
      for (var k = gapPrev; k < prevEnd; k++)
        if (previous[k].type.hasText && !consumed.contains(k)) k,
    ];
    final count = newText.length < oldText.length ? newText.length : oldText.length;
    for (var t = 0; t < count; t++) {
      inherit[newText[t]] = previous[oldText[t]];
      consumed.add(oldText[t]);
    }
  }

  for (final a in anchors) {
    pairGap(a.key, a.value);
    gapNext = a.key + 1;
    gapPrev = a.value + 1;
  }
  pairGap(lines.length, previous.length);

  // Ids reservados por herencia (tienen prioridad frente a duplicados copiados/pegados).
  final used = <String>{};
  final ids = List<String?>.filled(lines.length, null);
  for (final e in inherit.entries) {
    if (used.add(e.value.id)) ids[e.key] = e.value.id;
  }
  final out = <NoteBlock>[];
  for (var k = 0; k < lines.length; k++) {
    final line = lines[k];
    final from = inherit[k];
    var id = ids[k];
    if (id == null) {
      final own = line.embed?.id;
      if (own != null && own.isNotEmpty && !used.contains(own)) {
        id = own;
      } else {
        do {
          id = makeId();
        } while (used.contains(id));
      }
      used.add(id);
    }
    if (line.isEmbed) {
      out.add(line.embed!.copyWith(id: id));
    } else {
      out.add(
        NoteBlock(
          id: id,
          type: line.type,
          text: line.text,
          indent: line.type.isList ? line.indent : 0,
          checked: line.type == BlockType.todo && line.checked,
          sourcePageId: from?.sourcePageId,
          extra: from?.extra ?? const {},
        ),
      );
    }
  }
  return out;
}

// ─────────────────────────── Utilidades ───────────────────────────

/// Rango de documento (offset y longitud del contenido, sin el salto final) de cada bloque, en el
/// documento producido por [blocksToDelta].
List<({int start, int length})> blockRanges(List<NoteBlock> blocks) {
  final out = <({int start, int length})>[];
  var offset = 0;
  for (final b in blocks) {
    final len = b.type.hasText ? _toEditorText(b.text).length : 1;
    out.add((start: offset, length: len));
    offset += len + 1;
  }
  return out;
}
