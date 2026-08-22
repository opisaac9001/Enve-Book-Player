// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UnrarKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "UnrarKit", targets: ["UnrarKit"]),
    ],
    targets: [
        .target(
            name: "unrar-lib",
            path: "Sources/unrar-lib",
            exclude: [
                "arccmt.cpp",
                "blake2sp.cpp",
                "cmdfilter.cpp",
                "cmdmix.cpp",
                "coder.cpp",
                "crypt1.cpp",
                "crypt2.cpp",
                "crypt3.cpp",
                "crypt5.cpp",
                "hardlinks.cpp",
                "log.cpp",
                "model.cpp",
                "recvol3.cpp",
                "recvol5.cpp",
                "suballoc.cpp",
                "uicommon.cpp",
                "uisilent.cpp",
                "ulinks.cpp",
                "unpack15.cpp",
                "unpack20.cpp",
                "unpack30.cpp",
                "unpack50.cpp",
                "unpack50frag.cpp",
                "unpackinline.cpp",
                "uowners.cpp",
                "win32stm.cpp",
                "threadmisc.cpp",
                "unpack50mt.cpp",
                "blake2s_sse.cpp",
                "isnt.cpp",
                "rarpch.cpp",
                "uiconsole.cpp",
                "win32acl.cpp",
                "win32lnk.cpp",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("SILENT"),
                .define("RARDLL"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP"),
            ],
            cxxSettings: [
                .define("SILENT"),
                .define("RARDLL"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP"),
                .unsafeFlags([
                    "-Wno-return-type",
                    "-Wno-logical-op-parentheses",
                    "-Wno-conversion",
                    "-Wno-parentheses",
                    "-Wno-unused-function",
                    "-Wno-unused-variable",
                    "-Wno-switch",
                    "-Wno-conditional-uninitialized",
                    "-Wno-comma",
                    "-Wno-delete-non-abstract-non-virtual-dtor",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "UnrarKit",
            dependencies: ["unrar-lib"],
            path: "Sources/UnrarKit"
        ),
    ],
    cxxLanguageStandard: .cxx14
)
