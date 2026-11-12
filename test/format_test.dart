import 'package:flutter_test/flutter_test.dart';
import 'package:folio/core/format.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  test('relativeDate', () {
    final now = DateTime(2026, 11, 11, 18);
    expect(Fmt.relativeDate(DateTime(2026, 11, 11, 9, 5).millisecondsSinceEpoch, now: now), '9:05');
    expect(Fmt.relativeDate(DateTime(2026, 11, 10, 9).millisecondsSinceEpoch, now: now), 'Ayer');
    expect(Fmt.relativeDate(DateTime(2025, 1, 2).millisecondsSinceEpoch, now: now), contains('2025'));
  });

  test('bytes y ubicación', () {
    expect(Fmt.bytes(2740937888), '2,7 GB');
    expect(Fmt.bytes(639150592), '639 MB');
    expect(Fmt.location(const []), 'Notas');
    expect(Fmt.location(const ['Física', 'Tema 2']), 'Física › Tema 2');
  });
}
