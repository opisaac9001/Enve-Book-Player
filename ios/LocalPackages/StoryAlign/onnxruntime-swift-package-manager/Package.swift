// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "onnxruntime",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [.library(name: "onnxruntime", type: .static, targets: ["OnnxRuntimeBindings"])],
    targets: [
        .target(
            name: "OnnxRuntimeBindings",
            dependencies: ["onnxruntime"],
            path: "objectivec",
            cxxSettings: [.define("SPM_BUILD")]
        ),
        .binaryTarget(
            name: "onnxruntime",
            path: "pod-archive-onnxruntime-c-1.24.2.zip"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
