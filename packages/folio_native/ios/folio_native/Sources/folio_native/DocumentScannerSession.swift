import UIKit
import VisionKit

/// Una sesión del escáner de documentos de VisionKit (detección de bordes y corrección de
/// perspectiva). Guarda cada página como JPEG en el directorio temporal y entrega las rutas.
///
/// El plugin retiene la sesión hasta que termina (el `delegate` de VisionKit es débil).
final class DocumentScannerSession: NSObject, VNDocumentCameraViewControllerDelegate {
  static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

  private static let jpegQuality: CGFloat = 0.9
  private var completion: ((Any) -> Void)?

  /// `completion` recibe `[String]` (rutas) o `FlutterError`, siempre en el hilo principal.
  init(completion: @escaping (Any) -> Void) {
    self.completion = completion
    super.init()
  }

  func present(from presenter: UIViewController) {
    let controller = VNDocumentCameraViewController()
    controller.delegate = self
    controller.modalPresentationStyle = .fullScreen
    presenter.present(controller, animated: true)
  }

  // MARK: VNDocumentCameraViewControllerDelegate

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
  ) {
    controller.dismiss(animated: true)
    if scan.pageCount == 0 {
      finish(NativeError.cancelled("No se ha escaneado ninguna página.").flutterError)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let outcome: Any
      do {
        outcome = try DocumentScannerSession.save(scan: scan)
      } catch let error as NativeError {
        outcome = error.flutterError
      } catch {
        outcome = NativeError.io(error.localizedDescription).flutterError
      }
      DispatchQueue.main.async {
        self.finish(outcome)
      }
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    controller.dismiss(animated: true)
    finish(NativeError.cancelled("Escaneo cancelado.").flutterError)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    controller.dismiss(animated: true)
    finish(NativeError.io("El escáner falló: \(error.localizedDescription)").flutterError)
  }

  // MARK: Privado

  private func finish(_ outcome: Any) {
    guard let completion = completion else { return }
    self.completion = nil
    completion(outcome)
  }

  private static func save(scan: VNDocumentCameraScan) throws -> [String] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("folio_scan", isDirectory: true)
    var paths: [String] = []
    do {
      for index in 0..<scan.pageCount {
        try autoreleasepool {
          let image = scan.imageOfPage(at: index)
          guard let data = image.jpegData(compressionQuality: jpegQuality) else {
            throw NativeError.io("No se pudo codificar la página \(index + 1).")
          }
          let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
          try PdfAdapter.writeAtomically(data, to: url, what: "la página escaneada")
          paths.append(url.path)
        }
      }
    } catch {
      for path in paths {
        try? FileManager.default.removeItem(atPath: path)
      }
      throw error
    }
    return paths
  }
}
