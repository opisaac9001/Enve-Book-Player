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
    private var cacheOwner = UUID().uuidString
    private let preparationOwner: String?

    var isStreaming: Bool { streaming != nil }
    var hasLocalAsset: Bool { existingLocalAssetURL() != nil }

    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }

    private let profileSession: ProfileSession

    init(book: Book, providerResolver: any LibraryProviderResolving, profileSession: ProfileSession = .owner) {
        self.profileSession = profileSession
        preparationOwner = profileSession.readingCache.claimPreparation(for: book.uniqueId)
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

    func retire() async {
        let tasks = [openTask, streamedPositionsTask]
        cleanup()
        for task in tasks { await task?.value }
    }

    func cleanup() {
        let opening = openTask
        openTask?.cancel()
        openTask = nil
        streamedPositionsTask?.cancel()
        streamedPositionsTask = nil
        streaming = nil
        profileSession.downloads.cancelReaderAssetPreparation(for: book)
        let owner = cacheOwner
        cacheOwner = UUID().uuidString
        Task { [cache = profileSession.readingCache, preparationOwner] in
            await opening?.value
            if let preparationOwner { await cache.release(owner: preparationOwner) }
            await cache.release(owner: owner)
            await cache.trim()
        }
    }

    // Streamed EPUBs open inside resolution so a failed streamed open still falls through to the download path.
    func resolveAsset(
        openStreamed: (GrimmoryEpubStreamingSession) async throws -> Void
    ) async -> Resolution {
        let owner = cacheOwner
        var resolvedURL = existingLocalAssetURL()

        if resolvedURL == nil || !(FileManager.default.fileExists(atPath: resolvedURL?.path ?? "")) {
            if GrimmoryEpubStreaming.isEligible(book) {
                do {
                    let session = try await GrimmoryEpubStreaming.makeSession(
                        for: book,
                        providerResolver: providerResolver
                    )
                    try Task.checkCancellation()
                    await profileSession.readingCache.protect([session.cacheDirectory], owner: owner)
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
                    await profileSession.readingCache.protect([profileSession.ebooks.remoteReaderCacheRoot], owner: owner)
                    let downloadedURL = try await profileSession.downloads.prepareReaderAsset(for: book)
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
        await profileSession.readingCache.protect([url], owner: owner)
        if let preparationOwner { await profileSession.readingCache.release(owner: preparationOwner) }
        await profileSession.readingCache.touch(url)
        guard !Task.isCancelled else { return .cancelled }
        fileURL = url
        return .file(url)
    }

    func open(at url: URL) async throws -> Opened {
        try Task.checkCancellation()
        let owner = cacheOwner
        await profileSession.readingCache.protect([url], owner: owner)
        try Task.checkCancellation()
        await profileSession.readingCache.touch(url)
        try Task.checkCancellation()
        fileURL = url
        guard let readiumURL = FileURL(url: url) else {
            throw ClassicReaderError.invalidURL(url.path)
        }
        let asset = try await assetRetriever.retrieve(url: readiumURL).get()
        let publication = try await open(asset: asset)
        return Opened(publication: publication, fileURL: url)
    }

    func openStreamed(_ session: GrimmoryEpubStreamingSession) async throws -> Opened {
        try Task.checkCancellation()
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
        guard !Task.isCancelled, let streaming, let publication else { return }
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
        let importer = profileSession.ebooks
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
        try Task.checkCancellation()
        self.publication = publication
        return publication
    }

    private func existingLocalAssetURL() -> URL? {
        if book.epub3Features?.hasMediaOverlay == true,
            let cached = profileSession.ebooks.cachedReadaloudEpub(forBookId: book.id)
        {
            return cached
        }
        if profileSession.isOwner, !book.isComic,
            let audiobook = profileSession.playback.linker.linkedAudiobook(for: book),
            let narrated = StoryAlignService.shared.cachedNarratedEpubURL(ebook: book, audiobook: audiobook)
        {
            return narrated
        }
        return profileSession.ebooks.resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.filePath
        )
    }
}
