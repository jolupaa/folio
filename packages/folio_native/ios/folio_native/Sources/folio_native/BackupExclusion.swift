import Foundation

/// Exclusión de ficheros de la copia de seguridad de iCloud / Finder.
enum BackupExclusion {
  static func exclude(path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else {
      throw NativeError.io("No existe el fichero o carpeta que se quería excluir de la copia de seguridad.")
    }
    var url = URL(fileURLWithPath: path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
    } catch {
      throw NativeError.io("No se pudo excluir de la copia de seguridad: \(error.localizedDescription)")
    }
  }
}

/// Directorio `Application Support/models` (modelos GGUF de varios GB): se crea si falta y se
/// excluye de la copia de seguridad. Coincide con `<data_dir>/models` (data_dir = Application Support,
/// que es lo que devuelve `getApplicationSupportDirectory()` en iOS).
enum ModelsDirectory {
  static func prepare() {
    DispatchQueue.global(qos: .utility).async {
      let fileManager = FileManager.default
      guard
        let support = try? fileManager.url(
          for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      else {
        NSLog("folio_native: no se pudo localizar Application Support")
        return
      }
      var models = support.appendingPathComponent("models", isDirectory: true)
      do {
        try fileManager.createDirectory(at: models, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try models.setResourceValues(values)
      } catch {
        NSLog("folio_native: no se pudo preparar models/: \(error.localizedDescription)")
      }
    }
  }
}
