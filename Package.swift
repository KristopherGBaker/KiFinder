// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "KiFinder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "KionEngine",
            targets: ["KionEngine"]
        ),
        .library(
            name: "KionONNXEmbedder",
            targets: ["KionONNXEmbedder"]
        ),
        .library(
            name: "KionVisionEmbedder",
            targets: ["KionVisionEmbedder"]
        ),
        .library(
            name: "KionCoreMLEmbedder",
            targets: ["KionCoreMLEmbedder"]
        ),
        .executable(
            name: "KionCLI",
            targets: ["KionCLI"]
        )
    ],
    targets: [
        .target(
            name: "KionORTShim"
        ),
        .target(
            name: "KionEngine"
        ),
        .target(
            name: "KionONNXEmbedder",
            dependencies: ["KionEngine", "KionORTShim"],
            resources: [
                .copy("Resources/libonnxruntime.1.27.0.dylib")
            ]
        ),
        .target(
            name: "KionVisionEmbedder",
            dependencies: ["KionEngine"]
        ),
        .target(
            name: "KionCoreMLEmbedder",
            dependencies: ["KionEngine"]
        ),
        .executableTarget(
            name: "KionCLI",
            dependencies: ["KionEngine", "KionONNXEmbedder", "KionVisionEmbedder", "KionCoreMLEmbedder"]
        ),
        .testTarget(
            name: "KionEngineTests",
            dependencies: ["KionEngine", "KionONNXEmbedder", "KionVisionEmbedder", "KionCoreMLEmbedder"]
        )
    ]
)
