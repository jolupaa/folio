import 'package:flutter/material.dart';

import '../../src/rust/api/types.dart';

/// Nombre singular de un tipo de material.
String studyKindLabel(StudyKind k) => switch (k) {
  StudyKind.summary => 'Resumen',
  StudyKind.outline => 'Esquema',
  StudyKind.keyConcepts => 'Conceptos clave',
  StudyKind.flashcards => 'Flashcards',
  StudyKind.quiz => 'Cuestionario',
  StudyKind.skill => 'Material',
};

/// Encabezado de sección (plural).
String studyKindSection(StudyKind k) => switch (k) {
  StudyKind.summary => 'Resúmenes',
  StudyKind.outline => 'Esquemas',
  StudyKind.keyConcepts => 'Conceptos clave',
  StudyKind.flashcards => 'Flashcards',
  StudyKind.quiz => 'Cuestionarios',
  StudyKind.skill => 'Otras técnicas',
};

IconData studyKindIcon(StudyKind k) => switch (k) {
  StudyKind.summary => Icons.notes_rounded,
  StudyKind.outline => Icons.account_tree_outlined,
  StudyKind.keyConcepts => Icons.key_rounded,
  StudyKind.flashcards => Icons.style_outlined,
  StudyKind.quiz => Icons.quiz_outlined,
  StudyKind.skill => Icons.auto_awesome_outlined,
};

/// «12 tarjetas», «10 preguntas»; vacío para textos.
String studyItemCount(StudyKind k, int n) => switch (k) {
  StudyKind.flashcards => n == 1 ? '1 tarjeta' : '$n tarjetas',
  StudyKind.quiz => n == 1 ? '1 pregunta' : '$n preguntas',
  _ => '',
};

/// Icono de una técnica del catálogo (`StudySkillInfo.icon`).
IconData skillIcon(String name) => switch (name) {
  'lightbulb' => Icons.lightbulb_outline_rounded,
  'cornell' => Icons.view_agenda_outlined,
  'cheatsheet' => Icons.receipt_long_outlined,
  _ => Icons.auto_awesome_outlined,
};

/// Etiqueta, sección e icono de un material. Las técnicas se resuelven con el catálogo; una
/// técnica que ya no existe se muestra como «Material».
({String label, String section, IconData icon}) studyDisplay(
  StudyKind kind,
  String? skill,
  List<StudySkillInfo> skills,
) {
  final info = kind == StudyKind.skill ? skills.where((s) => s.id == skill).firstOrNull : null;
  if (info != null) return (label: info.name, section: info.section, icon: skillIcon(info.icon));
  return (label: studyKindLabel(kind), section: studyKindSection(kind), icon: studyKindIcon(kind));
}

/// Orden de los tipos fijos en la lista de materiales.
const studyKindOrder = [
  StudyKind.summary,
  StudyKind.outline,
  StudyKind.keyConcepts,
  StudyKind.flashcards,
  StudyKind.quiz,
];

/// Secciones de la lista: tipos fijos, técnicas en el orden del catálogo y, al final, las
/// técnicas desconocidas. Cada sección, de más reciente a más antigua; sin secciones vacías.
List<({String header, List<StudyItemSummary> items})> groupStudyItems(
  List<StudyItemSummary> items,
  List<StudySkillInfo> skills,
) {
  final known = {for (final s in skills) s.id};
  final keys = <String>[
    for (final k in studyKindOrder) 'kind:${k.name}',
    for (final s in skills) 'skill:${s.id}',
    'skill:?',
  ];
  final byKey = <String, List<StudyItemSummary>>{};
  for (final it in items) {
    final key = it.kind != StudyKind.skill
        ? 'kind:${it.kind.name}'
        : (known.contains(it.skill) ? 'skill:${it.skill}' : 'skill:?');
    byKey.putIfAbsent(key, () => []).add(it);
  }
  return [
    for (final key in keys)
      if (byKey[key] case final list? when list.isNotEmpty)
        (
          header: studyDisplay(list.first.kind, list.first.skill, skills).section,
          items: list..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
        ),
  ];
}

/// Puntuación 0..1 como porcentaje «75 %».
String percentLabel(double score) => '${(score.clamp(0.0, 1.0) * 100).round()} %';

/// «7,5» con coma decimal; enteros sin decimales.
String decimalLabel(double v) {
  final rounded = (v * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return '${rounded.round()}';
  return rounded.toStringAsFixed(1).replaceAll('.', ',');
}
