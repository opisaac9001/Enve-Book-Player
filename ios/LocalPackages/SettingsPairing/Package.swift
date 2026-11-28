// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SettingsPairing",
    platforms: [.iOS(.v17)],
    products: [.library(name: "CSettingsPairing", targets: ["CSettingsPairing"])],
    targets: [.target(
        name: "CSettingsPairing",
        exclude: ["mbedtls/UPSTREAM.txt"],
        resources: [.copy("mbedtls/LICENSE")],
        cSettings: [
            .headerSearchPath("mbedtls/include"),
            .headerSearchPath("mbedtls"),
            .define("MBEDTLS_CONFIG_FILE", to: "\"pairing_config.h\""),
        ]
    )]
)
