import 'package:flutter/material.dart';

import '../../src/rust/api/types.dart';

/// Nombre singular de un tipo de material.
String studyKindLabel(StudyKind k) => switch (k) {
  StudyKind.summary => 'Resumen',
  StudyKind.outline => 'Esquema',
  StudyKind.keyConcepts => 'Conceptos clave',
  StudyKind.flashcards => 'Flashcards',
  StudyKind.quiz => 'Cuestionario',
};

/// Encabezado de sección (plural).
String studyKindSection(StudyKind k) => switch (k) {
  StudyKind.summary => 'Resúmenes',
  StudyKind.outline => 'Esquemas',
  StudyKind.keyConcepts => 'Conceptos clave',
  StudyKind.flashcards => 'Flashcards',
  StudyKind.quiz => 'Cuestionarios',
};

IconData studyKindIcon(StudyKind k) => switch (k) {
  StudyKind.summary => Icons.notes_rounded,
  StudyKind.outline => Icons.account_tree_outlined,
  StudyKind.keyConcepts => Icons.key_rounded,
  StudyKind.flashcards => Icons.style_outlined,
  StudyKind.quiz => Icons.quiz_outlined,
};

/// «12 tarjetas», «10 preguntas»; vacío para textos.
String studyItemCount(StudyKind k, int n) => switch (k) {
  StudyKind.flashcards => n == 1 ? '1 tarjeta' : '$n tarjetas',
  StudyKind.quiz => n == 1 ? '1 pregunta' : '$n preguntas',
  _ => '',
};

/// Puntuación 0..1 como porcentaje «75 %».
String percentLabel(double score) => '${(score.clamp(0.0, 1.0) * 100).round()} %';

/// «7,5» con coma decimal; enteros sin decimales.
String decimalLabel(double v) {
  final rounded = (v * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return '${rounded.round()}';
  return rounded.toStringAsFixed(1).replaceAll('.', ',');
}
