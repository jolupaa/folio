import AVFoundation
import Flutter
import UIKit
import os

/// Adaptadores nativos de Folio para iOS (docs/CONTRATOS.md §6). Canal `folio/native`.
///
/// `handle(_:result:)` se invoca en el hilo principal. El trabajo pesado (Vision, PDFKit, escritura de
/// ficheros) se hace en colas de fondo y el resultado se devuelve siempre en el hilo principal.
public class FolioNativePlugin: NSObject, FlutterPlugin {
  static let channelName = "folio/native"

  /// Cola concurrente para OCR (cada petición usa su propio VNImageRequestHandler).
  private let ocrQueue = DispatchQueue(
    label: "app.folio.native.ocr", qos: .userInitiated, attributes: .concurrent)
  /// Cola serie para PDF: evita abrir el mismo documento en paralelo y limita la memoria.
  private let pdfQueue = DispatchQueue(label: "app.folio.native.pdf", qos: .userInitiated)

  private var scannerSession: DocumentScannerSession?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let instance = FolioNativePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    ModelsDirectory.prepare()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ocr.recognize":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(NativeError.io("Falta la ruta de la imagen.").flutterError)
        return
      }
      let languages = (args["languages"] as? [String]) ?? TextRecognizer.defaultLanguages
      ocrQueue.async {
        let outcome: Any
        do {
          outcome = try TextRecognizer.recognize(path: path, languages: languages)
        } catch let error as NativeError {
          outcome = error.flutterError
        } catch {
          outcome = NativeError.ocrFailed(error.localizedDescription).flutterError
        }
        DispatchQueue.main.async { result(outcome) }
      }

    case "ocr.info":
      ocrQueue.async {
        let info = TextRecognizer.info()
        DispatchQueue.main.async { result(info) }
      }

    case "pdf.pageCount":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(NativeError.io("Falta la ruta del PDF.").flutterError)
        return
      }
      runOnPdfQueue(result) { try PdfAdapter.pageCount(path: path) }

    case "pdf.renderPage":
      guard let path = args["path"] as? String, !path.isEmpty,
        let outPath = args["outPath"] as? String, !outPath.isEmpty,
        let page = (args["page"] as? NSNumber)?.intValue
      else {
        result(NativeError.io("Faltan argumentos para renderizar la página.").flutterError)
        return
      }
      let targetWidth = (args["targetWidth"] as? NSNumber)?.intValue ?? 1700
      runOnPdfQueue(result) {
        try PdfAdapter.renderPage(path: path, index: page, outPath: outPath, targetWidth: targetWidth)
      }

    case "pdf.pageText":
      guard let path = args["path"] as? String, !path.isEmpty,
        let page = (args["page"] as? NSNumber)?.intValue
      else {
        result(NativeError.io("Faltan argumentos para leer el texto de la página.").flutterError)
        return
      }
      runOnPdfQueue(result) { try PdfAdapter.pageText(path: path, index: page) }

    case "scanner.scan":
      startScan(result: result)

    case "files.excludeFromBackup":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(NativeError.io("Falta la ruta.").flutterError)
        return
      }
      DispatchQueue.global(qos: .utility).async {
        let outcome: Any
        do {
          try BackupExclusion.exclude(path: path)
          outcome = true
        } catch let error as NativeError {
          outcome = error.flutterError
        } catch {
          outcome = NativeError.io(error.localizedDescription).flutterError
        }
        DispatchQueue.main.async { result(outcome) }
      }

    case "device.memory":
      let total = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
      let available = Int64(os_proc_available_memory())
      result(["total": total, "available": available])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func runOnPdfQueue(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any) {
    pdfQueue.async {
      let outcome: Any
      do {
        outcome = try autoreleasepool { try work() }
      } catch let error as NativeError {
        outcome = error.flutterError
      } catch {
        outcome = NativeError.io(error.localizedDescription).flutterError
      }
      DispatchQueue.main.async { result(outcome) }
    }
  }

  // MARK: - Escáner (VisionKit)

  private func startScan(result: @escaping FlutterResult) {
    guard DocumentScannerSession.isSupported else {
      result(NativeError.unsupported("El escáner de documentos no está disponible en este dispositivo.").flutterError)
      return
    }
    guard scannerSession == nil else {
      result(NativeError.io("Ya hay un escaneo en curso.").flutterError)
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      presentScanner(result: result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if granted {
            self.presentScanner(result: result)
          } else {
            result(NativeError.permissionDenied("Folio no tiene acceso a la cámara.").flutterError)
          }
        }
      }
    case .denied, .restricted:
      result(NativeError.permissionDenied("Folio no tiene acceso a la cámara.").flutterError)
    @unknown default:
      result(NativeError.permissionDenied("Folio no tiene acceso a la cámara.").flutterError)
    }
  }

  private func presentScanner(result: @escaping FlutterResult) {
    guard scannerSession == nil else {
      result(NativeError.io("Ya hay un escaneo en curso.").flutterError)
      return
    }
    guard let presenter = Self.topViewController() else {
      result(NativeError.io("No se encontró una ventana activa para mostrar el escáner.").flutterError)
      return
    }
    let session = DocumentScannerSession { [weak self] outcome in
      self?.scannerSession = nil
      result(outcome)
    }
    scannerSession = session
    session.present(from: presenter)
  }

  /// Controlador visible de la escena activa (raíz y, si hay, el último presentado).
  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene =
      scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first { $0.activationState == .foregroundInactive }
      ?? scenes.first
    guard let windowScene = scene else { return nil }
    let window = windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
