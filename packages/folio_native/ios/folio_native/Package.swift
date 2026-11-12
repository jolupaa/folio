// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Mantener coherente con ../folio_native.podspec (plataforma iOS 16 y frameworks enlazados).
let package = Package(
    name: "folio_native",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .library(name: "folio-native", targets: ["folio_native"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "folio_native",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("VisionKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO"),
            ]
        )
    ]
)
