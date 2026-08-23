import CryptoKit
import Foundation

struct PlaybackSessionInfo {
    let sessionId: String
    let audioTracks: [AudioTrackInfo]
    let chapters: [Chapter]
    let serverCurrentTime: TimeInterval?

    init(sessionId: String, audioTracks: [AudioTrackInfo], chapters: [Chapter], serverCurrentTime: TimeInterval? = nil) {
        self.sessionId = sessionId
        self.audioTracks = audioTracks
        self.chapters = chapters
        self.serverCurrentTime = serverCurrentTime
    }
}

struct AudioTrackInfo {
    let index: Int
    let startOffset: Double
    let duration: Double
    let contentUrl: String
    let mimeType: String
    var title: String? = nil
}

enum ProviderReadState: Sendable {
    case unspecified
    case reading
    case finished
    case abandoned
    case notReading

    init(serverValue: String?) {
        switch serverValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "READING", "RE_READING": self = .reading
        case "READ", "COMPLETED", "FINISHED": self = .finished
        case "ABANDONED": self = .abandoned
        case "UNREAD", "PARTIALLY_READ", "PAUSED", "ON_HOLD", "WONT_READ", "UNSET": self = .notReading
        default: self = .unspecified
        }
    }

    var isFinished: Bool { self == .finished }
    var isAbandoned: Bool { self == .abandoned }

    var persistedStatus: String? {
        switch self {
        case .unspecified: nil
        case .reading: "READING"
        case .finished: "READ"
        case .abandoned: "ABANDONED"
        case .notReading: "NOT_READING"
        }
    }
}

struct ProviderEbookProgress: Sendable {
    let progress: Double
    let locator: String?
    let updatedAt: Date?
    let readState: ProviderReadState
}

struct ProviderAudiobookProgress: Sendable {
    let positionSeconds: TimeInterval
    let percentage: Double
    let trackIndex: Int?
    let updatedAt: Date?
    let readState: ProviderReadState
}

protocol ProviderConnectionHandling: AnyObject {
    var connection: ServerConnection { get set }
    func validateConnection() async throws -> Bool
    var capabilities: ProviderCapabilities { get }
}

protocol LibraryCatalogProvider: ProviderConnectionHandling {
    func fetchLibraries() async throws -> [Library]
    func fetchBooks(libraryId: String) async throws -> [Book]
    func fetchBookBatches(libraryId: String) -> AsyncThrowingStream<LibraryFetchBatchResult, Error>
    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book]
    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)?
    func fetchCollections(libraryId: String?) async throws -> [Collection]
    func fetchSeries(libraryId: String) async throws -> [Series]
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress]
    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book
}

protocol PlaybackSessionProvider: ProviderConnectionHandling {
    func getAudioURL(for book: Book) -> URL?
    func chapterExtractionURL(for book: Book) -> URL?
    func getStreamingHeaders() -> [String: String]
    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo
}

protocol AudiobookProgressPushing: ProviderConnectionHandling {
    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws
}

protocol AudiobookProgressPulling: ProviderConnectionHandling {
    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)?
    func fetchAudiobookProgressState(for book: Book) async throws -> ProviderAudiobookProgress?
}

protocol AudiobookProgressProvider: AudiobookProgressPulling, AudiobookProgressPushing {}

protocol EbookProgressPushing: ProviderConnectionHandling {
    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws
}

protocol EbookProgressPulling: ProviderConnectionHandling {
    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isAbandoned: Bool)?
    func fetchEbookProgressState(for book: Book) async throws -> ProviderEbookProgress?
}

protocol EbookProgressProvider: EbookProgressPulling, EbookProgressPushing {}

protocol EbookDownloadProvider: ProviderConnectionHandling {
    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL
}

protocol ServerPageProvider: ProviderConnectionHandling {
    func fetchPageCount(for book: Book) async throws -> Int
    func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data
}

protocol PersonalRatingProvider: ProviderConnectionHandling {
    var supportsPersonalRating: Bool { get }
    func updatePersonalRating(for book: Book, rating: Int) async throws
}

protocol LibraryProvider: LibraryCatalogProvider {}

@MainActor
protocol LibraryProviderResolving: AnyObject {
    func provider(for providerId: UUID) -> LibraryProvider?
    func provider(for book: Book) -> LibraryProvider?
}

extension LibraryProviderResolving {
    func capability<Capability>(
        _ capability: Capability.Type,
        for book: Book
    ) -> Capability? {
        provider(for: book) as? Capability
    }
}

@MainActor
protocol ProviderConnectionAccessing: LibraryProviderResolving {
    var connections: [ServerConnection] { get }
    func backend(id: String) -> BackendConfig?
    func allBackends() -> [BackendConfig]
}

extension ProviderConnectionAccessing {
    func activeConnections(of type: ProviderType) -> [ServerConnection] {
        connections.filter { $0.type == type && $0.isConnected && !$0.isArchived }
    }
}

protocol EngineAwareEbookProgressProvider: EbookProgressPushing {
    func updateEbookProgress(
        for book: Book,
        progress: Double,
        epubLocator: String?,
        sourceEngine: ReaderEngineKind?
    ) async throws
}

protocol HistorySessionSyncProvider: ProviderConnectionHandling {
    func uploadHistorySession(_ session: HistorySession, for book: Book) async throws
}

struct LibraryFetchBatchResult {
    let books: [Book]
    let loadedSoFar: Int
    let totalCount: Int?
}

struct LibraryCatalogPage {
    let books: [Book]
    let totalCount: Int?
    let isLast: Bool
}

struct LibraryCatalogBatch {
    let books: [Book]
    let loadedSoFar: Int
    let totalCount: Int?
    let resumeToken: String?
    let completesSnapshot: Bool
}

final class LibraryCatalogBatchSource {
    let snapshotIdentifier: String
    let resumed: Bool
    private let nextHandler: () async throws -> LibraryCatalogBatch?

    init(
        snapshotIdentifier: String,
        resumed: Bool,
        next: @escaping () async throws -> LibraryCatalogBatch?
    ) {
        self.snapshotIdentifier = snapshotIdentifier
        self.resumed = resumed
        nextHandler = next
    }

    func next() async throws -> LibraryCatalogBatch? {
        try await nextHandler()
    }

    static func paged(
        firstPage: LibraryCatalogPage,
        pageSize: Int,
        pageConcurrency: Int,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?,
        fetchPage: @escaping @Sendable (Int) async throws -> LibraryCatalogPage
    ) -> LibraryCatalogBatchSource {
        let snapshotIdentifier = snapshotFingerprint(firstPage)
        let requestedPage = resumeAfter.flatMap(Int.init) ?? 0
        let canResume = expectedSnapshotIdentifier == snapshotIdentifier && requestedPage > 0
        let state = PagedLibraryCatalogState(
            firstPage: firstPage,
            pageSize: pageSize,
            pageConcurrency: pageConcurrency,
            nextPage: canResume ? requestedPage : 0,
            fetchPage: fetchPage
        )
        return LibraryCatalogBatchSource(
            snapshotIdentifier: snapshotIdentifier,
            resumed: canResume,
            next: { try await state.next() }
        )
    }

    static func snapshot(
        books: [Book],
        batchSize: Int = 500,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) -> LibraryCatalogBatchSource {
        let identity = "\(books.count)|" + books.map(\.uniqueId).sorted().joined(separator: "\u{1F}")
        let snapshotIdentifier = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let requestedOffset = resumeAfter.flatMap(Int.init) ?? 0
        let canResume = expectedSnapshotIdentifier == snapshotIdentifier && resumeAfter != nil
        let state = SnapshotLibraryCatalogState(
            books: books,
            batchSize: batchSize,
            offset: canResume ? min(requestedOffset, books.count) : 0
        )
        return LibraryCatalogBatchSource(
            snapshotIdentifier: snapshotIdentifier,
            resumed: canResume,
            next: { state.next() }
        )
    }

    private static func snapshotFingerprint(_ firstPage: LibraryCatalogPage) -> String {
        let identity = "\(firstPage.totalCount ?? -1)|" + firstPage.books.map(\.uniqueId).sorted().joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class SnapshotLibraryCatalogState {
    private let books: [Book]
    private let batchSize: Int
    private var offset: Int
    private var emittedEmptySnapshot = false

    init(books: [Book], batchSize: Int, offset: Int) {
        self.books = books
        self.batchSize = max(1, batchSize)
        self.offset = offset
    }

    func next() -> LibraryCatalogBatch? {
        if books.isEmpty {
            guard !emittedEmptySnapshot else { return nil }
            emittedEmptySnapshot = true
            return LibraryCatalogBatch(
                books: [],
                loadedSoFar: 0,
                totalCount: 0,
                resumeToken: "0",
                completesSnapshot: true
            )
        }
        guard offset < books.count else { return nil }
        let end = min(offset + batchSize, books.count)
        let batch = Array(books[offset..<end])
        offset = end
        return LibraryCatalogBatch(
            books: batch,
            loadedSoFar: offset,
            totalCount: books.count,
            resumeToken: String(offset),
            completesSnapshot: offset == books.count
        )
    }
}

private final class PagedLibraryCatalogState {
    private let firstPage: LibraryCatalogPage
    private let pageSize: Int
    private let pageConcurrency: Int
    private let fetchPage: @Sendable (Int) async throws -> LibraryCatalogPage
    private var nextPage: Int
    private var loaded: Int
    private var finished = false

    init(
        firstPage: LibraryCatalogPage,
        pageSize: Int,
        pageConcurrency: Int,
        nextPage: Int,
        fetchPage: @escaping @Sendable (Int) async throws -> LibraryCatalogPage
    ) {
        self.firstPage = firstPage
        self.pageSize = pageSize
        self.pageConcurrency = max(1, pageConcurrency)
        self.nextPage = nextPage
        loaded = nextPage * pageSize
        self.fetchPage = fetchPage
    }

    func next() async throws -> LibraryCatalogBatch? {
        guard !finished else { return nil }

        let startPage = nextPage
        let pages: [(Int, LibraryCatalogPage)]
        if startPage == 0 {
            pages = [(0, firstPage)]
        } else {
            let pageNumbers: [Int]
            if let total = firstPage.totalCount {
                let pageCount = max(1, (total + pageSize - 1) / pageSize)
                guard startPage < pageCount else {
                    finished = true
                    return nil
                }
                pageNumbers = Array(startPage..<min(startPage + pageConcurrency, pageCount))
            } else {
                pageNumbers = [startPage]
            }
            pages = try await withThrowingTaskGroup(of: (Int, LibraryCatalogPage).self) { group in
                for page in pageNumbers {
                    group.addTask { (page, try await self.fetchPage(page)) }
                }
                var fetched: [(Int, LibraryCatalogPage)] = []
                for try await page in group { fetched.append(page) }
                return fetched.sorted { $0.0 < $1.0 }
            }
        }

        let books = pages.flatMap { $0.1.books }
        loaded += books.count
        let last = pages.last!
        let completesSnapshot = last.1.isLast
        nextPage = last.0 + 1
        finished = completesSnapshot
        return LibraryCatalogBatch(
            books: books,
            loadedSoFar: loaded,
            totalCount: firstPage.totalCount,
            resumeToken: String(nextPage),
            completesSnapshot: completesSnapshot
        )
    }
}

protocol IncrementalCatalogProvider: LibraryProvider {
    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource
}

protocol WholeSnapshotCatalogProvider: IncrementalCatalogProvider {}

extension WholeSnapshotCatalogProvider {
    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        LibraryCatalogBatchSource.snapshot(
            books: try await fetchBooks(libraryId: libraryId),
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier
        )
    }
}

extension ProviderConnectionHandling {
    var capabilities: ProviderCapabilities { [] }
}

extension PlaybackSessionProvider {
    func chapterExtractionURL(for book: Book) -> URL? { getAudioURL(for: book) }
}

extension EbookProgressPulling {
    func fetchEbookProgressState(for book: Book) async throws -> ProviderEbookProgress? {
        guard let progress = try await fetchEbookProgress(for: book) else { return nil }
        return ProviderEbookProgress(
            progress: progress.progress,
            locator: progress.locator,
            updatedAt: progress.updatedAt,
            readState: progress.isAbandoned ? .abandoned : .unspecified
        )
    }
}

extension AudiobookProgressPulling {
    func fetchAudiobookProgressState(for book: Book) async throws -> ProviderAudiobookProgress? {
        guard let progress = try await fetchAudiobookProgress(for: book) else { return nil }
        return ProviderAudiobookProgress(
            positionSeconds: progress.positionSeconds,
            percentage: progress.percentage,
            trackIndex: progress.trackIndex,
            updatedAt: progress.updatedAt,
            readState: progress.isAbandoned ? .abandoned : .unspecified
        )
    }
}

extension LibraryCatalogProvider {
    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)? {
        return nil
    }

    func fetchBookBatches(libraryId: String) -> AsyncThrowingStream<LibraryFetchBatchResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let books = try await fetchBooks(libraryId: libraryId)
                    continuation.yield(
                        LibraryFetchBatchResult(
                            books: books,
                            loadedSoFar: books.count,
                            totalCount: books.count
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

@MainActor
enum ProviderFactory {
    static func create(for connection: ServerConnection) -> LibraryProvider? {
        PluginRegistry.shared.makeLibraryProvider(for: connection)
    }
}

enum ProviderError: LocalizedError {
    case invalidURL
    case unauthorized
    case rateLimited(String)
    case serverError(String)
    case invalidResponse
    case notImplemented
    case decodingFailed
    case networkError(String)
    case unknown

    case noCFI

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The server URL is invalid."
        case .unauthorized: return "Authentication failed. Please check your credentials."
        case .rateLimited(let message): return message
        case .serverError(let message): return "Server error: \(message)"
        case .invalidResponse: return "Received an invalid response from the server."
        case .notImplemented: return "This provider is not yet fully implemented."
        case .decodingFailed: return "Failed to decode server response."
        case .networkError(let message): return "Network error: \(message)"
        case .unknown: return "An unknown error occurred."
        case .noCFI: return "Annotation has no CFI location. Skipped."
        }
    }
}
