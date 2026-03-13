// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AawaazDependencies",
    platforms: [
        .macOS(.v14)
    ],
    products: [],
    dependencies: [
        .package(url: "https://github.com/ggerganov/whisper.cpp.git", from: "1.7.4"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.16.0"),
    ],
    targets: []
)
