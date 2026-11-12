import Flutter
import Foundation

/// Error con código del contrato (docs/CONTRATOS.md §6) que se devuelve a Dart como
/// `PlatformException(code, message)`.
struct NativeError: Error {
  let code: String
  let message: String

  var flutterError: FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  static func permissionDenied(_ message: String) -> NativeError {
    NativeError(code: "permission_denied", message: message)
  }

  static func unsupported(_ message: String) -> NativeError {
    NativeError(code: "unsupported", message: message)
  }

  static func io(_ message: String) -> NativeError {
    NativeError(code: "io", message: message)
  }

  static func ocrFailed(_ message: String) -> NativeError {
    NativeError(code: "ocr_failed", message: message)
  }

  static func cancelled(_ message: String) -> NativeError {
    NativeError(code: "cancelled", message: message)
  }

  /// Traduce un error de escritura a un mensaje legible (sin espacio, permisos…).
  static func write(_ error: Error, what: String) -> NativeError {
    let nsError = error as NSError
    let outOfSpace =
      (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
      || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
    if outOfSpace {
      return .io("No queda espacio suficiente en el dispositivo para guardar \(what).")
    }
    return .io("No se pudo guardar \(what): \(nsError.localizedDescription)")
  }
}
