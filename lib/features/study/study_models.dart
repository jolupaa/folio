/// Modelos Dart del contenido de los materiales de estudio (`study_items.content`) y de los
/// intentos de cuestionario (`quiz_attempts.answers`), según docs/CONTRATOS.md §3–4.
///
/// La lectura es tolerante: campos ausentes o con tipo inesperado toman valores por defecto y
/// las claves desconocidas se conservan en `extra` para no perderlas al guardar una edición.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../src/rust/api/types.dart';

// ─────────────────────────── Utilidades de lectura tolerante ───────────────────────────

Map<String, dynamic> _asMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, v) => MapEntry('$k', v));
  return <String, dynamic>{};
}

List<Object?> _asList(Object? v) => v is List ? v : const [];

String _str(Object? v, [String fallback = '']) {
  if (v is String) return v;
  if (v == null) return fallback;
  if (v is num || v is bool) return '$v';
  return fallback;
}

String? _strOrNull(Object? v) => v is String ? v : (v is num ? '$v' : null);

int? _int(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _double(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
  return null;
}

bool? _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == 'sí' || s == 'si' || s == '1') return true;
    if (s == 'false' || s == 'no' || s == '0') return false;
  }
  return null;
}

List<int> _intList(Object? v) {
  final out = <int>[];
  for (final e in _asList(v)) {
    final n = _int(e);
    if (n != null && !out.contains(n)) out.add(n);
  }
  return out;
}

Map<String, dynamic> _extra(Map<String, dynamic> json, Set<String> known) => {
  for (final e in json.entries)
    if (!known.contains(e.key)) e.key: e.value,
};

String _newId(String prefix) => '$prefix${const Uuid().v4().replaceAll('-', '').substring(0, 10)}';

/// Igualdad estructural basada en la serialización JSON (los datos son JSON por naturaleza).
mixin _JsonEquality {
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other.runtimeType == runtimeType && jsonEncode((other as _JsonEquality).toJson()) == jsonEncode(toJson()));

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

// ─────────────────────────── Citas ───────────────────────────

/// Lee una cita en JSON (claves snake_case, docs/CONTRATOS.md §4).
Citation citationFromJson(Object? raw) {
  final j = _asMap(raw);
  return Citation(
    n: _int(j['n']) ?? 0,
    noteId: _str(j['note_id']),
    noteTitle: _str(j['note_title']),
    location: [for (final e in _asList(j['location'])) _str(e)],
    chunkId: _int(j['chunk_id']) ?? 0,
    blockId: _strOrNull(j['block_id']),
    pageId: _strOrNull(j['page_id']),
    attachmentName: _strOrNull(j['attachment_name']),
    pageIndex: _int(j['page_index']),
    snippet: _str(j['snippet']),
    exists: _bool(j['exists']) ?? true,
  );
}

Map<String, dynamic> citationToJson(Citation c) => {
  'n': c.n,
  'note_id': c.noteId,
  'note_title': c.noteTitle,
  'location': c.location,
  'chunk_id': c.chunkId,
  'block_id': c.blockId,
  'page_id': c.pageId,
  'attachment_name': c.attachmentName,
  'page_index': c.pageIndex,
  'snippet': c.snippet,
  'exists': c.exists,
};

List<Citation> _citations(Object? v) => [
  for (final e in _asList(v))
    if (e is Map) citationFromJson(e),
];

/// Busca la cita `n` en una lista.
Citation? findCitation(List<Citation> citations, int n) {
  for (final c in citations) {
    if (c.n == n) return c;
  }
  return null;
}

// ─────────────────────────── Contenido ───────────────────────────

/// Contenido de un material de estudio. Use [StudyContent.parse] para leerlo según el tipo.
sealed class StudyContent with _JsonEquality {
  StudyContent({required this.citations, Map<String, dynamic>? extra}) : extra = extra ?? {};

  /// Todas las citas del material (n únicos).
  final List<Citation> citations;

  /// Claves desconocidas, conservadas tal cual.
  final Map<String, dynamic> extra;

  /// Lee el JSON de `StudyItem.contentJson`. Nunca lanza: un JSON inválido produce contenido vacío.
  static StudyContent parse(StudyKind kind, String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      decoded = null;
    }
    final map = _asMap(decoded);
    return switch (kind) {
      StudyKind.summary || StudyKind.outline || StudyKind.keyConcepts => TextContent.fromJson(map),
      StudyKind.flashcards => FlashcardsContent.fromJson(map),
      StudyKind.quiz => QuizContent.fromJson(map),
    };
  }

  String encode() => jsonEncode(toJson());

  Citation? citation(int n) => findCitation(citations, n);

  Set<int> get citationNumbers => {for (final c in citations) c.n};
}

/// Resumen, esquema o conceptos clave (Markdown con referencias [n]).
final class TextContent extends StudyContent {
  TextContent({this.format = 'markdown', required this.text, this.detail, super.citations = const [], super.extra});

  factory TextContent.fromJson(Map<String, dynamic> j) => TextContent(
    format: _str(j['format'], 'markdown'),
    text: _str(j['text']),
    detail: _strOrNull(j['detail']),
    citations: _citations(j['citations']),
    extra: _extra(j, const {'format', 'text', 'detail', 'citations'}),
  );

  final String format;
  final String text;

  /// «brief» | «detailed» (solo resúmenes).
  final String? detail;

  TextContent copyWith({String? text}) =>
      TextContent(format: format, text: text ?? this.text, detail: detail, citations: citations, extra: extra);

  @override
  Map<String, dynamic> toJson() => {
    ...extra,
    'format': format,
    'text': text,
    'detail': ?detail,
    'citations': [for (final c in citations) citationToJson(c)],
  };
}

final class Flashcard with _JsonEquality {
  Flashcard({
    required this.id,
    required this.front,
    required this.back,
    this.citations = const [],
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  /// Tarjeta nueva (creada a mano) con id único.
  factory Flashcard.create({String front = '', String back = ''}) =>
      Flashcard(id: _newId('c'), front: front, back: back);

  factory Flashcard.fromJson(Map<String, dynamic> j, int index) => Flashcard(
    id: _str(j['id']).isEmpty ? 'c${index + 1}' : _str(j['id']),
    front: _str(j['front']),
    back: _str(j['back']),
    citations: _intList(j['citations']),
    extra: _extra(j, const {'id', 'front', 'back', 'citations'}),
  );

  final String id;
  final String front;
  final String back;

  /// Números de cita referenciados por la tarjeta.
  final List<int> citations;
  final Map<String, dynamic> extra;

  Flashcard copyWith({String? front, String? back}) =>
      Flashcard(id: id, front: front ?? this.front, back: back ?? this.back, citations: citations, extra: extra);

  @override
  Map<String, dynamic> toJson() => {...extra, 'id': id, 'front': front, 'back': back, 'citations': citations};
}

final class FlashcardsContent extends StudyContent {
  FlashcardsContent({required this.cards, super.citations = const [], super.extra});

  factory FlashcardsContent.fromJson(Map<String, dynamic> j) {
    final raw = _asList(j['cards']);
    return FlashcardsContent(
      cards: [
        for (var i = 0; i < raw.length; i++)
          if (raw[i] is Map) Flashcard.fromJson(_asMap(raw[i]), i),
      ],
      citations: _citations(j['citations']),
      extra: _extra(j, const {'cards', 'citations'}),
    );
  }

  final List<Flashcard> cards;

  FlashcardsContent copyWith({List<Flashcard>? cards}) =>
      FlashcardsContent(cards: cards ?? this.cards, citations: citations, extra: extra);

  @override
  Map<String, dynamic> toJson() => {
    ...extra,
    'cards': [for (final c in cards) c.toJson()],
    'citations': [for (final c in citations) citationToJson(c)],
  };
}

enum QuestionKind {
  /// Opción múltiple.
  mcq,

  /// Respuesta abierta.
  open,
}

final class QuizQuestion with _JsonEquality {
  QuizQuestion({
    required this.id,
    required this.kind,
    required this.question,
    this.options = const [],
    this.answerIndex,
    this.referenceAnswer,
    this.explanation = '',
    this.citations = const [],
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  factory QuizQuestion.create(QuestionKind kind) => QuizQuestion(
    id: _newId('q'),
    kind: kind,
    question: '',
    options: kind == QuestionKind.mcq ? const ['', ''] : const [],
    answerIndex: kind == QuestionKind.mcq ? 0 : null,
    referenceAnswer: kind == QuestionKind.open ? '' : null,
  );

  factory QuizQuestion.fromJson(Map<String, dynamic> j, int index) {
    final options = [for (final o in _asList(j['options'])) _str(o)];
    final kind = switch (_str(j['kind'])) {
      'mcq' => QuestionKind.mcq,
      'open' => QuestionKind.open,
      _ => options.length >= 2 ? QuestionKind.mcq : QuestionKind.open,
    };
    var answer = _int(j['answer_index']);
    if (answer != null && (answer < 0 || answer >= options.length)) answer = null;
    return QuizQuestion(
      id: _str(j['id']).isEmpty ? 'q${index + 1}' : _str(j['id']),
      kind: kind,
      question: _str(j['question']),
      options: options,
      answerIndex: answer,
      referenceAnswer: _strOrNull(j['reference_answer']),
      explanation: _str(j['explanation']),
      citations: _intList(j['citations']),
      extra: _extra(j, const {
        'id',
        'kind',
        'question',
        'options',
        'answer_index',
        'reference_answer',
        'explanation',
        'citations',
      }),
    );
  }

  final String id;
  final QuestionKind kind;
  final String question;
  final List<String> options;

  /// Índice de la opción correcta (opción múltiple).
  final int? answerIndex;

  /// Respuesta de referencia (respuesta abierta).
  final String? referenceAnswer;
  final String explanation;
  final List<int> citations;
  final Map<String, dynamic> extra;

  bool get isMcq => kind == QuestionKind.mcq;

  /// Una pregunta de opción múltiple sin respuesta correcta válida no se puede corregir.
  bool get isGradable => !isMcq || (answerIndex != null && answerIndex! < options.length);

  QuizQuestion copyWith({
    QuestionKind? kind,
    String? question,
    List<String>? options,
    int? answerIndex,
    bool clearAnswerIndex = false,
    String? referenceAnswer,
    String? explanation,
  }) => QuizQuestion(
    id: id,
    kind: kind ?? this.kind,
    question: question ?? this.question,
    options: options ?? this.options,
    answerIndex: clearAnswerIndex ? null : (answerIndex ?? this.answerIndex),
    referenceAnswer: referenceAnswer ?? this.referenceAnswer,
    explanation: explanation ?? this.explanation,
    citations: citations,
    extra: extra,
  );

  @override
  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'kind': kind.name,
    'question': question,
    if (kind == QuestionKind.mcq) 'options': options,
    if (kind == QuestionKind.mcq) 'answer_index': ?answerIndex,
    if (kind == QuestionKind.open) 'reference_answer': ?referenceAnswer,
    'explanation': explanation,
    'citations': citations,
  };
}

final class QuizContent extends StudyContent {
  QuizContent({required this.questions, super.citations = const [], super.extra});

  factory QuizContent.fromJson(Map<String, dynamic> j) {
    final raw = _asList(j['questions']);
    return QuizContent(
      questions: [
        for (var i = 0; i < raw.length; i++)
          if (raw[i] is Map) QuizQuestion.fromJson(_asMap(raw[i]), i),
      ],
      citations: _citations(j['citations']),
      extra: _extra(j, const {'questions', 'citations'}),
    );
  }

  final List<QuizQuestion> questions;

  QuizContent copyWith({List<QuizQuestion>? questions}) =>
      QuizContent(questions: questions ?? this.questions, citations: citations, extra: extra);

  QuizQuestion? question(String id) {
    for (final q in questions) {
      if (q.id == id) return q;
    }
    return null;
  }

  @override
  Map<String, dynamic> toJson() => {
    ...extra,
    'questions': [for (final q in questions) q.toJson()],
    'citations': [for (final c in citations) citationToJson(c)],
  };
}

// ─────────────────────────── Intentos de cuestionario ───────────────────────────

/// Respuesta a una pregunta dentro de un intento (`quiz_attempts.answers`).
final class QuizAnswer with _JsonEquality {
  QuizAnswer({
    required this.questionId,
    required this.response,
    this.correct,
    this.score,
    this.feedback,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  factory QuizAnswer.fromJson(Map<String, dynamic> j) => QuizAnswer(
    questionId: _str(j['question_id']),
    response: _str(j['response']),
    correct: _bool(j['correct']),
    score: _double(j['score']),
    feedback: _strOrNull(j['feedback']),
    extra: _extra(j, const {'question_id', 'response', 'correct', 'score', 'feedback'}),
  );

  final String questionId;

  /// Opción múltiple: índice elegido como texto («2»). Abierta: texto escrito.
  final String response;
  final bool? correct;

  /// 0..1.
  final double? score;
  final String? feedback;
  final Map<String, dynamic> extra;

  /// Puntuación efectiva (0..1): `score` o, si falta, 1/0 según `correct`.
  double get effectiveScore => (score ?? (correct == true ? 1.0 : 0.0)).clamp(0.0, 1.0);

  @override
  Map<String, dynamic> toJson() => {
    ...extra,
    'question_id': questionId,
    'response': response,
    'correct': ?correct,
    'score': ?score,
    'feedback': ?feedback,
  };
}

List<QuizAnswer> parseQuizAnswers(String json) {
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  return [
    for (final e in _asList(decoded))
      if (e is Map) QuizAnswer.fromJson(_asMap(e)),
  ];
}

String encodeQuizAnswers(List<QuizAnswer> answers) => jsonEncode([for (final a in answers) a.toJson()]);

/// Puntuación media (0..1) de un conjunto de respuestas sobre `total` preguntas.
double quizScore(Iterable<QuizAnswer> answers, int total) {
  if (total <= 0) return 0;
  var sum = 0.0;
  for (final a in answers) {
    sum += a.effectiveScore;
  }
  return (sum / total).clamp(0.0, 1.0);
}

// ─────────────────────────── Corrección de respuestas abiertas ───────────────────────────

/// Resultado de `grade_open_answer` (`Done.text` = `{"score":0..1,"correct":bool,"feedback":"…"}`).
final class GradeResult {
  const GradeResult({required this.score, required this.correct, required this.feedback});

  final double score;
  final bool correct;
  final String feedback;

  /// Interpreta la respuesta del corrector. Acepta el JSON rodeado de texto o de un bloque de
  /// código, puntuaciones en porcentaje (0..100) y la ausencia de `correct` (se deduce de `score`).
  static GradeResult? tryParse(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final j = _asMap(decoded);
    var score = _double(j['score']);
    final correct = _bool(j['correct']);
    if (score == null && correct == null) return null;
    if (score != null && score > 1 && score <= 100) score = score / 100;
    score = (score ?? (correct! ? 1.0 : 0.0)).clamp(0.0, 1.0);
    return GradeResult(score: score, correct: correct ?? score >= 0.5, feedback: _str(j['feedback']).trim());
  }
}

/// Extrae el comentario («feedback») de una corrección aún en streaming, para mostrarlo mientras
/// llega. Si la salida no es JSON, devuelve el texto tal cual.
String partialGradeFeedback(String streamed) {
  final t = streamed.trimLeft();
  if (!t.startsWith('{') && !t.startsWith('```')) return streamed.trim();
  final m = RegExp(r'"feedback"\s*:\s*"((?:[^"\\]|\\.)*)').firstMatch(t);
  if (m == null) return '';
  final raw = m.group(1)!;
  try {
    return jsonDecode('"$raw"') as String;
  } on FormatException {
    // Secuencia de escape incompleta al final del fragmento.
    return raw.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(RegExp(r'\\.?$'), '');
  }
}

/// Número aproximado de elementos (tarjetas o preguntas) presentes en una salida JSON parcial.
int countStreamedItems(String streamed, StudyKind kind) {
  final key = switch (kind) {
    StudyKind.flashcards => '"front"',
    StudyKind.quiz => '"question"',
    _ => null,
  };
  if (key == null) return 0;
  return key.allMatches(streamed).length;
}
