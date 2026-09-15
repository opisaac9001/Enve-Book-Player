import Foundation
import ReadiumNavigator
import Testing
import UniformTypeIdentifiers

@testable import enve

@MainActor
struct FoliateReaderFontTests {
    @Test func importerAcceptsTrueTypeAndOpenTypeFonts() {
        #expect(UTType(filenameExtension: "ttf")?.conforms(to: .font) == true)
        #expect(UTType(filenameExtension: "otf")?.conforms(to: .font) == true)
    }

    @Test func packagesEveryOpenDyslexicFace() throws {
        let css = try #require(FoliateBuiltInFontCSS.openDyslexic)

        #expect(css.components(separatedBy: "@font-face").count - 1 == 4)
        #expect(css.contains("font-style: normal;"))
        #expect(css.contains("font-style: italic;"))
        #expect(css.contains("font-weight: 400;"))
        #expect(css.contains("font-weight: 700;"))
        #expect(css.contains("data:font/otf;base64,"))
    }

    @Test func importsUploadedFontForReadiumAndFoliate() throws {
        let environment = try makeLibrary()
        defer { environment.cleanUp() }
        let sourceURL = try readiumFontURL(
            named: "iAWriterDuospace-Regular",
            extension: "ttf",
            subdirectory: "Assets/Static/readium-css/fonts"
        )

        let installed = try environment.library.importFontFile(from: sourceURL)

        #expect(installed.source == .uploaded)
        #expect(installed.files.count == 1)
        #expect(FileManager.default.fileExists(atPath: installed.files[0].filePath))
        #expect(environment.library.hasUsableFontFamily(named: installed.familyName))
        #expect(
            environment.library.readiumDeclarations.contains {
                $0.fontFamily.rawValue == installed.familyName
            }
        )

        var appearance = ClassicReaderAppearance()
        appearance.usesCustomFont = true
        appearance.customFontFamilyName = installed.familyName
        let preferences = try FoliateReaderPreferences(
            appearance: appearance,
            fontLibrary: environment.library
        )
        #expect(preferences.customFontFamily == installed.familyName)
        #expect(preferences.customFontCSS?.contains("data:font/ttf;base64,") == true)
    }

    @Test func loadsInstalledMultiFaceFamilyForReadiumAndFoliate() async throws {
        let environment = try makeLibrary()
        defer { environment.cleanUp() }
        let family = try #require(
            ReaderFontLibrary.GoogleFontFamily.allCases.first { $0.id == "atkinson-hyperlegible" }
        )
        let familyDirectory = environment.fontsDirectory.appendingPathComponent(family.id, isDirectory: true)
        try FileManager.default.createDirectory(at: familyDirectory, withIntermediateDirectories: true)

        let sourceNames = [
            "OpenDyslexic-Regular",
            "OpenDyslexic-Bold",
            "OpenDyslexic-Italic",
            "OpenDyslexic-BoldItalic",
        ]
        for (entry, sourceName) in zip(family.files, sourceNames) {
            let sourceURL = try readiumFontURL(
                named: sourceName,
                extension: "otf",
                subdirectory: "Assets/Static/fonts"
            )
            try FileManager.default.copyItem(
                at: sourceURL,
                to: familyDirectory.appendingPathComponent(entry.fileName)
            )
        }

        let installed = try await environment.library.installGoogleFont(family)

        #expect(installed.source == .google)
        #expect(installed.files.count == 4)
        #expect(installed.files.allSatisfy { FileManager.default.fileExists(atPath: $0.filePath) })
        #expect(
            environment.library.readiumDeclarations.contains {
                $0.fontFamily.rawValue == installed.familyName
            }
        )

        var appearance = ClassicReaderAppearance()
        appearance.usesCustomFont = true
        appearance.customFontFamilyName = installed.familyName
        let preferences = try FoliateReaderPreferences(
            appearance: appearance,
            fontLibrary: environment.library
        )
        let css = try #require(preferences.customFontCSS)
        #expect(css.components(separatedBy: "@font-face").count - 1 == 4)
        #expect(css.contains("font-style: normal;"))
        #expect(css.contains("font-style: italic;"))
        #expect(css.contains("font-weight: 400;"))
        #expect(css.contains("font-weight: 700;"))
    }

    private func makeLibrary() throws -> TestLibraryEnvironment {
        let identifier = UUID().uuidString
        let fontsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-font-tests-\(identifier)", isDirectory: true)
        let suiteName = "enve-font-tests-\(identifier)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let library = ReaderFontLibrary(
            userDefaults: defaults,
            fontsDirectory: fontsDirectory,
            registerInstalledFonts: false
        )
        return TestLibraryEnvironment(
            library: library,
            fontsDirectory: fontsDirectory,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func readiumFontURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) throws -> URL {
        let bundleURL = try #require(
            Bundle.main.url(forResource: "Readium_ReadiumNavigator", withExtension: "bundle")
        )
        let bundle = try #require(Bundle(url: bundleURL))
        return try #require(
            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
        )
    }

    private struct TestLibraryEnvironment {
        let library: ReaderFontLibrary
        let fontsDirectory: URL
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            try? FileManager.default.removeItem(at: fontsDirectory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
