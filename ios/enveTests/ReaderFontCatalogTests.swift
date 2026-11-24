import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderFontCatalogTests {

    @Test func catalogOffersAtLeastTwoHundredUniqueFamilies() {
        let names = ReaderFontCatalog.families.map { $0.name.lowercased() }

        #expect(names.count >= 200)
        #expect(Set(names).count == names.count)
        #expect(ReaderFontCatalog.Category.allCases.allSatisfy { category in
            ReaderFontCatalog.families.contains { $0.category == category }
        })
    }

    @Test func catalogIncludesEveryBuiltInGoogleFamily() {
        for builtIn in ReaderFontLibrary.GoogleFontFamily.allCases {
            #expect(ReaderFontCatalog.family(named: builtIn.familyName) != nil)
        }
    }

    @Test func searchFiltersByNameAndCategory() {
        let mono = ReaderFontCatalog.families(matching: "plex", in: .monospace)
        #expect(mono.map(\.name) == ["IBM Plex Mono"])

        let anyPlex = ReaderFontCatalog.families(matching: "  PLEX ", in: nil).map(\.name)
        #expect(Set(anyPlex) == ["IBM Plex Serif", "IBM Plex Sans", "IBM Plex Mono"])

        #expect(ReaderFontCatalog.families(matching: "", in: .serif).allSatisfy { $0.category == .serif })
        #expect(ReaderFontCatalog.families(matching: "zzzz-not-a-font", in: nil).isEmpty)
        #expect(ReaderFontCatalog.family(named: "eb garamond")?.name == "EB Garamond")
    }

    @Test func licenseURLsFollowGoogleFontsRepositoryLayout() {
        let urls = ReaderFontLibrary.licenseURLs(for: "Source Serif 4").map(\.absoluteString)

        #expect(
            urls == [
                "https://raw.githubusercontent.com/google/fonts/main/ofl/sourceserif4/OFL.txt",
                "https://raw.githubusercontent.com/google/fonts/main/apache/sourceserif4/LICENSE.txt",
                "https://raw.githubusercontent.com/google/fonts/main/ufl/sourceserif4/UFL.txt",
            ]
        )
        #expect(ReaderFontLibrary.licenseURLs(for: "  ").isEmpty)
    }

    @Test func previewDescriptorComesFromInstalledFileOnly() throws {
        let identifier = UUID().uuidString
        let fontsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-font-catalog-tests-\(identifier)", isDirectory: true)
        let suiteName = "enve-font-catalog-tests-\(identifier)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: fontsDirectory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let library = ReaderFontLibrary(
            userDefaults: defaults,
            fontsDirectory: fontsDirectory,
            registerInstalledFonts: false
        )
        let bundleURL = try #require(
            Bundle.main.url(forResource: "Readium_ReadiumNavigator", withExtension: "bundle")
        )
        let sourceURL = try #require(
            Bundle(url: bundleURL)?.url(
                forResource: "iAWriterDuospace-Regular",
                withExtension: "ttf",
                subdirectory: "Assets/Static/readium-css/fonts"
            )
        )

        let installed = try library.importFontFile(from: sourceURL)
        #expect(library.previewFontDescriptor(for: installed) != nil)

        let missing = ReaderFontLibrary.InstalledFontFamily(
            familyName: "Missing",
            displayName: "Missing",
            source: .google,
            files: [
                ReaderFontLibrary.InstalledFontFile(
                    fileName: "Missing.ttf",
                    filePath: fontsDirectory.appendingPathComponent("Missing.ttf").path,
                    style: .normal,
                    weightKind: .standardNormal
                )
            ]
        )
        #expect(library.previewFontDescriptor(for: missing) == nil)
    }
}
