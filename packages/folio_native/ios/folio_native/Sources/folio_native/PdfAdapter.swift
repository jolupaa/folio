import Foundation
import PDFKit
import UIKit

/// Acceso a PDF con PDFKit. Se llama siempre desde una cola serie de fondo; cada operación abre
/// su propio `PDFDocument`.
enum PdfAdapter {
  private static let minWidth = 64
  private static let maxWidth = 4096
  private static let maxSide: CGFloat = 8192

  static func pageCount(path: String) throws -> Int {
    return try openDocument(path: path).pageCount
  }

  static func pageText(path: String, index: Int) throws -> String {
    let document = try openDocument(path: path)
    guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
      throw NativeError.io("La página \(index + 1) no existe en el PDF.")
    }
    return (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Renderiza la página como PNG opaco con fondo blanco y ancho `targetWidth` (px).
  /// Respeta la rotación de la página (/Rotate) y el cuadro de recorte (CropBox).
  static func renderPage(path: String, index: Int, outPath: String, targetWidth: Int) throws -> [String: Any] {
    let document = try openDocument(path: path)
    guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
      throw NativeError.io("La página \(index + 1) no existe en el PDF.")
    }

    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else {
      throw NativeError.io("La página \(index + 1) está vacía o dañada.")
    }
    let rotation = ((page.rotation % 360) + 360) % 360
    let quarter = rotation == 90 || rotation == 270
    // Tamaño de la página tal como se muestra (ya rotada), en puntos.
    let shown = quarter ? CGSize(width: box.height, height: box.width) : box.size

    var scale = CGFloat(min(max(targetWidth, minWidth), maxWidth)) / shown.width
    if shown.height * scale > maxSide { scale = maxSide / shown.height }
    let outSize = CGSize(
      width: max(1, (shown.width * scale).rounded()),
      height: max(1, (shown.height * scale).rounded()))

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1  // tamaño exacto en píxeles, independiente de la pantalla
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: outSize, format: format)
    let pageRef = page.pageRef

    let image = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: outSize))
      let cg = context.cgContext

      guard let pageRef = pageRef else {
        // Sin página CoreGraphics: miniatura de PDFKit (ya rotada) escalada al lienzo.
        let thumbnail = page.thumbnail(of: outSize, for: .cropBox)
        thumbnail.draw(in: CGRect(origin: .zero, size: outSize))
        return
      }

      cg.saveGState()
      cg.interpolationQuality = .high
      // UIKit (origen arriba, y hacia abajo) → espacio PDF (origen abajo, y hacia arriba) escalado.
      cg.translateBy(x: 0, y: outSize.height)
      cg.scaleBy(x: scale, y: -scale)
      // /Rotate gira la página en sentido horario al mostrarla.
      switch rotation {
      case 90:
        cg.translateBy(x: 0, y: shown.height)
        cg.rotate(by: -.pi / 2)
      case 180:
        cg.translateBy(x: shown.width, y: shown.height)
        cg.rotate(by: .pi)
      case 270:
        cg.translateBy(x: shown.width, y: 0)
        cg.rotate(by: .pi / 2)
      default:
        break
      }
      cg.translateBy(x: -box.minX, y: -box.minY)
      cg.clip(to: box)
      cg.drawPDFPage(pageRef)
      cg.restoreGState()
    }

    guard let data = image.pngData() else {
      throw NativeError.io("No se pudo codificar la página como PNG.")
    }
    try writeAtomically(data, to: URL(fileURLWithPath: outPath), what: "la página")
    return ["path": outPath, "width": Int(outSize.width), "height": Int(outSize.height)]
  }

  private static func openDocument(path: String) throws -> PDFDocument {
    guard FileManager.default.fileExists(atPath: path) else {
      throw NativeError.io("No se encuentra el PDF.")
    }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw NativeError.io("El PDF está dañado o no es compatible.")
    }
    if document.isLocked {
      throw NativeError.io("El PDF está protegido con contraseña.")
    }
    return document
  }

  static func writeAtomically(_ data: Data, to url: URL, what: String) throws {
    let directory = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      throw NativeError.write(error, what: what)
    }
  }
}
