import Foundation
import Logging
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer

@MainActor
final class ReaderPublicationSession {
    struct Opened {
        let publication: Publication
        let fileURL: URL?
    }

    enum Resolution {
        case streamed
        case file(URL)
        case downloadFailed(Error)
        case notFound
        case cancelled
    }

    private let book: Book
    private let providerResolver: any LibraryProviderResolving
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    private(set) var publication: Publication?
    private(set) var fileURL: URL?
    private var streaming: GrimmoryEpubStreamingSession?
    private var openTask: Task<Void, Never>?
    private var streamedPositionsTask: Task<Void, Never>?

    var isStreaming: Bool { streaming != nil }

    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }

    init(book: Book, providerResolver: any LibraryProviderResolving) {
        self.book = book
        self.providerResolver = providerResolver
        let httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            onCreatePublication: TokenSearchInstaller.publicationTransform
        )
    }

    deinit {
        openTask?.cancel()
        streamedPositionsTask?.cancel()
    }

    func begin(_ operation: @escaping () async -> Void) {
        openTask = Task { await operation() }
    }

    func cleanup() {
        openTask?.cancel()
        openTask = nil
        streamedPositionsTask?.cancel()
        streamedPositionsTask = nil
        streaming = nil
    }

    // Streamed EPUBs open inside resolution so a failed streamed open still falls through to the download path.
    func resolveAsset(
        openStreamed: (GrimmoryEpubStreamingSession) async throws -> Void
    ) async -> Resolution {
        var resolvedURL = existingLocalAssetURL()

        if resolvedURL == nil || !(FileManager.default.fileExists(atPath: resolvedURL?.path ?? "")) {
            if GrimmoryEpubStreaming.isEligible(book) {
                do {
                    let session = try await GrimmoryEpubStreaming.makeSession(
                        for: book,
                        providerResolver: providerResolver
                    )
                    try Task.checkCancellation()
                    streaming = session
                    try await openStreamed(session)
                    return .streamed
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    streaming = nil
                    AppLogger.library.info(
                        "Grimmory EPUB streaming unavailable bookDiagnosticID=\(bookDiagnosticID); falling back: \(error.localizedDescription)"
                    )
                }
            }
            if book.source != .local, !book.isReadAloudBook {
                do {
                    let downloadedURL = try await UnifiedDownloadService.shared.prepareReaderAsset(for: book)
                    try Task.checkCancellation()
                    resolvedURL = downloadedURL
                    fileURL = downloadedURL
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .downloadFailed(error)
                }
            }

            if resolvedURL == nil || !(FileManager.default.fileExists(atPath: resolvedURL?.path ?? "")) {
                return .notFound
            }
        }

        guard let url = resolvedURL else { return .notFound }
        fileURL = url
        return .file(url)
    }

    func open(at url: URL) async throws -> Opened {
        fileURL = url
        guard let readiumURL = FileURL(url: url) else {
            throw ClassicReaderError.invalidURL(url.path)
        }
        let asset = try await assetRetriever.retrieve(url: readiumURL).get()
        let publication = try await open(asset: asset)
        return Opened(publication: publication, fileURL: url)
    }

    func openStreamed(_ session: GrimmoryEpubStreamingSession) async throws -> Opened {
        let asset = Asset.container(
            ContainerAsset(
                container: StreamedGrimmoryEpubContainer(session: session),
                format: Format(specifications: .zip, .epub, mediaType: .epub, fileExtension: "epub")
            )
        )
        let publication = try await open(asset: asset)
        return Opened(publication: publication, fileURL: nil)
    }

    func scheduleStreamedPositions(apply: @escaping (Publication, [[Locator]]) async -> Void) {
        streamedPositionsTask?.cancel()
        guard let streaming, let publication else { return }
        streamedPositionsTask = Task {
            await streaming.prefetchAllResources()
            guard !Task.isCancelled else { return }
            let positionsByReadingOrder = (try? await publication.positionsByReadingOrder().get()) ?? []
            guard !Task.isCancelled else { return }
            await apply(publication, positionsByReadingOrder)
        }
    }

    func foliateSource() throws -> FoliateBookSource {
        if let streaming {
            return .streamed(streaming)
        }
        guard let fileURL else {
            throw ClassicReaderError.fileNotFound(nil)
        }
        return .file(fileURL, fileExtension: fileURL.pathExtension)
    }

    func discardUnreadableAsset(at fileURL: URL) {
        let importer = LocalEbookImporter.shared
        guard Self.isDiscardableAsset(
            at: fileURL,
            source: book.source,
            managedRoots: [importer.serverEbooksRoot, importer.remoteReaderCacheRoot]
        ) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func isDiscardableAsset(
        at fileURL: URL,
        source: Book.BookSource,
        managedRoots: [URL]
    ) -> Bool {
        guard source != .local else { return false }
        let path = fileURL.standardizedFileURL.path
        return managedRoots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    private func open(asset: Asset) async throws -> Publication {
        let publication = try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
        self.publication = publication
        return publication
    }

    private func existingLocalAssetURL() -> URL? {
        if book.epub3Features?.hasMediaOverlay == true,
            let cached = LocalEbookImporter.shared.cachedReadaloudEpub(forBookId: book.id)
        {
            return cached
        }
        if #available(iOS 26.0, *),
            let audiobook = EbookAudiobookLinker.shared.linkedAudiobook(for: book),
            let narrated = StoryAlignService.shared.cachedNarratedEpubURL(ebook: book, audiobook: audiobook)
        {
            return narrated
        }
        return LocalEbookImporter.shared.resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.filePath
        )
    }
}
