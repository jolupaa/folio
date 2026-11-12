import 'package:intl/intl.dart';

/// Formatos legibles en español.
abstract final class Fmt {
  static final _time = DateFormat.Hm('es');
  static final _dayMonth = DateFormat.MMMd('es');
  static final _full = DateFormat.yMMMd('es');
  static final _weekday = DateFormat.EEEE('es');

  /// «10:24» hoy, «Ayer», «lunes» (última semana), «12 nov», «12 nov 2024».
  static String relativeDate(int millis, {DateTime? now}) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return _time.format(d);
    if (diff == 1) return 'Ayer';
    if (diff > 1 && diff < 7) return _weekday.format(d);
    if (d.year == n.year) return _dayMonth.format(d);
    return _full.format(d);
  }

  /// «2,7 GB», «640 MB», «12 kB».
  static String bytes(int bytes) {
    const units = ['B', 'kB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    final f = NumberFormat(v >= 100 || i == 0 ? '0' : '0.#', 'es');
    return '${f.format(v)} ${units[i]}';
  }

  /// Ruta de carpetas: «Física › Tema 2»; vacía → «Notas».
  static String location(List<String> path) => path.isEmpty ? 'Notas' : path.join(' › ');

  static String count(int n, String singular, String plural) => '$n ${n == 1 ? singular : plural}';
}
