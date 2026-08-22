import Combine
import CoreText
import Foundation
import Logging
import ReadiumNavigator
import ReadiumShared

@MainActor
@Observable
final class ReaderFontLibrary {
    static let shared = ReaderFontLibrary()

    enum FontInstallError: LocalizedError {
        case invalidName
        case fontNotFound(String)
        case networkError(String)
        case parseError
        case noFilesFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Please enter a valid font name."
            case .fontNotFound(let name):
                return "\(name) was not found on Google Fonts."
            case .networkError(let details):
                return "Could not reach Google Fonts: \(details)"
            case .parseError:
                return "Could not parse the Google Fonts response."
            case .noFilesFound(let name):
                return "No downloadable font files were found for \(name)."
            }
        }
    }

    struct InstalledFontFile: Identifiable, Codable, Equatable, Sendable {
        enum FaceStyle: String, Codable, Sendable {
            case normal
            case italic
        }

        enum WeightKind: Codable, Equatable, Sendable {
            case standardNormal
            case standardBold
            case variable(range: ClosedRange<Int>)

            private enum CodingKeys: String, CodingKey {
                case type
                case lower
                case upper
            }

            private enum Kind: String, Codable {
                case standardNormal
                case standardBold
                case variable
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(Kind.self, forKey: .type) {
                case .standardNormal:
                    self = .standardNormal
                case .standardBold:
                    self = .standardBold
                case .variable:
                    let lower = try container.decode(Int.self, forKey: .lower)
                    let upper = try container.decode(Int.self, forKey: .upper)
                    self = .variable(range: lower...upper)
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .standardNormal:
                    try container.encode(Kind.standardNormal, forKey: .type)
                case .standardBold:
                    try container.encode(Kind.standardBold, forKey: .type)
                case .variable(let range):
                    try container.encode(Kind.variable, forKey: .type)
                    try container.encode(range.lowerBound, forKey: .lower)
                    try container.encode(range.upperBound, forKey: .upper)
                }
            }
        }

        let id: String
        let fileName: String
        let filePath: String
        let style: FaceStyle
        let weightKind: WeightKind

        init(
            id: String = UUID().uuidString,
            fileName: String,
            filePath: String,
            style: FaceStyle,
            weightKind: WeightKind
        ) {
            self.id = id
            self.fileName = fileName
            self.filePath = filePath
            self.style = style
            self.weightKind = weightKind
        }
    }

    struct InstalledFontFamily: Identifiable, Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable {
            case google
            case uploaded
        }

        let id: String
        let familyName: String
        let displayName: String
        let source: Source
        let files: [InstalledFontFile]

        init(
            id: String = UUID().uuidString,
            familyName: String,
            displayName: String,
            source: Source,
            files: [InstalledFontFile]
        ) {
            self.id = id
            self.familyName = familyName
            self.displayName = displayName
            self.source = source
            self.files = files
        }
    }

    struct GoogleFontFamily: Identifiable, CaseIterable, Sendable {
        struct DownloadFile: Sendable {
            let fileName: String
            let url: String
            let style: InstalledFontFile.FaceStyle
            let weightKind: InstalledFontFile.WeightKind
        }

        let id: String
        let familyName: String
        let displayName: String
        let files: [DownloadFile]

        static let allCases: [GoogleFontFamily] = [
            GoogleFontFamily(
                id: "atkinson-hyperlegible",
                familyName: "Atkinson Hyperlegible",
                displayName: "Atkinson Hyperlegible",
                files: [
                    DownloadFile(
                        fileName: "AtkinsonHyperlegible-Regular.ttf",
                        url:
                            "https://raw.githubusercontent.com/google/fonts/main/ofl/atkinsonhyperlegible/AtkinsonHyperlegible-Regular.ttf",
                        style: .normal,
                        weightKind: .standardNormal
                    ),
                    DownloadFile(
                        fileName: "AtkinsonHyperlegible-Bold.ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/atkinsonhyperlegible/AtkinsonHyperlegible-Bold.ttf",
                        style: .normal,
                        weightKind: .standardBold
                    ),
                    DownloadFile(
                        fileName: "AtkinsonHyperlegible-Italic.ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/atkinsonhyperlegible/AtkinsonHyperlegible-Italic.ttf",
                        style: .italic,
                        weightKind: .standardNormal
                    ),
                    DownloadFile(
                        fileName: "AtkinsonHyperlegible-BoldItalic.ttf",
                        url:
                            "https://raw.githubusercontent.com/google/fonts/main/ofl/atkinsonhyperlegible/AtkinsonHyperlegible-BoldItalic.ttf",
                        style: .italic,
                        weightKind: .standardBold
                    ),
                ]
            ),
            GoogleFontFamily(
                id: "ibm-plex-serif",
                familyName: "IBM Plex Serif",
                displayName: "IBM Plex Serif",
                files: [
                    DownloadFile(
                        fileName: "IBMPlexSerif-Regular.ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexserif/IBMPlexSerif-Regular.ttf",
                        style: .normal,
                        weightKind: .standardNormal
                    ),
                    DownloadFile(
                        fileName: "IBMPlexSerif-Bold.ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexserif/IBMPlexSerif-Bold.ttf",
                        style: .normal,
                        weightKind: .standardBold
                    ),
                    DownloadFile(
                        fileName: "IBMPlexSerif-Italic.ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexserif/IBMPlexSerif-Italic.ttf",
                        style: .italic,
                        weightKind: .standardNormal
                    ),
                    DownloadFile(
                        fileName: "IBMPlexSerif-BoldItalic.ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexserif/IBMPlexSerif-BoldItalic.ttf",
                        style: .italic,
                        weightKind: .standardBold
                    ),
                ]
            ),
            GoogleFontFamily(
                id: "lora",
                familyName: "Lora",
                displayName: "Lora",
                files: [
                    DownloadFile(
                        fileName: "Lora[wght].ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/lora/Lora%5Bwght%5D.ttf",
                        style: .normal,
                        weightKind: .variable(range: 200...900)
                    ),
                    DownloadFile(
                        fileName: "Lora-Italic[wght].ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/lora/Lora-Italic%5Bwght%5D.ttf",
                        style: .italic,
                        weightKind: .variable(range: 200...900)
                    ),
                ]
            ),
            GoogleFontFamily(
                id: "literata",
                familyName: "Literata",
                displayName: "Literata",
                files: [
                    DownloadFile(
                        fileName: "Literata[opsz,wght].ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/literata/Literata%5Bopsz%2Cwght%5D.ttf",
                        style: .normal,
                        weightKind: .variable(range: 200...900)
                    ),
                    DownloadFile(
                        fileName: "Literata-Italic[opsz,wght].ttf",
                        url: "https://raw.githubusercontent.com/google/fonts/main/ofl/literata/Literata-Italic%5Bopsz%2Cwght%5D.ttf",
                        style: .italic,
                        weightKind: .variable(range: 200...900)
                    ),
                ]
            ),
        ]
    }

    private(set) var installedFonts: [InstalledFontFamily] = []

    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let metadataKey = "enve.reader.installedFonts.v1"

    private var fontsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Enve/ReaderFonts", isDirectory: true)
    }

    private init() {
        try? fileManager.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        loadInstalledFonts()

        let urlsToRegister = installedFonts.flatMap { $0.files.map { URL(fileURLWithPath: $0.filePath) } }
        Task.detached(priority: .utility) {
            for url in urlsToRegister {
                var error: Unmanaged<CFError>?
                _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            }
        }
    }

    func loadInstalledFonts() {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
            let fonts = try? JSONDecoder().decode([InstalledFontFamily].self, from: data)
        else {
            installedFonts = []
            return
        }

        var validFonts: [InstalledFontFamily] = []
        var removedAny = false

        for family in fonts {
            let resolvedFiles = family.files.map { file -> InstalledFontFile in

                var currentPath = file.filePath
                if !fileManager.fileExists(atPath: currentPath) {
                    let components = URL(fileURLWithPath: currentPath).pathComponents
                    guard components.count >= 2 else { return file }
                    let subfolder = components[components.count - 2]
                    let filename = components[components.count - 1]
                    let rebuilt = fontsDirectory.appendingPathComponent(subfolder).appendingPathComponent(filename).path
                    guard fileManager.fileExists(atPath: rebuilt) else { return file }
                    AppLogger.general.debug(
                        "[ReaderFontLibrary] Remapped stale path fileId=\(DiagnosticLogSanitizer.identifier(for: filename))"
                    )
                    currentPath = rebuilt
                }

                let currentURL = URL(fileURLWithPath: currentPath)
                let currentFilename = currentURL.lastPathComponent
                let sanitizedFilename = Self.sanitizeFontFilename(currentFilename)
                if sanitizedFilename != currentFilename {
                    let sanitizedPath = currentURL.deletingLastPathComponent().appendingPathComponent(sanitizedFilename).path
                    if !fileManager.fileExists(atPath: sanitizedPath) {
                        do {
                            try fileManager.moveItem(atPath: currentPath, toPath: sanitizedPath)
                            AppLogger.general.debug(
                                "[ReaderFontLibrary] Renamed font fileId=\(DiagnosticLogSanitizer.identifier(for: currentFilename)) to make it URL-safe"
                            )
                            currentPath = sanitizedPath
                        } catch {
                            AppLogger.general.error(
                                "[ReaderFontLibrary] Failed to rename font fileId=\(DiagnosticLogSanitizer.identifier(for: currentFilename)): \(error)"
                            )
                        }
                    } else {

                        try? fileManager.removeItem(atPath: currentPath)
                        currentPath = sanitizedPath
                    }
                }

                if currentPath == file.filePath && sanitizedFilename == currentFilename { return file }
                return InstalledFontFile(
                    id: file.id,
                    fileName: sanitizedFilename,
                    filePath: currentPath,
                    style: file.style,
                    weightKind: file.weightKind
                )
            }

            let existingFiles = resolvedFiles.filter { file in
                let exists = fileManager.fileExists(atPath: file.filePath)
                if !exists {
                    AppLogger.general.warning(
                        "[ReaderFontLibrary] Missing font pathId=\(DiagnosticLogSanitizer.identifier(for: file.filePath))"
                    )
                }
                return exists
            }

            if existingFiles.isEmpty {
                AppLogger.general.warning(
                    "[ReaderFontLibrary] Removing stale font familyId=\(DiagnosticLogSanitizer.identifier(for: family.familyName)) - no files exist on disk"
                )
                removedAny = true
            } else if existingFiles.count < family.files.count || existingFiles != family.files {

                if existingFiles.count < family.files.count {
                    AppLogger.general.warning(
                        "[ReaderFontLibrary] Font family '\(family.familyName)' has \(family.files.count - existingFiles.count) missing files"
                    )
                }
                let updatedFamily = InstalledFontFamily(
                    id: family.id,
                    familyName: family.familyName,
                    displayName: family.displayName,
                    source: family.source,
                    files: existingFiles
                )
                validFonts.append(updatedFamily)
                removedAny = true
            } else {
                validFonts.append(family)
            }
        }

        installedFonts = validFonts

        if removedAny {
            persist()
        }
    }

    func reinstallIfNeeded(_ familyName: String) async -> Bool {
        guard let family = fontFamily(named: familyName) else {
            return false
        }

        let allFilesExist = family.files.allSatisfy { fileManager.fileExists(atPath: $0.filePath) }
        if allFilesExist {
            return true
        }

        if family.source == .google {

            if let builtIn = GoogleFontFamily.allCases.first(where: { $0.familyName == familyName }) {
                do {
                    _ = try await installGoogleFont(builtIn)
                    AppLogger.general.debug(
                        "[ReaderFontLibrary] Reinstalled font familyId=\(DiagnosticLogSanitizer.identifier(for: familyName))"
                    )
                    return true
                } catch {
                    AppLogger.general.error(
                        "[ReaderFontLibrary] Failed to reinstall font familyId=\(DiagnosticLogSanitizer.identifier(for: familyName)): \(error)"
                    )
                    return false
                }
            } else {

                do {
                    _ = try await installGoogleFontByName(familyName)
                    AppLogger.general.debug(
                        "[ReaderFontLibrary] Reinstalled font familyId=\(DiagnosticLogSanitizer.identifier(for: familyName))"
                    )
                    return true
                } catch {
                    AppLogger.general.error(
                        "[ReaderFontLibrary] Failed to reinstall font familyId=\(DiagnosticLogSanitizer.identifier(for: familyName)): \(error)"
                    )
                    return false
                }
            }
        }

        AppLogger.general.warning(
            "[ReaderFontLibrary] Cannot reinstall uploaded font familyId=\(DiagnosticLogSanitizer.identifier(for: familyName))"
        )
        return false
    }

    func installGoogleFont(_ font: GoogleFontFamily) async throws -> InstalledFontFamily {
        let familyDirectory = fontsDirectory.appendingPathComponent(font.id, isDirectory: true)
        try fileManager.createDirectory(at: familyDirectory, withIntermediateDirectories: true)

        var files: [InstalledFontFile] = []
        for entry in font.files {
            let destination = familyDirectory.appendingPathComponent(entry.fileName)
            if !fileManager.fileExists(atPath: destination.path) {
                guard let downloadURL = URL(string: entry.url) else {
                    throw NSError(
                        domain: "ReaderFontLibrary",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid font URL: \(entry.url)"]
                    )
                }
                let (data, _) = try await URLSession.shared.data(from: downloadURL)
                try data.write(to: destination, options: .atomic)
            }
            try registerFont(at: destination)
            files.append(
                InstalledFontFile(
                    fileName: entry.fileName,
                    filePath: destination.path,
                    style: entry.style,
                    weightKind: entry.weightKind
                )
            )
        }

        let installed = InstalledFontFamily(
            familyName: font.familyName,
            displayName: font.displayName,
            source: .google,
            files: files
        )
        upsert(installed)
        return installed
    }

    func installGoogleFontByName(_ familyName: String) async throws -> InstalledFontFamily {
        let trimmedName = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw FontInstallError.invalidName
        }

        if let installed = installedFonts.first(where: {
            $0.familyName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            return installed
        }

        if let builtIn = GoogleFontFamily.allCases.first(where: {
            $0.familyName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            return try await installGoogleFont(builtIn)
        }

        let encodedName = trimmedName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedName
        guard let cssURL = URL(string: "https://fonts.googleapis.com/css?family=\(encodedName):400,700,400italic,700italic") else {
            throw FontInstallError.invalidName
        }

        var request = URLRequest(url: cssURL)
        request.timeoutInterval = 20
        request.setValue("Mozilla/4.0", forHTTPHeaderField: "User-Agent")

        let cssData: Data
        let response: URLResponse
        do {
            (cssData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FontInstallError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FontInstallError.networkError("Unexpected response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 400, 404:
            throw FontInstallError.fontNotFound(trimmedName)
        default:
            throw FontInstallError.networkError("HTTP \(httpResponse.statusCode)")
        }

        guard let css = String(data: cssData, encoding: .utf8) else {
            throw FontInstallError.parseError
        }

        let parsedFiles = Self.parseGoogleFontCSS(css)
        guard !parsedFiles.isEmpty else {
            throw FontInstallError.noFilesFound(trimmedName)
        }

        let directoryName =
            "google-"
            + trimmedName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let familyDirectory = fontsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: familyDirectory, withIntermediateDirectories: true)

        var installedFiles: [InstalledFontFile] = []
        for file in parsedFiles {
            let destination = familyDirectory.appendingPathComponent(file.fileName)
            if !fileManager.fileExists(atPath: destination.path) {
                let (data, _) = try await URLSession.shared.data(from: file.url)
                try data.write(to: destination, options: .atomic)
            }
            try registerFont(at: destination)
            installedFiles.append(
                InstalledFontFile(
                    fileName: file.fileName,
                    filePath: destination.path,
                    style: file.style,
                    weightKind: file.weightKind
                )
            )
        }

        let installed = InstalledFontFamily(
            familyName: trimmedName,
            displayName: trimmedName,
            source: .google,
            files: installedFiles
        )
        upsert(installed)
        return installed
    }

    func importFontFile(from sourceURL: URL) throws -> InstalledFontFamily {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }

        let familyDirectory = fontsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: familyDirectory, withIntermediateDirectories: true)

        let sanitizedName = Self.sanitizeFontFilename(sourceURL.lastPathComponent)
        let destination = familyDirectory.appendingPathComponent(sanitizedName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        do {
            try registerFont(at: destination)
        } catch {
            AppLogger.library.warning(
                "[FontImport] System registration failed (font will still work in reader): \(error.localizedDescription)"
            )
        }

        guard let descriptor = CTFontManagerCreateFontDescriptorsFromURL(destination as CFURL) as? [CTFontDescriptor],
            let first = descriptor.first
        else {

            try? fileManager.removeItem(at: familyDirectory)
            throw NSError(
                domain: "ReaderFontLibrary",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected font could not be read. Make sure it is a valid .ttf or .otf file."]
            )
        }

        let attributes = CTFontDescriptorCopyAttributes(first) as NSDictionary
        let familyName = (attributes[kCTFontFamilyNameAttribute] as? String) ?? sourceURL.deletingPathExtension().lastPathComponent

        let installed = InstalledFontFamily(
            familyName: familyName,
            displayName: familyName,
            source: .uploaded,
            files: [
                InstalledFontFile(
                    fileName: sanitizedName,
                    filePath: destination.path,
                    style: .normal,
                    weightKind: .variable(range: 200...900)
                )
            ]
        )
        upsert(installed)
        return installed
    }

    func fontFamily(named familyName: String) -> InstalledFontFamily? {
        installedFonts.first { $0.familyName == familyName }
    }

    func sanitizeFontFamilySelection(_ familyName: String) -> String {
        guard familyName != "Original", familyName != "OpenDyslexic" else {
            return familyName
        }

        return hasUsableFontFamily(named: familyName) ? familyName : "Original"
    }

    func hasUsableFontFamily(named familyName: String) -> Bool {
        guard let family = fontFamily(named: familyName) else {
            return false
        }

        return !fontFaces(for: family).isEmpty
    }

    func invalidReason(for familyName: String) -> String? {
        guard let family = fontFamily(named: familyName) else {
            return nil
        }

        let faces = fontFaces(for: family)
        if !faces.isEmpty {
            return nil
        }

        let missingFiles = family.files.filter {
            !fileManager.fileExists(atPath: $0.filePath) || !fileManager.isReadableFile(atPath: $0.filePath)
        }

        if !missingFiles.isEmpty {
            return "Font files are missing or unreadable."
        }

        return "Readium could not create a usable font face from this font."
    }

    func deleteFont(familyName: String) {
        guard let font = installedFonts.first(where: { $0.familyName == familyName }) else {
            return
        }

        for file in font.files {
            let url = URL(fileURLWithPath: file.filePath)
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        }

        if let firstFile = font.files.first {
            let directory = URL(fileURLWithPath: firstFile.filePath).deletingLastPathComponent()
            try? fileManager.removeItem(at: directory)
        }

        installedFonts.removeAll { $0.familyName == familyName }
        persist()
    }

    var readiumDeclarations: [AnyHTMLFontFamilyDeclaration] {
        installedFonts.compactMap { family in
            let faces = fontFaces(for: family)
            guard !faces.isEmpty else {
                return nil
            }

            return CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: family.familyName),
                fontFaces: faces
            ).eraseToAnyHTMLFontFamilyDeclaration()
        }
    }

    private func upsert(_ font: InstalledFontFamily) {
        installedFonts.removeAll { $0.familyName == font.familyName }
        installedFonts.append(font)
        installedFonts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(installedFonts) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }

    private func fontFaces(for family: InstalledFontFamily) -> [CSSFontFace] {
        family.files.compactMap { file in
            guard fileManager.fileExists(atPath: file.filePath),
                fileManager.isReadableFile(atPath: file.filePath),
                let url = FileURL(path: file.filePath, isDirectory: false)
            else {
                return nil
            }

            switch (file.style, file.weightKind) {
            case (.normal, .standardNormal):
                return CSSFontFace(file: url, style: .normal, weight: .standard(.normal))
            case (.normal, .standardBold):
                return CSSFontFace(file: url, style: .normal, weight: .standard(.bold))
            case (.italic, .standardNormal):
                return CSSFontFace(file: url, style: .italic, weight: .standard(.normal))
            case (.italic, .standardBold):
                return CSSFontFace(file: url, style: .italic, weight: .standard(.bold))
            case (.normal, .variable(let range)):
                return CSSFontFace(file: url, style: .normal, weight: .variable(range))
            case (.italic, .variable(let range)):
                return CSSFontFace(file: url, style: .italic, weight: .variable(range))
            }
        }
    }

    private static func parseGoogleFontCSS(
        _ css: String
    ) -> [(url: URL, fileName: String, style: InstalledFontFile.FaceStyle, weightKind: InstalledFontFile.WeightKind)] {
        guard
            let blockRegex = try? NSRegularExpression(
                pattern: #"@font-face\s*\{[^}]+\}"#,
                options: [.dotMatchesLineSeparators]
            )
        else {
            return []
        }

        let cssRange = NSRange(css.startIndex..<css.endIndex, in: css)
        let blocks = blockRegex.matches(in: css, range: cssRange)

        return blocks.compactMap { match in
            guard let blockRange = Range(match.range, in: css) else {
                return nil
            }
            let block = String(css[blockRange])

            guard let urlMatch = block.range(of: #"url\(([^)]+)\)"#, options: .regularExpression) else {
                return nil
            }

            var urlString = String(block[urlMatch])
                .replacingOccurrences(of: "url(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))

            urlString = urlString.replacingOccurrences(of: "\n", with: "")
            urlString = urlString.replacingOccurrences(of: "\r", with: "")

            guard let url = URL(string: urlString) else {
                return nil
            }

            let style: InstalledFontFile.FaceStyle = block.contains("font-style: italic") ? .italic : .normal
            let weightKind: InstalledFontFile.WeightKind = block.contains("font-weight: 700") ? .standardBold : .standardNormal
            let fileName = url.lastPathComponent.isEmpty ? UUID().uuidString + ".ttf" : url.lastPathComponent

            return (url, fileName, style, weightKind)
        }
    }

    static func sanitizeFontFilename(_ filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let sanitizedBase = base.unicodeScalars.map { scalar -> String in

            let c = scalar.value
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                || c == 0x2D || c == 0x5F || c == 0x28 || c == 0x29
            {
                return String(scalar)
            }
            return "-"
        }.joined()

        let collapsed =
            sanitizedBase
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return ext.isEmpty ? collapsed : "\(collapsed).\(ext)"
    }

    private func registerFont(at url: URL) throws {
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !success,
            let retainedError = error?.takeRetainedValue(),
            CFErrorGetCode(retainedError) != CTFontManagerError.alreadyRegistered.rawValue
        {
            throw retainedError
        }
    }
}
