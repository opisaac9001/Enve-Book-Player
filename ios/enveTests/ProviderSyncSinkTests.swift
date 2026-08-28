import Foundation
import Testing

@testable import enve

@MainActor
private final class ProviderResolverStub: LibraryProviderResolving {
    var providers: [UUID: LibraryProvider] = [:]
    private(set) var requestedBooks: [Book] = []

    func provider(for providerId: UUID) -> LibraryProvider? {
        providers[providerId]
    }

    func provider(for book: Book) -> LibraryProvider? {
        requestedBooks.append(book)
        return providers[book.providerId]
    }
}

@MainActor
private final class ProgressProviderStub: @MainActor LibraryProvider, @MainActor AudiobookProgressProvider {
    struct PlaybackUpdate: Equatable {
        let bookId: String
        let sessionId: String?
        let currentTime: TimeInterval
        let isFinished: Bool
        let timeListened: TimeInterval
    }

    var connection: ServerConnection
    var audiobookProgress: ProviderAudiobookProgress?
    private(set) var playbackUpdates: [PlaybackUpdate] = []

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func validateConnection() async throws -> Bool { true }
    func fetchLibraries() async throws -> [Library] { [] }
    func fetchBooks(libraryId: String) async throws -> [Book] { [] }
    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
    func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        throw ProviderError.notImplemented
    }
    func getAudioURL(for book: Book) -> URL? { nil }
    func getStreamingHeaders() -> [String: String] { [:] }
    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        throw ProviderError.notImplemented
    }
    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        playbackUpdates.append(
            PlaybackUpdate(
                bookId: book.id,
                sessionId: sessionId,
                currentTime: currentTime,
                isFinished: isFinished,
                timeListened: timeListened
            )
        )
    }
    func fetchAudiobookProgressState(for book: Book) async throws -> ProviderAudiobookProgress? {
        audiobookProgress
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let audiobookProgress else { return nil }
        return (
            audiobookProgress.positionSeconds,
            audiobookProgress.percentage,
            audiobookProgress.trackIndex,
            audiobookProgress.updatedAt,
            audiobookProgress.readState.isAbandoned
        )
    }
}

@MainActor
struct ProviderSyncSinkTests {
    @Test func reauthenticationPolicyOnlyClassifiesAuthorizationFailures() {
        #expect(ProviderConnectionStore.requiresReauthentication(after: ProviderError.unauthorized))
        #expect(
            ProviderConnectionStore.requiresReauthentication(
                after: NSError(
                    domain: "tests",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Cloudflare access rejected"]
                )
            )
        )
        #expect(
            !ProviderConnectionStore.requiresReauthentication(
                after: ProviderError.networkError("The server is offline")
            )
        )
    }

    @Test func connectionStoreCreatesOneOwnedProviderForFallbackResolution() {
        let connectionId = UUID()
        let connection = ServerConnection(
            id: connectionId,
            name: "Emby Server",
            url: "https://example.invalid",
            type: .emby,
            isConnected: true,
            selectedLibraryIds: ["library"]
        )
        let provider = ProgressProviderStub(connection: connection)
        var factoryCalls = 0
        let store = ProviderConnectionStore(
            initialConnections: [connection],
            providerFactory: { _ in
                factoryCalls += 1
                return provider
            }
        )
        #expect(!store.persistsConnections)
        let book = Book(
            id: "emby-fallback",
            title: "Emby Fallback",
            source: .emby,
            backendId: connectionId.uuidString,
            providerId: UUID(),
            libraryId: "library"
        )

        let first = store.provider(for: book)
        let second = store.provider(for: book)

        #expect(first === provider)
        #expect(second === provider)
        #expect(factoryCalls == 1)
    }

    @Test func connectionStoreOwnsLegacyBackendProjection() {
        let connectionId = UUID()
        let connection = ServerConnection(
            id: connectionId,
            name: "ABS Server",
            url: "https://example.invalid",
            type: .audiobookshelf,
            token: "fixture-token",
            isConnected: true
        )
        let store = ProviderConnectionStore(
            initialConnections: [connection],
            providerFactory: { _ in nil }
        )

        let backend = store.backend(id: connectionId.uuidString.uppercased())

        #expect(backend?.id == connectionId.uuidString)
        #expect(backend?.type == .audiobookshelf)
        #expect(store.allBackends().contains(where: { $0.id == connectionId.uuidString }))
    }

    @Test func resolvesByBookAndMapsAudiobookProgress() async {
        let providerId = UUID()
        let connection = ServerConnection(
            id: providerId,
            name: "Test Server",
            url: "https://example.invalid",
            type: .audiobookshelf,
            isConnected: true
        )
        let provider = ProgressProviderStub(connection: connection)
        provider.audiobookProgress = ProviderAudiobookProgress(
            positionSeconds: 25,
            percentage: 0.25,
            trackIndex: 0,
            updatedAt: Date(timeIntervalSince1970: 500),
            readState: .reading
        )
        let resolver = ProviderResolverStub()
        resolver.providers[providerId] = provider
        let book = makeBook(providerId: providerId)
        let sink = ProviderSyncSink(providerResolver: resolver)

        let snapshot = await sink.pull(book: book, domain: .audiobook)

        #expect(resolver.requestedBooks.map(\.id) == [book.id])
        #expect(snapshot?.positionSeconds == 25)
        #expect(snapshot?.progress == 0.25)
        #expect(snapshot?.lastUpdate == Date(timeIntervalSince1970: 500))
        #expect(snapshot?.source == "Test Server")
    }

    @Test func routesAudiobookPushThroughResolvedCapability() async throws {
        let providerId = UUID()
        let provider = ProgressProviderStub(
            connection: ServerConnection(
                id: providerId,
                name: "Test Server",
                url: "https://example.invalid",
                type: .audiobookshelf,
                isConnected: true
            )
        )
        let resolver = ProviderResolverStub()
        resolver.providers[providerId] = provider
        let book = makeBook(providerId: providerId)
        let sink = ProviderSyncSink(providerResolver: resolver)

        try await sink.push(
            ProgressUpdate(
                book: book,
                domain: .audiobook,
                positionSeconds: 40,
                progress: 0.4,
                locator: nil,
                sourceEngine: nil,
                sessionId: "session-1",
                isFinished: true,
                timeListened: 12,
                playbackRate: 1.5
            )
        )

        #expect(
            provider.playbackUpdates == [
                ProgressProviderStub.PlaybackUpdate(
                    bookId: book.id,
                    sessionId: "session-1",
                    currentTime: 40,
                    isFinished: true,
                    timeListened: 12
                )
            ]
        )
    }

    @Test func isNotApplicableWithoutAResolvedProvider() {
        let resolver = ProviderResolverStub()
        let sink = ProviderSyncSink(providerResolver: resolver)

        #expect(!sink.isApplicable(to: makeBook(providerId: UUID()), domain: .audiobook))
    }

    private func makeBook(providerId: UUID) -> Book {
        Book(
            id: "provider-sync-contract",
            title: "Provider Sync Contract",
            duration: 100,
            source: .audiobookshelf,
            providerId: providerId,
            libraryId: "tests"
        )
    }
}
