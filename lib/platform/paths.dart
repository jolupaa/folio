import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Rutas de trabajo en caché (docs/CONTRATOS.md §7: `<cache_dir>/tmp/`).
abstract final class AppPaths {
  static Future<Directory> _cache() => getTemporaryDirectory();

  /// `<cache>/tmp/<name>` (creado si no existe).
  static Future<Directory> tmpDir(String name) async {
    final base = await _cache();
    final dir = Directory('${base.path}${Platform.pathSeparator}tmp${Platform.pathSeparator}$name');
    await dir.create(recursive: true);
    return dir;
  }

  /// `<cache>/pdf/<attachmentId>` (renders de páginas de PDF cacheados; creado si no existe).
  static Future<Directory> pdfCacheDir(String attachmentId) async {
    final base = await _cache();
    final dir = Directory('${base.path}${Platform.pathSeparator}pdf${Platform.pathSeparator}$attachmentId');
    await dir.create(recursive: true);
    return dir;
  }

  /// true si [path] está dentro de la caché/temporales de la app (se puede borrar sin riesgo).
  static Future<bool> isInAppCache(String path) async {
    final base = await _cache();
    final normalized = File(path).absolute.path;
    return isWithin(base.path, normalized);
  }

  /// true si [child] está dentro de [parent] (comparación de rutas absolutas).
  static bool isWithin(String parent, String child) {
    final sep = Platform.pathSeparator;
    final p = parent.endsWith(sep) ? parent : '$parent$sep';
    return child.startsWith(p);
  }

  /// Borra un fichero sin lanzar.
  static Future<void> deleteQuietly(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Fichero en uso o ya borrado: no es un error para el usuario.
    }
  }

  /// Borra un directorio y su contenido sin lanzar.
  static Future<void> deleteDirQuietly(Directory? dir) async {
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Ignorado: es una carpeta temporal.
    }
  }
}
