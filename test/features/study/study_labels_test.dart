import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/study/study_labels.dart';
import 'package:folio/src/rust/api/types.dart';

const _skills = [
  StudySkillInfo(
    id: 'feynman',
    name: 'Explícamelo fácil',
    section: 'Explicaciones fáciles',
    description: 'd',
    icon: 'lightbulb',
  ),
  StudySkillInfo(id: 'cornell', name: 'Notas Cornell', section: 'Notas Cornell', description: 'd', icon: 'cornell'),
];

StudyItemSummary _item(String id, StudyKind kind, {String? skill, int updatedAt = 0}) => StudyItemSummary(
  id: id,
  kind: kind,
  skill: skill,
  title: id,
  scopeLabel: '',
  sourceCount: 1,
  itemCount: 0,
  createdAt: 0,
  updatedAt: updatedAt,
);

void main() {
  group('studyDisplay', () {
    test('técnica conocida usa los datos del catálogo', () {
      final d = studyDisplay(StudyKind.skill, 'cornell', _skills);
      expect(d.label, 'Notas Cornell');
      expect(d.section, 'Notas Cornell');
      expect(d.icon, Icons.view_agenda_outlined);
    });

    test('técnica desconocida o ausente cae en «Material»', () {
      for (final skill in ['retirada', null]) {
        final d = studyDisplay(StudyKind.skill, skill, _skills);
        expect(d.label, 'Material');
        expect(d.section, 'Otras técnicas');
        expect(d.icon, Icons.auto_awesome_outlined);
      }
    });

    test('tipo fijo ignora el catálogo', () {
      final d = studyDisplay(StudyKind.quiz, null, _skills);
      expect(d.label, 'Cuestionario');
      expect(d.section, 'Cuestionarios');
      expect(d.icon, Icons.quiz_outlined);
    });
  });

  test('skillIcon traduce los nombres conocidos', () {
    expect(skillIcon('lightbulb'), Icons.lightbulb_outline_rounded);
    expect(skillIcon('cheatsheet'), Icons.receipt_long_outlined);
    expect(skillIcon('otro'), Icons.auto_awesome_outlined);
  });

  test('groupStudyItems: tipos fijos, técnicas del catálogo y el resto al final', () {
    final groups = groupStudyItems([
      _item('c-viejo', StudyKind.skill, skill: 'cornell', updatedAt: 1),
      _item('r', StudyKind.summary),
      _item('x', StudyKind.skill, skill: 'retirada'),
      _item('f', StudyKind.skill, skill: 'feynman'),
      _item('c-nuevo', StudyKind.skill, skill: 'cornell', updatedAt: 9),
    ], _skills);
    expect(groups.map((g) => g.header), ['Resúmenes', 'Explicaciones fáciles', 'Notas Cornell', 'Otras técnicas']);
    expect(groups[2].items.map((i) => i.id), ['c-nuevo', 'c-viejo']);
    expect(groups[3].items.single.id, 'x');
  });
}
