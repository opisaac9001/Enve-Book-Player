import Foundation
import Logging
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import UIKit

private let convertedEpubCacheVersion = "v5"

enum EbookImportError: Error {
    case assetRetrievalFailed
    case publicationOpenFailed
    case noValidEbookDetected
    case unsupportedFormat
}

final class LocalEbookImporter: @unchecked Sendable {
    static let shared = LocalEbookImporter()

    private let fileManager = FileManager.default

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

    private init() {
        try? fileManager.createDirectory(at: localEbooksRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: serverEbooksRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: remoteReaderCacheRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: readaloudCacheRoot, withIntermediateDirectories: true)
    }

    func resolveExistingLocalEbookURL(bookIdentifier: String? = nil, ebookFileURL: URL?, filePath: String?) -> URL? {
        let candidates = ebookPathCandidates(bookIdentifier: bookIdentifier, ebookFileURL: ebookFileURL, filePath: filePath)
        return candidates.first(where: isExistingEbook)
    }

    func resolveExistingLocalEbookURL(ebookFileURL: URL?, filePath: String?) -> URL? {
        resolveExistingLocalEbookURL(bookIdentifier: nil, ebookFileURL: ebookFileURL, filePath: filePath)
    }

    private func ebookPathCandidates(bookIdentifier: String?, ebookFileURL: URL?, filePath: String?) -> [URL] {
        var candidates: [URL] = []

        func appendCandidate(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }

        func appendConvertedSourceCandidates(for path: String) {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().lastPathComponent == "ConvertedEbooks" else { return }

            let fileName = url.lastPathComponent
            guard
                let match = fileName.range(
                    of: #"-v\d+\.epub$"#,
                    options: [.regularExpression, .caseInsensitive]
                )
            else {
                return
            }

            let sourceBaseName = String(fileName[..<match.lowerBound])
            guard !sourceBaseName.isEmpty else { return }

            let sourceRoots = [serverEbooksRoot, localEbooksRoot, remoteReaderCacheRoot]
            for root in sourceRoots {
                for ext in EbookFormat.mobiExtensions {
                    appendCandidate(root.appendingPathComponent("\(sourceBaseName).\(ext)", isDirectory: false))
                }
            }
        }

        func appendStoredPath(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            appendConvertedSourceCandidates(for: path)
            appendCandidate(URL(fileURLWithPath: path))

            let nsPath = path as NSString
            let fileName = nsPath.lastPathComponent
            if !fileName.isEmpty {
                appendCandidate(serverEbooksRoot.appendingPathComponent(fileName, isDirectory: false))
                appendCandidate(localEbooksRoot.appendingPathComponent(fileName, isDirectory: false))
                appendCandidate(remoteReaderCacheRoot.appendingPathComponent(fileName, isDirectory: false))
            }

            let marker = "/Documents/Ebooks/"
            if let range = path.range(of: marker) {
                let relative = String(path[range.upperBound...])
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                appendCandidate(
                    docs.appendingPathComponent("Ebooks", isDirectory: true).appendingPathComponent(relative, isDirectory: false)
                )
            }
        }

        appendStoredPath(ebookFileURL?.path)
        appendStoredPath(filePath)
        if let bookIdentifier {
            appendCandidate(persistedRemoteEbook(forBookId: bookIdentifier))
            appendCandidate(cachedEbook(forBookId: bookIdentifier))
        }

        return candidates
    }

    func cacheRemoteEbook(tempURL: URL, preferredFilename: String, bookIdentifier: String? = nil) throws -> URL {
        try ImportLimits.validateImportedMediaFile(tempURL)
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
        guard Int64(data.count) <= ImportLimits.maxImportedMediaFileBytes else {
            throw ImportLimitError.fileTooLarge(
                path: preferredFilename,
                size: Int64(data.count),
                maxSize: ImportLimits.maxImportedMediaFileBytes
            )
        }
        try fileManager.createDirectory(at: remoteReaderCacheRoot, withIntermediateDirectories: true)
        let destinationURL = cachedRemoteEbookURL(preferredFilename: preferredFilename, bookIdentifier: bookIdentifier)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
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

    func cachedEbook(forBookId bookId: String) -> URL? {
        if let persisted = persistedRemoteEbook(forBookId: bookId) {
            return persisted
        }
        return existingRemoteEbook(forBookId: bookId, roots: [remoteReaderCacheRoot])
    }

    func persistedRemoteEbook(forBookId bookId: String) -> URL? {
        existingRemoteEbook(forBookId: bookId, roots: [serverEbooksRoot])
    }

    func persistRemoteEbookForOffline(from sourceURL: URL, preferredFilename: String? = nil, bookIdentifier: String? = nil) throws -> URL {
        try ImportLimits.validateImportedMediaFile(sourceURL)
        try fileManager.createDirectory(at: serverEbooksRoot, withIntermediateDirectories: true)
        let destinationURL = storedRemoteEbookURL(
            root: serverEbooksRoot,
            preferredFilename: preferredFilename ?? sourceURL.lastPathComponent,
            bookIdentifier: bookIdentifier
        )
        if sourceURL == destinationURL {
            return destinationURL
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            if sourceURL.path.hasPrefix(remoteReaderCacheRoot.path) {
                try? fileManager.removeItem(at: sourceURL)
            }
        }

        return destinationURL
    }

    func deleteRemoteEbookArtifacts(forBookId bookId: String) throws {
        if let connectionDirs = try? fileManager.contentsOfDirectory(at: streamedEpubCacheRoot, includingPropertiesForKeys: nil) {
            for connectionDir in connectionDirs {
                guard let bookDirs = try? fileManager.contentsOfDirectory(at: connectionDir, includingPropertiesForKeys: nil) else {
                    continue
                }
                for dir in bookDirs
                where dir.lastPathComponent == "book-\(bookId)" || dir.lastPathComponent.hasPrefix("book-\(bookId)-file-") {
                    try? fileManager.removeItem(at: dir)
                }
            }
        }
        let urls = [persistedRemoteEbook(forBookId: bookId), existingRemoteEbook(forBookId: bookId, roots: [remoteReaderCacheRoot])]
            .compactMap { $0 }
        var lastError: Error?
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
    }

    private static let validEbookExtensions: Set<String> = {
        var exts = Set(EbookFormat.allCases.map { $0.rawValue })
        exts.formUnion(EbookFormat.mobiExtensions)
        return exts
    }()

    private func isExistingEbook(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
            || Self.validEbookExtensions.contains(url.pathExtension.lowercased())
    }

    private func existingRemoteEbook(forBookId bookId: String, roots: [URL]) -> URL? {
        let safeId = sanitizeFilename(bookId)
        guard !safeId.isEmpty else { return nil }
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let contents =
                (try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
            if let match = contents.first(where: {
                $0.lastPathComponent.hasPrefix(safeId)
                    && Self.validEbookExtensions.contains($0.pathExtension.lowercased())
            }) {
                return match
            }
        }
        return nil
    }

    private func storedRemoteEbookURL(root: URL, preferredFilename: String, bookIdentifier: String?) -> URL {
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
        return root.appendingPathComponent(fileName, isDirectory: false)
    }

    func readaloudEpubURL(forBookId bookId: String) -> URL {
        readaloudCacheRoot.appendingPathComponent("\(bookId).epub")
    }

    func cachedReadaloudEpub(forBookId bookId: String) -> URL? {
        let url = readaloudEpubURL(forBookId: bookId)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func resolveEbookForOverlay(book: Book) -> URL? {
        if let readaloud = cachedReadaloudEpub(forBookId: book.id),
            isExistingEbook(readaloud)
        {
            return readaloud
        }
        if let offline = persistedRemoteEbook(forBookId: book.id),
            isExistingEbook(offline)
        {
            return offline
        }
        if let url = book.ebookFileURL, isExistingEbook(url) {
            return url
        }
        return resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.mediaType == .ebook ? book.filePath : nil
        )
    }

    func cacheReadaloudEpub(tempURL: URL, bookId: String) throws -> URL {
        try ImportLimits.validateImportedMediaFile(tempURL)
        try fileManager.createDirectory(at: readaloudCacheRoot, withIntermediateDirectories: true)
        let destURL = readaloudEpubURL(forBookId: bookId)
        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        do {
            try fileManager.moveItem(at: tempURL, to: destURL)
        } catch {
            try fileManager.copyItem(at: tempURL, to: destURL)
            try? fileManager.removeItem(at: tempURL)
        }
        return destURL
    }

    func removeReadaloudCache(forBookId bookId: String, stableId: String? = nil) {
        let epubURL = readaloudEpubURL(forBookId: bookId)
        try? fileManager.removeItem(at: epubURL)
        for key in Set([bookId, stableId].compactMap { $0 }) {
            let overlayDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("enve-overlay")
                .appendingPathComponent(key)
            try? fileManager.removeItem(at: overlayDir)
        }
    }

    func migrateToLocal(cachedURL: URL) -> URL? {
        do {
            try fileManager.createDirectory(at: localEbooksRoot, withIntermediateDirectories: true)
            let dest = localEbooksRoot.appendingPathComponent(cachedURL.lastPathComponent)
            if fileManager.fileExists(atPath: dest.path) {
                return dest
            }
            try fileManager.moveItem(at: cachedURL, to: dest)
            return dest
        } catch {
            AppLogger.network.error("Failed to migrate cached ebook to local: \(error)")
            return nil
        }
    }

    private func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "-", options: .regularExpression)
        let collapsed = sanitized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "ebook.epub" : collapsed
    }

    func extractChapters(from fileURL: URL) async throws -> [LocalChapter] {
        try ImportLimits.validateImportedMediaFile(fileURL)
        try Task.checkCancellation()
        let chapterSourceURL: URL
        if EbookFormat.mobiExtensions.contains(fileURL.pathExtension.lowercased()) {
            chapterSourceURL = try await convertMobiToEpub(fileURL)
        } else {
            chapterSourceURL = fileURL
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        guard let readiumURL = FileURL(url: chapterSourceURL) else {
            throw EbookImportError.assetRetrievalFailed
        }

        let assetResult = await assetRetriever.retrieve(url: readiumURL)
        guard let asset = try? assetResult.get() else {
            throw EbookImportError.assetRetrievalFailed
        }

        let openResult = await publicationOpener.open(asset: asset, allowUserInteraction: false)
        guard let publication = try? openResult.get() else {
            throw EbookImportError.publicationOpenFailed
        }

        let tocLinks = (try? await publication.tableOfContents().get()) ?? []
        let flattenedTOC = flattenLinks(tocLinks)
        let sourceLinks = flattenedTOC.isEmpty ? publication.readingOrder : flattenedTOC

        return sourceLinks.enumerated().map { index, link in
            let cleanedTitle = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = URL(string: link.href)?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            let title = (cleanedTitle?.isEmpty == false ? cleanedTitle : fallbackTitle) ?? "Chapter \(index + 1)"

            let start = TimeInterval(index)

            return LocalChapter(
                id: "ebook-chapter-\(index)-\(link.href)",
                title: title,
                startTime: start,
                endTime: start,
                duration: 0
            )
        }
    }

    func extractMetadata(from fileURL: URL) async throws -> LocalBookMetadata {
        try ImportLimits.validateImportedMediaFile(fileURL)
        return try await ImportLimits.withTimeout(
            seconds: ImportLimits.metadataExtractionTimeoutSeconds,
            operationName: "ebook metadata \(fileURL.lastPathComponent)"
        ) {
            try await self.extractMetadataWithoutTimeout(from: fileURL)
        }
    }

    private func extractMetadataWithoutTimeout(from fileURL: URL) async throws -> LocalBookMetadata {
        try Task.checkCancellation()
        guard let format = EbookFormat.from(fileExtension: fileURL.pathExtension) else {
            throw EbookImportError.unsupportedFormat
        }

        if format == .cbz || format == .cbr {
            return try await ComicArchiveService.shared.extractMetadata(from: fileURL)
        }

        if format.requiresMobiConversion {
            return try extractMobiMetadata(from: fileURL)
        }

        guard format.isReadiumSupported else {
            throw EbookImportError.unsupportedFormat
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        guard let readiumURL = FileURL(url: fileURL) else {
            throw EbookImportError.assetRetrievalFailed
        }

        let assetResult = await assetRetriever.retrieve(url: readiumURL)
        guard let asset = try? assetResult.get() else {
            throw EbookImportError.assetRetrievalFailed
        }

        let openResult = await publicationOpener.open(asset: asset, allowUserInteraction: false)
        guard let publication = try? openResult.get() else {
            throw EbookImportError.publicationOpenFailed
        }

        let smilResources = publication.resources.filterByMediaType(.smil)
        let epub3Features: EPUB3Features? = {
            let hasOverlays = !smilResources.isEmpty
            let isFixed = publication.metadata.layout == .fixed
            guard hasOverlays || isFixed else { return nil }
            return EPUB3Features(
                hasMediaOverlay: hasOverlays,
                hasFixedLayout: isFixed,
                smilFileCount: smilResources.count
            )
        }()

        let title = publication.metadata.title ?? fileURL.deletingPathExtension().lastPathComponent
        let author = publication.metadata.authors.first?.name
        let description = publication.metadata.description
        let publishedDate = publication.metadata.published
        let genres = publication.metadata.subjects.map { $0.name }
        let publisher = publication.metadata.publishers.first?.name
        let language = publication.metadata.languages.first

        let isbn: String? = {
            guard let raw = publication.metadata.identifier else { return nil }
            let cleaned =
                raw
                .replacingOccurrences(of: "urn:isbn:", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "isbn:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "")
            let digits = cleaned.filter { $0.isNumber || $0 == "X" || $0 == "x" }
            if digits.count == 13 || digits.count == 10 { return digits }
            return nil
        }()
        let tocLinks = (try? await publication.tableOfContents().get()) ?? []
        let flattenedTOC = flattenLinks(tocLinks)
        let sourceLinks = flattenedTOC.isEmpty ? publication.readingOrder : flattenedTOC
        let chapters = sourceLinks.enumerated().map { index, link in
            let cleanedTitle = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = URL(string: link.href)?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            let title = (cleanedTitle?.isEmpty == false ? cleanedTitle : fallbackTitle) ?? "Chapter \(index + 1)"
            let start = TimeInterval(index)
            let end = TimeInterval(index + 1)

            return LocalChapter(
                id: "ebook-chapter-\(index)-\(link.href)",
                title: title,
                startTime: start,
                endTime: end,
                duration: max(1, end - start)
            )
        }

        let coverDestURL = fileURL.deletingPathExtension().appendingPathExtension("cover.jpg")
        let coverPath: String? = await {
            if fileManager.fileExists(atPath: coverDestURL.path) {
                return coverDestURL.path
            }

            if format == .epub, let opfCover = await EPUBOPFCoverExtractor.extractCover(epubURL: fileURL) {
                let opfDestURL = fileURL.deletingPathExtension()
                    .appendingPathExtension("cover.\(opfCover.pathExtension)")
                if (try? opfCover.bytes.write(to: opfDestURL)) != nil,
                    fileManager.fileExists(atPath: opfDestURL.path)
                {
                    return opfDestURL.path
                }
            }

            let coverImage = (try? await publication.cover().get()) ?? nil
            if let image = coverImage, let jpegData = image.jpegData(compressionQuality: 0.85) {
                try? jpegData.write(to: coverDestURL)
                return fileManager.fileExists(atPath: coverDestURL.path) ? coverDestURL.path : nil
            }
            return nil
        }()

        return LocalBookMetadata(
            title: title,
            author: author,
            narrator: nil,
            description: description,
            series: nil,
            seriesNumber: nil,
            publishedYear: publishedDate.map { Calendar.current.component(.year, from: $0) },
            genres: genres,
            publisher: publisher,
            isbn: isbn,
            asin: nil,
            duration: nil,
            chapters: chapters,
            coverImagePath: coverPath,
            language: language,
            epub3Features: epub3Features
        )
    }

    func convertedEpubURL(for mobiURL: URL) -> URL {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let convertedRoot = cachesURL.appendingPathComponent("ConvertedEbooks", isDirectory: true)
        try? fileManager.createDirectory(at: convertedRoot, withIntermediateDirectories: true)
        let baseName = mobiURL.deletingPathExtension().lastPathComponent
        return convertedRoot.appendingPathComponent(baseName + "-" + convertedEpubCacheVersion + ".epub")
    }

    func cachedConvertedEpub(for mobiURL: URL) -> URL? {
        let url = convertedEpubURL(for: mobiURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let srcDate = (try? mobiURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            let dstDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            srcDate > dstDate
        {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return url
    }

    func convertMobiToEpub(_ mobiURL: URL) async throws -> URL {
        try ImportLimits.validateWholeFileRead(mobiURL)
        if let cached = cachedConvertedEpub(for: mobiURL) {
            AppLogger.network.debug(
                "Using cached converted EPUB \(DiagnosticLogSanitizer.fileDescriptor(for: mobiURL))"
            )
            return cached
        }

        let outputURL = convertedEpubURL(for: mobiURL)
        AppLogger.network.debug("Converting MOBI \(DiagnosticLogSanitizer.fileDescriptor(for: mobiURL))")
        try await MobiConverter.convert(mobiURL: mobiURL, outputURL: outputURL)
        AppLogger.network.debug("Conversion complete \(DiagnosticLogSanitizer.fileDescriptor(for: outputURL))")
        return outputURL
    }

    private func extractMobiMetadata(from fileURL: URL) throws -> LocalBookMetadata {
        let meta = try MobiConverter.extractMetadata(from: fileURL)
        return LocalBookMetadata(
            title: meta.title,
            author: meta.author,
            narrator: nil,
            description: meta.description,
            series: nil,
            seriesNumber: nil,
            publishedYear: meta.publishedYear,
            genres: nil,
            publisher: meta.publisher,
            isbn: nil,
            asin: nil,
            duration: nil,
            chapters: nil,
            coverImagePath: nil,
            language: meta.language,
            epub3Features: nil
        )
    }

    func copyToCanonicalLocation(_ fileURL: URL) throws -> URL {
        try ImportLimits.validateImportedMediaFile(fileURL)
        let canonical = localEbooksRoot

        if fileURL.path.hasPrefix(canonical.path) {
            return fileURL
        }

        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)

        let destURL = uniqueDestinationURL(for: canonical.appendingPathComponent(fileURL.lastPathComponent))
        do {
            try fileManager.moveItem(at: fileURL, to: destURL)
        } catch {
            try fileManager.copyItem(at: fileURL, to: destURL)
            try? fileManager.removeItem(at: fileURL)
        }
        return destURL
    }

    private func uniqueDestinationURL(for desired: URL) -> URL {
        guard fileManager.fileExists(atPath: desired.path) else { return desired }

        let dir = desired.deletingLastPathComponent()
        let base = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension
        var counter = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func flattenLinks(_ links: [Link]) -> [Link] {
        links.flatMap { link in
            [link] + flattenLinks(link.children)
        }
    }

}
