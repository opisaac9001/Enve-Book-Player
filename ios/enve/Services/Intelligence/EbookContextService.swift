import Foundation
import Logging
import PDFKit
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer

enum EbookContextError: LocalizedError {
    case missingFile
    case unsupportedFormat
    case emptyText

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "Download this ebook before asking Enve Librarian."
        case .unsupportedFormat:
            return "Enve Librarian can answer from text ebooks and PDFs. Image-only books are not supported yet."
        case .emptyText:
            return "Enve could not find readable text in this ebook."
        }
    }
}

@MainActor
@Observable
final class EbookContextService {
    static let shared = EbookContextService()

    private(set) var buildingBookIds = Set<String>()
    private(set) var progressByBook: [String: Double] = [:]
    private(set) var statusTextByBook: [String: String] = [:]

    @ObservationIgnored private let store = EbookContextStore.shared

    private init() {}

    func isBuilding(bookStableId: String) -> Bool {
        buildingBookIds.contains(bookStableId)
    }

    func progress(for bookStableId: String) -> Double {
        progressByBook[bookStableId] ?? 0
    }

    func statusText(for bookStableId: String) -> String? {
        statusTextByBook[bookStableId]
    }

    func prepareContext(for book: Book) async throws {
        guard book.mediaType == .ebook else { return }
        let stableId = book.stableId
        if let context = store.loadContext(bookStableId: stableId), !context.chunks.isEmpty {
            return
        }
        guard !buildingBookIds.contains(stableId) else { return }

        buildingBookIds.insert(stableId)
        progressByBook[stableId] = 0
        statusTextByBook[stableId] = "Preparing ebook text"
        store.markGenerating(bookStableId: stableId)

        do {
            let chunks = try await buildContext(for: book)
            guard !chunks.isEmpty else { throw EbookContextError.emptyText }
            try store.saveContext(bookStableId: stableId, chunks: chunks)
            progressByBook[stableId] = 1
            statusTextByBook[stableId] = nil
            buildingBookIds.remove(stableId)
        } catch {
            store.markFailed(bookStableId: stableId, message: error.localizedDescription)
            statusTextByBook[stableId] = error.localizedDescription
            buildingBookIds.remove(stableId)
            throw error
        }
    }

    private func buildContext(for book: Book) async throws -> [EbookContextChunk] {
        let fileURL = try await resolvedEbookURL(for: book)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw EbookContextError.unsupportedFormat
        }

        let ext = fileURL.pathExtension.lowercased()
        if ext == EbookFormat.pdf.rawValue {
            return try buildPDFContext(book: book, fileURL: fileURL)
        }
        if ext == EbookFormat.cbz.rawValue || ext == EbookFormat.cbr.rawValue {
            throw EbookContextError.unsupportedFormat
        }
        if EbookFormat.mobiExtensions.contains(ext) {
            do {
                let epubURL = try await LocalEbookImporter.shared.convertMobiToEpub(fileURL)
                return try await buildEPUBContext(book: book, fileURL: epubURL)
            } catch {
                let html = try await MobiConverter.extractHTMLForWebKit(mobiURL: fileURL)
                return [makeSingleChunk(book: book, title: book.title, href: nil, text: plainText(fromHTML: html))]
            }
        }
        guard ext.isEmpty || ext == EbookFormat.epub.rawValue else {
            throw EbookContextError.unsupportedFormat
        }
        return try await buildEPUBContext(book: book, fileURL: fileURL)
    }

    private func resolvedEbookURL(for book: Book) async throws -> URL {
        let currentBook =
            AppState.shared.bookInMemory(uniqueId: book.uniqueId)
            ?? AppState.shared.bookInMemory(stableId: book.stableId)
            ?? book

        if currentBook.epub3Features?.hasMediaOverlay == true,
            let cached = LocalEbookImporter.shared.cachedReadaloudEpub(forBookId: currentBook.id)
        {
            return cached
        }

        if #available(iOS 26.0, *),
            let audiobook = EbookAudiobookLinker.shared.linkedAudiobook(for: currentBook),
            let narrated = StoryAlignService.shared.cachedNarratedEpubURL(ebook: currentBook, audiobook: audiobook)
        {
            return narrated
        }

        if let local = LocalEbookImporter.shared.resolveExistingLocalEbookURL(
            bookIdentifier: currentBook.id,
            ebookFileURL: currentBook.ebookFileURL,
            filePath: currentBook.filePath
        ) {
            return local
        }

        guard currentBook.source != .local,
            let provider = AppState.shared.providerConnections.capability(EbookDownloadProvider.self, for: currentBook)
        else {
            throw EbookContextError.missingFile
        }

        let downloaded = try await provider.downloadEbook(for: currentBook, onProgress: nil)
        AppState.shared.mutateBook(uniqueId: currentBook.uniqueId) { $0.ebookFileURL = downloaded }
        return downloaded
    }

    private func buildEPUBContext(book: Book, fileURL: URL) async throws -> [EbookContextChunk] {
        statusTextByBook[book.stableId] = "Reading EPUB text"

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
            throw EbookContextError.missingFile
        }

        let asset = try await assetRetriever.retrieve(url: readiumURL).get()
        let publication = try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
        let tocLinks = flattenLinks((try? await publication.tableOfContents().get()) ?? [])
        let positionsByReadingOrder = (try? await publication.positionsByReadingOrder().get()) ?? []
        let readingOrder = publication.readingOrder
        guard !readingOrder.isEmpty else { throw EbookContextError.emptyText }

        var drafts: [DraftChunk] = []
        for (index, link) in readingOrder.enumerated() {
            try Task.checkCancellation()
            progressByBook[book.stableId] = Double(index) / Double(max(readingOrder.count, 1))

            guard let resource = publication.get(link) else { continue }
            let data: Data
            do {
                nonisolated(unsafe) let unsafeResource = resource
                data = try await unsafeResource.read().get()
            } catch {
                AppLogger.general.warning("Failed to read ebook resource \(link.href): \(error.localizedDescription)")
                continue
            }

            let raw =
                String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let text = plainText(fromHTML: raw)
            guard text.count > 20 else { continue }

            let positions = positionsByReadingOrder.indices.contains(index) ? positionsByReadingOrder[index] : []
            let fallbackStart = Double(index) / Double(max(readingOrder.count, 1))
            let fallbackEnd = Double(index + 1) / Double(max(readingOrder.count, 1))
            let start = clampedProgress(positions.first?.locations.totalProgression ?? fallbackStart)
            let end = clampedProgress(positions.last?.locations.totalProgression ?? fallbackEnd)

            drafts.append(
                DraftChunk(
                    title: title(for: link, tocLinks: tocLinks, fallbackIndex: index),
                    href: link.href,
                    index: index,
                    startProgress: start,
                    endProgress: max(end, start),
                    text: text
                )
            )
        }

        return finalizedChunks(from: drafts, book: book)
    }

    private func buildPDFContext(book: Book, fileURL: URL) throws -> [EbookContextChunk] {
        statusTextByBook[book.stableId] = "Reading PDF text"
        guard let document = PDFDocument(url: fileURL) else {
            throw EbookContextError.missingFile
        }

        let pageCount = max(document.pageCount, 1)
        var chunks: [EbookContextChunk] = []
        for index in 0..<pageCount {
            progressByBook[book.stableId] = Double(index) / Double(pageCount)
            guard let page = document.page(at: index) else { continue }
            let text = normalizeWhitespace(page.string ?? "")
            guard text.count > 20 else { continue }

            chunks.append(
                EbookContextChunk(
                    id: "\(book.stableId)-pdf-\(index)",
                    bookStableId: book.stableId,
                    title: "Page \(index + 1)",
                    href: nil,
                    index: index,
                    startProgress: Double(index) / Double(pageCount),
                    endProgress: Double(index + 1) / Double(pageCount),
                    text: text
                )
            )
        }
        return chunks
    }

    private func makeSingleChunk(book: Book, title: String?, href: String?, text: String) -> EbookContextChunk {
        EbookContextChunk(
            id: "\(book.stableId)-text-0",
            bookStableId: book.stableId,
            title: title,
            href: href,
            index: 0,
            startProgress: 0,
            endProgress: 1,
            text: text
        )
    }

    private func finalizedChunks(from drafts: [DraftChunk], book: Book) -> [EbookContextChunk] {
        let sorted = drafts.sorted { $0.startProgress < $1.startProgress }
        return sorted.enumerated().map { outputIndex, draft in
            let nextStart = sorted.indices.contains(outputIndex + 1) ? sorted[outputIndex + 1].startProgress : 1
            let end = max(draft.endProgress, min(1, nextStart), draft.startProgress + 0.0001)
            return EbookContextChunk(
                id: "\(book.stableId)-epub-\(draft.index)",
                bookStableId: book.stableId,
                title: draft.title,
                href: draft.href,
                index: draft.index,
                startProgress: draft.startProgress,
                endProgress: min(1, end),
                text: draft.text
            )
        }
    }

    private func title(for link: ReadiumShared.Link, tocLinks: [ReadiumShared.Link], fallbackIndex: Int) -> String {
        let href = normalizedHref(link.href)
        if let tocTitle = tocLinks.first(where: { tocLink in
            let tocHref = normalizedHref(tocLink.href)
            return tocHref == href || tocHref.hasSuffix(href) || href.hasSuffix(tocHref)
        })?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !tocTitle.isEmpty {
            return tocTitle
        }
        if let linkTitle = link.title?.trimmingCharacters(in: .whitespacesAndNewlines), !linkTitle.isEmpty {
            return linkTitle
        }
        let fallback = URL(string: link.href)?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        return fallback?.isEmpty == false ? fallback! : "Section \(fallbackIndex + 1)"
    }

    private func flattenLinks(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] {
        links.flatMap { [$0] + flattenLinks($0.children) }
    }

    private func normalizedHref(_ href: String) -> String {
        href.components(separatedBy: "#").first ?? href
    }

    private func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(p|div|section|article|h[1-6]|li|blockquote)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        return normalizeWhitespace(text)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return decoded
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private struct DraftChunk {
        let title: String
        let href: String?
        let index: Int
        let startProgress: Double
        let endProgress: Double
        let text: String
    }
}
