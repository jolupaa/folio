import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/study/study_models.dart';
import 'package:folio/src/rust/api/types.dart';

void main() {
  test('el contenido de una técnica se lee como texto Markdown', () {
    final c = StudyContent.parse(StudyKind.skill, '{"format":"markdown","text":"Hola [1]","citations":[]}');
    expect(c, isA<TextContent>());
    expect((c as TextContent).text, 'Hola [1]');
  });
}
