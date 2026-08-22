// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "StoryAlign",
    platforms: [
        .macOS(.v15),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "StoryAlignCore",
            targets: ["StoryAlignCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "ZIPFoundation",
            path: "VendoredZIPFoundation",
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
            ]
        ),
    ]
)
