#
# Podspec de folio_native. Mantener coherente con folio_native/Package.swift (SwiftPM):
# misma plataforma mínima (iOS 16), mismos fuentes y frameworks.
#
Pod::Spec.new do |s|
  s.name             = 'folio_native'
  s.version          = '0.0.1'
  s.summary          = 'Adaptadores nativos de Folio: OCR (Vision/ML Kit), PDF, escáner'
  s.description      = <<-DESC
OCR en el dispositivo con Apple Vision, render y texto de PDF con PDFKit, escáner de documentos
con VisionKit, memoria del dispositivo y exclusión de copias de seguridad.
                       DESC
  s.homepage         = 'https://folio.app'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Folio' => 'dev@folio.app' }
  s.source           = { :path => '.' }
  s.source_files     = 'folio_native/Sources/folio_native/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.frameworks       = 'Vision', 'VisionKit', 'PDFKit', 'AVFoundation', 'ImageIO'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'folio_native_privacy' => ['folio_native/Sources/folio_native/PrivacyInfo.xcprivacy']}
end
