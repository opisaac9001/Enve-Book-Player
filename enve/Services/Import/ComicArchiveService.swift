import Foundation
import ReadiumZIPFoundation
import UnrarKit

enum ComicReadingDirection: Sendable {
    case leftToRight
    case rightToLeft
}

final class ComicArchiveService: @unchecked Sendable {
    static let shared = ComicArchiveService()

    private let fileManager = FileManager.default
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "avif"]

    private let lock = NSLock()
    private var inFlightExtractions: [String: Task<[URL], any Error>] = [:]

    private init() {}

    func extractedPages(from archiveURL: URL, bookId: String) async throws -> [URL] {
        let existing: Task<[URL], any Error>? = lock.withLock { inFlightExtractions[bookId] }
        if let existing {
            return try await existing.value
        }

        let archiveURL = archiveURL
        let task = Task.detached(priority: .userInitiated) { [self] in
            try await self.performExtraction(from: archiveURL, bookId: bookId)
        }

        lock.withLock { inFlightExtractions[bookId] = task }
        do {
            let pages = try await task.value
            _ = lock.withLock { inFlightExtractions.removeValue(forKey: bookId) }
            return pages
        } catch {
            _ = lock.withLock { inFlightExtractions.removeValue(forKey: bookId) }
            throw error
        }
    }

    private func performExtraction(from archiveURL: URL, bookId: String) async throws -> [URL] {
        let extractionDirectory = try extractionDirectory(for: bookId)
        let manifestURL = extractionDirectory.appendingPathComponent("manifest.json")
        let currentSignature = try sourceSignature(for: archiveURL)

        if let cachedManifest = try? loadManifest(from: manifestURL),
            cachedManifest == currentSignature
        {
            let cachedPages = extractedImageURLs(in: extractionDirectory)
            if !cachedPages.isEmpty {
                return cachedPages
            }
        }

        if fileManager.fileExists(atPath: extractionDirectory.path) {
            try? fileManager.removeItem(at: extractionDirectory)
        }
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

        let treatAsRAR = isRARArchive(at: archiveURL)

        if treatAsRAR {
            let pages = try extractRARPages(from: archiveURL, to: extractionDirectory)
            if !pages.isEmpty {
                try saveManifest(currentSignature, to: manifestURL)
                return pages
            }
        } else {
            do {
                let pages = try await extractZIPPages(from: archiveURL, to: extractionDirectory)
                if !pages.isEmpty {
                    try saveManifest(currentSignature, to: manifestURL)
                    return pages
                }
            } catch {
                throw error
            }
        }

        throw ComicArchiveError.noImagesFound(archiveURL.lastPathComponent)
    }

    private func extractZIPPages(from archiveURL: URL, to extractionDirectory: URL) async throws -> [URL] {
        let archive = try await Archive(url: archiveURL, accessMode: .read)

        let imageEntries = try await archive.entries()
            .filter { entry in
                guard entry.type == .file else { return false }
                let path = entry.path.lowercased()
                guard !path.hasPrefix("__macosx/") else { return false }
                return imageExtensions.contains((path as NSString).pathExtension)
            }
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        guard !imageEntries.isEmpty else {
            return []
        }

        var extractedPages: [URL] = []
        for (index, entry) in imageEntries.enumerated() {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let sanitizedName = sanitizeFilename((entry.path as NSString).lastPathComponent)
            let outputURL = extractionDirectory.appendingPathComponent(
                String(format: "%05d-%@", index, sanitizedName.isEmpty ? "page.\(ext)" : sanitizedName)
            )
            _ = try await archive.extract(entry, to: outputURL)
            extractedPages.append(outputURL)
        }

        return extractedPages
    }

    private func isRARArchive(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 7), header.count >= 7 else { return false }
        return header[0] == 0x52 && header[1] == 0x61 && header[2] == 0x72
            && header[3] == 0x21 && header[4] == 0x1A && header[5] == 0x07
    }

    private func extractRARPages(from archiveURL: URL, to extractionDirectory: URL) throws -> [URL] {
        let rar = RARArchive(url: archiveURL)
        let entries = try rar.listEntries()

        let imageEntries =
            entries
            .filter { entry in
                guard !entry.isDirectory else { return false }
                guard isSafeEntryPath(entry.fileName) else { return false }
                let name = entry.fileName.lowercased()
                guard !name.hasPrefix("__macosx/") else { return false }
                return imageExtensions.contains((name as NSString).pathExtension)
            }
            .sorted { lhs, rhs in
                lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }

        guard !imageEntries.isEmpty else { return [] }

        let tempExtract = extractionDirectory.appendingPathComponent("_raw", isDirectory: true)
        try FileManager.default.createDirectory(at: tempExtract, withIntermediateDirectories: true)
        try rar.extractAll(to: tempExtract.path)

        var extractedPages: [URL] = []
        for (index, entry) in imageEntries.enumerated() {
            let ext = (entry.fileName as NSString).pathExtension.lowercased()
            let sanitizedName = sanitizeFilename((entry.fileName as NSString).lastPathComponent)
            let outputName = String(format: "%05d-%@", index, sanitizedName.isEmpty ? "page.\(ext)" : sanitizedName)
            let outputURL = extractionDirectory.appendingPathComponent(outputName)
            let sourceURL = extractedSourceURL(in: tempExtract, for: entry.fileName)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try FileManager.default.moveItem(at: sourceURL, to: outputURL)
                extractedPages.append(outputURL)
            }
        }

        try? FileManager.default.removeItem(at: tempExtract)
        return extractedPages
    }

    func readingDirection(from archiveURL: URL) async -> ComicReadingDirection? {
        let data: Data?
        if isRARArchive(at: archiveURL) {
            data = try? readComicInfoFromRAR(archiveURL: archiveURL)
        } else {
            data = try? await readComicInfoFromZIP(archiveURL: archiveURL)
        }

        guard let data else { return nil }
        return parseMangaDirection(fromComicInfoXML: data)
    }

    private func readComicInfoFromZIP(archiveURL: URL) async throws -> Data? {
        let archive = try await Archive(url: archiveURL, accessMode: .read)
        let entry = try await archive.entries()
            .first { entry in
                guard entry.type == .file else { return false }
                guard isSafeEntryPath(entry.path) else { return false }
                let lower = entry.path.lowercased()
                guard !lower.hasPrefix("__macosx/") else { return false }
                return (lower as NSString).lastPathComponent == "comicinfo.xml"
            }
        guard let entry else { return nil }

        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("comicinfo-\(UUID().uuidString).xml")
        defer { try? fileManager.removeItem(at: tempURL) }
        _ = try await archive.extract(entry, to: tempURL)
        return try? Data(contentsOf: tempURL)
    }

    private func readComicInfoFromRAR(archiveURL: URL) throws -> Data? {
        let rar = RARArchive(url: archiveURL)
        let entries = try rar.listEntries()
        guard
            let entry = entries.first(where: { entry in
                guard !entry.isDirectory, isSafeEntryPath(entry.fileName) else { return false }
                let lower = entry.fileName.lowercased()
                guard !lower.hasPrefix("__macosx/") else { return false }
                return (lower as NSString).lastPathComponent == "comicinfo.xml"
            })
        else { return nil }
        return try rar.extractData(fromFile: entry.fileName)
    }

    private func parseMangaDirection(fromComicInfoXML data: Data) -> ComicReadingDirection? {
        let parser = XMLParser(data: data)
        let delegate = MangaElementParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        switch delegate.value?.lowercased() {
        case "yesandrighttoleft": return .rightToLeft
        case "yes", "no": return .leftToRight
        default: return nil
        }
    }

    func extractMetadata(from archiveURL: URL) async throws -> LocalBookMetadata {
        let rawName = archiveURL.deletingPathExtension().lastPathComponent
        let title = Self.stripIdPrefix(from: rawName)
        let bookId = rawName

        let coverPath: String?
        let pageCount: Int
        let existingDir = try extractionDirectory(for: bookId)
        let cachedPages = extractedImageURLs(in: existingDir)
        if !cachedPages.isEmpty {
            coverPath = cachedPages.first?.path
            pageCount = cachedPages.count
        } else {
            coverPath = try await extractCoverOnly(from: archiveURL, bookId: bookId)
            pageCount = 1
        }

        let chapters = (0..<pageCount).map { index in
            LocalChapter(
                id: "cbz-page-\(index)",
                title: "Page \(index + 1)",
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1),
                duration: 1
            )
        }

        return LocalBookMetadata(
            title: title,
            chapters: chapters,
            coverImagePath: coverPath
        )
    }

    private func extractCoverOnly(from archiveURL: URL, bookId: String) async throws -> String? {
        let dir = try extractionDirectory(for: bookId)

        if isRARArchive(at: archiveURL),
            let coverURL = try? extractFirstRARImage(from: archiveURL, to: dir)
        {
            return coverURL.path
        }

        if let coverURL = try? await extractFirstZIPImage(from: archiveURL, to: dir) {
            return coverURL.path
        }

        return nil
    }

    private func extractFirstZIPImage(from archiveURL: URL, to extractionDirectory: URL) async throws -> URL? {
        let archive = try await Archive(url: archiveURL, accessMode: .read)
        let firstImage = try await archive.entries()
            .filter { entry in
                guard entry.type == .file else { return false }
                guard isSafeEntryPath(entry.path) else { return false }
                let path = entry.path.lowercased()
                guard !path.hasPrefix("__macosx/") else { return false }
                return imageExtensions.contains((path as NSString).pathExtension)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .first

        guard let entry = firstImage else { return nil }
        let ext = (entry.path as NSString).pathExtension.lowercased()
        let sanitizedName = sanitizeFilename((entry.path as NSString).lastPathComponent)
        let outputURL = extractionDirectory.appendingPathComponent(
            String(format: "%05d-%@", 0, sanitizedName.isEmpty ? "page.\(ext)" : sanitizedName)
        )
        _ = try await archive.extract(entry, to: outputURL)
        return outputURL
    }

    private func extractFirstRARImage(from archiveURL: URL, to extractionDirectory: URL) throws -> URL? {
        let rar = RARArchive(url: archiveURL)
        let entries = try rar.listEntries()
        let firstImage =
            entries
            .filter { entry in
                guard !entry.isDirectory else { return false }
                guard isSafeEntryPath(entry.fileName) else { return false }
                let name = entry.fileName.lowercased()
                guard !name.hasPrefix("__macosx/") else { return false }
                return imageExtensions.contains((name as NSString).pathExtension)
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            .first

        guard let entry = firstImage else { return nil }
        let ext = (entry.fileName as NSString).pathExtension.lowercased()
        let sanitizedName = sanitizeFilename((entry.fileName as NSString).lastPathComponent)
        let outputName = String(format: "%05d-%@", 0, sanitizedName.isEmpty ? "page.\(ext)" : sanitizedName)
        let outputURL = extractionDirectory.appendingPathComponent(outputName)
        let data = try rar.extractData(fromFile: entry.fileName)
        try data.write(to: outputURL, options: [.atomic])
        return outputURL
    }

    private func extractionDirectory(for bookId: String) throws -> URL {
        guard let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ComicArchiveError.cacheDirectoryUnavailable
        }

        let directory =
            cachesDirectory
            .appendingPathComponent("ComicPages", isDirectory: true)
            .appendingPathComponent(sanitizeFilename(bookId), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func extractedImageURLs(in directory: URL) -> [URL] {
        let contents =
            (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return
            contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func pageTitle(for pageURL: URL, index: Int) -> String {
        let baseName = pageURL.deletingPathExtension().lastPathComponent
        if let separatorIndex = baseName.firstIndex(of: "-") {
            let cleaned = String(baseName[baseName.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return "Page \(index + 1)"
    }

    static func stripIdPrefix(from name: String) -> String {
        guard let dashIndex = name.firstIndex(of: "-") else { return name }
        let prefix = String(name[name.startIndex..<dashIndex])
        guard prefix.count >= 5,
            prefix.allSatisfy({ $0.isLetter || $0.isNumber }),
            !prefix.allSatisfy(\.isNumber)
        else {
            return name
        }
        let remainder = String(name[name.index(after: dashIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? name : stripIdPrefix(from: remainder)
    }

    private func sanitizeFilename(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")
        let cleaned = value.components(separatedBy: invalidCharacters).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractedSourceURL(in directory: URL, for entryPath: String) -> URL {
        entryPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(directory) { partialResult, component in
                partialResult.appendingPathComponent(String(component), isDirectory: false)
            }
    }

    private func isSafeEntryPath(_ path: String) -> Bool {
        if path.isEmpty || path.contains("\0") { return false }
        if path.hasPrefix("/") || path.hasPrefix("\\") { return false }
        let segments = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        for segment in segments where segment == ".." {
            return false
        }
        return true
    }

    private func sourceSignature(for url: URL) throws -> ArchiveManifest {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ArchiveManifest(
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    private func saveManifest(_ manifest: ArchiveManifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    private func loadManifest(from url: URL) throws -> ArchiveManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ArchiveManifest.self, from: data)
    }
}

private struct ArchiveManifest: Codable, Equatable, Sendable {
    let modifiedAt: TimeInterval
    let fileSize: Int64
}

private final class MangaElementParser: NSObject, XMLParserDelegate {
    private(set) var value: String?
    private var capturing = false
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName.caseInsensitiveCompare("Manga") == .orderedSame {
            capturing = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.caseInsensitiveCompare("Manga") == .orderedSame {
            value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            capturing = false
            parser.abortParsing()
        }
    }
}

private enum ComicArchiveError: LocalizedError {
    case cacheDirectoryUnavailable
    case invalidArchive(String)
    case noImagesFound(String)

    var errorDescription: String? {
        switch self {
        case .cacheDirectoryUnavailable:
            return "Comic page cache directory is unavailable"
        case .invalidArchive(let path):
            return "Could not open comic archive: \(path)"
        case .noImagesFound(let name):
            return "No readable comic pages found in \(name)"
        }
    }
}
