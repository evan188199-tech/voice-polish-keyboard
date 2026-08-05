// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SherpaOnnxLocal",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SherpaOnnx", targets: ["SherpaOnnx"])
    ],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxC",
            path: "../Frameworks/sherpa-onnx.xcframework"
        ),
        .binaryTarget(
            name: "onnxruntime",
            path: "../Frameworks/onnxruntime.xcframework"
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: [
                "SherpaOnnxC",
                "onnxruntime"
            ],
            path: "Sources/SherpaOnnx",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML")
            ]
        )
    ]
)
