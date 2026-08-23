import Foundation

final class LocalEbookImporter: @unchecked Sendable {
    static let shared = LocalEbookImporter()
    private init() {}

    enum EbookImportError: LocalizedError {
        case notSupportedOnTVOS

        var errorDescription: String? {
            "Ebook downloading isn't available on Apple TV. Read this book on your iPhone or iPad, or use Read Together."
        }
    }

    var localEbooksRoot: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("Ebooks/local", isDirectory: true)
    }

    var serverEbooksRoot: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("Ebooks", isDirectory: true)
    }

    var remoteReaderCacheRoot: URL {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesURL.appendingPathComponent("ReaderEbooks", isDirectory: true)
    }

    var streamedEpubCacheRoot: URL {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesURL.appendingPathComponent("StreamedEpubs", isDirectory: true)
    }

    var readaloudCacheRoot: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("Ebooks/readaloud", isDirectory: true)
    }

    private static let validEbookExtensions: Set<String> = {
        var exts = Set(EbookFormat.allCases.map { $0.rawValue })
        exts.formUnion(EbookFormat.mobiExtensions)
        return exts
    }()

    private func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "-", options: .regularExpression)
        let collapsed = sanitized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "ebook.epub" : collapsed
    }

    func cachedEbook(forBookId bookId: String) -> URL? {
        let safeId = sanitizeFilename(bookId)
        guard !safeId.isEmpty else { return nil }
        let root = remoteReaderCacheRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return contents.first {
            $0.lastPathComponent.hasPrefix(safeId)
                && Self.validEbookExtensions.contains($0.pathExtension.lowercased())
        }
    }

    func resolveEbookForOverlay(book: Book) -> URL? {
        nil
    }

    func persistedRemoteEbook(forBookId bookId: String) -> URL? {
        nil
    }

    func cachedReadaloudEpub(forBookId bookId: String) -> URL? {
        nil
    }

    private func cachedRemoteEbookURL(preferredFilename: String, bookIdentifier: String?) -> URL {
        let sanitizedName = sanitizeFilename(preferredFilename)
        let fileName: String
        if let bookIdentifier, !bookIdentifier.isEmpty {
            let safeIdentifier = sanitizeFilename(bookIdentifier)
            if safeIdentifier.isEmpty || sanitizedName.hasPrefix(safeIdentifier) {
                fileName = sanitizedName
            } else {
                fileName = "\(safeIdentifier)-\(sanitizedName)"
            }
        } else {
            fileName = sanitizedName
        }
        return remoteReaderCacheRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    func cacheRemoteEbook(tempURL: URL, preferredFilename: String, bookIdentifier: String? = nil) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: remoteReaderCacheRoot, withIntermediateDirectories: true)
        let destinationURL = cachedRemoteEbookURL(preferredFilename: preferredFilename, bookIdentifier: bookIdentifier)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: tempURL, to: destinationURL)
            try? fileManager.removeItem(at: tempURL)
        }
        return destinationURL
    }

    func cacheRemoteEbook(data: Data, preferredFilename: String, bookIdentifier: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: remoteReaderCacheRoot, withIntermediateDirectories: true)
        let destinationURL = cachedRemoteEbookURL(preferredFilename: preferredFilename, bookIdentifier: bookIdentifier)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    func cacheReadaloudEpub(tempURL: URL, bookId: String) throws -> URL {
        throw EbookImportError.notSupportedOnTVOS
    }

    func extractMetadata(from fileURL: URL) async throws -> LocalBookMetadata {
        throw EbookImportError.notSupportedOnTVOS
    }

    func resolveExistingLocalEbookURL(bookIdentifier: String? = nil, ebookFileURL: URL?, filePath: String?) -> URL? {
        let candidates: [URL] = [
            ebookFileURL,
            filePath.flatMap { URL(fileURLWithPath: $0) },
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func resolveExistingLocalEbookURL(ebookFileURL: URL?, filePath: String?) -> URL? {
        resolveExistingLocalEbookURL(bookIdentifier: nil, ebookFileURL: ebookFileURL, filePath: filePath)
    }

    func extractChapters(from fileURL: URL) async throws -> [LocalChapter] {
        []
    }

    func deleteRemoteEbookArtifacts(forBookId bookId: String) throws {}

    func removeReadaloudCache(forBookId bookId: String, stableId: String? = nil) {}

    func migrateToLocal(cachedURL: URL) -> URL? {
        nil
    }

    func persistRemoteEbookForOffline(from sourceURL: URL, preferredFilename: String? = nil, bookIdentifier: String? = nil) throws -> URL {
        throw EbookImportError.notSupportedOnTVOS
    }
}
