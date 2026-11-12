import Foundation
import ImageIO
import Vision

/// OCR en el dispositivo con Apple Vision (`VNRecognizeTextRequest`, nivel `.accurate`).
/// Se llama siempre desde una cola de fondo.
enum TextRecognizer {
  static let engine = "apple_vision"
  static let defaultLanguages = ["es-ES", "en-US"]

  /// Lado mayor máximo con el que se decodifica la imagen (acota la memoria con fotos enormes).
  private static let maxPixelSize = 4096

  private struct Line {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let confidence: Double
  }

  static func makeRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    if VNRecognizeTextRequest.supportedRevisions.contains(VNRecognizeTextRequestRevision3) {
      request.revision = VNRecognizeTextRequestRevision3
    }
    request.usesLanguageCorrection = true
    return request
  }

  /// Filtra los idiomas pedidos contra los que admite la revisión/nivel configurados en `request`.
  /// Acepta coincidencia exacta («es-ES») o por idioma base («es» → «es-ES»).
  static func resolveLanguages(_ requested: [String], for request: VNRecognizeTextRequest) -> [String] {
    let supported: [String] = (try? request.supportedRecognitionLanguages()) ?? []
    if supported.isEmpty { return [] }
    var chosen: [String] = []
    for language in requested {
      if let exact = supported.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
        if !chosen.contains(exact) { chosen.append(exact) }
        continue
      }
      let base = baseLanguage(language)
      if let match = supported.first(where: { baseLanguage($0) == base }), !chosen.contains(match) {
        chosen.append(match)
      }
    }
    return chosen
  }

  private static func baseLanguage(_ tag: String) -> String {
    let normalized = tag.replacingOccurrences(of: "_", with: "-").lowercased()
    return normalized.split(separator: "-").first.map(String.init) ?? normalized
  }

  static func info() -> [String: Any] {
    let request = makeRequest()
    let languages = resolveLanguages(defaultLanguages, for: request)
    return [
      "engine": engine,
      "languages": languages.isEmpty ? defaultLanguages : languages,
      // El modelo no está optimizado para manuscritos: la UI avisa de revisar el resultado.
      "handwriting": false,
      "available": true,
    ]
  }

  static func recognize(path: String, languages: [String]) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else {
      throw NativeError.io("No se encuentra la imagen que se quería reconocer.")
    }
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw NativeError.io("No se pudo leer la imagen (formato no compatible).")
    }
    // Miniatura acotada SIN aplicar la transformación EXIF: la orientación se pasa a Vision aparte,
    // así las cajas devueltas quedan en el espacio de la imagen tal como se ve.
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: false,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw NativeError.io("No se pudo decodificar la imagen.")
    }
    let orientation = exifOrientation(source)

    let request = makeRequest()
    let resolved = resolveLanguages(languages.isEmpty ? defaultLanguages : languages, for: request)
    if !resolved.isEmpty {
      request.recognitionLanguages = resolved
    }

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw NativeError.ocrFailed("El reconocimiento de texto falló: \(error.localizedDescription)")
    }

    let observations: [VNRecognizedTextObservation] = request.results ?? []
    var lines: [Line] = []
    lines.reserveCapacity(observations.count)
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { continue }
      // Vision: normalizado con origen ABAJO-izquierda → contrato: origen ARRIBA-izquierda.
      let box = observation.boundingBox
      let x = clampUnit(Double(box.minX))
      let y = clampUnit(1.0 - Double(box.maxY))
      let w = min(clampUnit(Double(box.width)), 1.0 - x)
      let h = min(clampUnit(Double(box.height)), 1.0 - y)
      lines.append(
        Line(text: text, x: x, y: y, w: w, h: h, confidence: clampUnit(Double(candidate.confidence))))
    }

    var result: [String: Any] = [
      "text": composeText(lines),
      "engine": engine,
      "lines": lines.map { line -> [String: Any] in
        [
          "text": line.text,
          "x": line.x,
          "y": line.y,
          "w": line.w,
          "h": line.h,
          "confidence": line.confidence,
        ]
      },
    ]
    if !lines.isEmpty {
      result["confidence"] = lines.reduce(0.0) { $0 + $1.confidence } / Double(lines.count)
    }
    return result
  }

  /// Une las líneas en el orden de lectura de Vision; separa párrafos (línea en blanco) cuando el
  /// hueco vertical supera la altura típica de línea o el texto salta a otra columna.
  private static func composeText(_ lines: [Line]) -> String {
    guard !lines.isEmpty else { return "" }
    let heights = lines.map { $0.h }.sorted()
    let typical = heights[heights.count / 2]
    var text = lines[0].text
    for index in 1..<lines.count {
      let previous = lines[index - 1]
      let line = lines[index]
      let gap = line.y - (previous.y + previous.h)
      let newColumn = line.y + line.h < previous.y
      text += (gap > typical * 0.9 || newColumn) ? "\n\n" : "\n"
      text += line.text
    }
    return text
  }

  private static func exifOrientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let raw = properties[kCGImagePropertyOrientation as String] as? NSNumber,
      let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value)
    else {
      return .up
    }
    return orientation
  }

  private static func clampUnit(_ value: Double) -> Double {
    if value.isNaN { return 0 }
    return min(max(value, 0), 1)
  }
}
