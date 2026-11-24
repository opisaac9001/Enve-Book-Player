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
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
