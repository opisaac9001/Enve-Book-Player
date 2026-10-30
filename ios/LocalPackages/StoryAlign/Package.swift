// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "StoryAlign",
    platforms: [
        .macOS(.v15),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "ctc-align", targets: ["CTCAlign"]),
        .library(
            name: "StoryAlignCore",
            targets: ["StoryAlignCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "ZIPFoundation",
            path: "VendoredZIPFoundation",
            exclude: ["LICENSE"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "StoryAlignCore",
            dependencies: [
                "ZIPFoundation",
                "SwiftSoup",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager", condition: .when(platforms: [.iOS, .macOS])),
            ],
            exclude: ["StoryAlignCore.docc"]
        ),
        .testTarget(name: "StoryAlignCoreTests", dependencies: ["StoryAlignCore"]),
        .executableTarget(name: "CTCAlign", dependencies: ["StoryAlignCore"]),
    ]
)
