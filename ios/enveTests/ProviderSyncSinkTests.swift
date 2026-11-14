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
final class ProgressProviderStub: @MainActor LibraryProvider, @MainActor AudiobookProgressProvider {
    struct PlaybackUpdate: Equatable {
        let bookId: String
        let sessionId: String?
        let currentTime: TimeInterval
        let isFinished: Bool
        let timeListened: TimeInterval
    }

    var connection: ServerConnection
    var audiobookProgress: ProviderAudiobookProgress?
    var pullError: Error?
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
        if let pullError { throw pullError }
        return audiobookProgress
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        guard let audiobookProgress else { return nil }
        return (
            audiobookProgress.positionSeconds,
            audiobookProgress.percentage,
            audiobookProgress.trackIndex,
            audiobookProgress.updatedAt,
            audiobookProgress.readState.isFinished
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

    @Test func resolvesByBookAndMapsAudiobookProgress() async throws {
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

        let snapshot = try await sink.pull(book: book, domain: .audiobook)

        #expect(resolver.requestedBooks.map(\.id) == [book.id])
        #expect(snapshot?.positionSeconds == 25)
        #expect(snapshot?.progress == 0.25)
        #expect(snapshot?.lastUpdate == Date(timeIntervalSince1970: 500))
        #expect(snapshot?.source == "Test Server")
    }

    @Test func providerPullFailureIsNotAnEmptySuccess() async throws {
        let connection = ServerConnection(name: "Fixture", url: "https://example.invalid", type: .jellyfin)
        let provider = ProgressProviderStub(connection: connection)
        provider.pullError = URLError(.timedOut)
        let resolver = ProviderResolverStub()
        resolver.providers[connection.id] = provider
        let sink = ProviderSyncSink(providerResolver: resolver)
        let book = makeBook(providerId: connection.id)
        await #expect(throws: URLError.self) {
            _ = try await sink.pull(book: book, domain: .audiobook)
        }
    }

    @Test(arguments: [ProviderType.audiobookshelf, .plex, .jellyfin, .emby], [false, true])
    func guardedDownloadWriteChecksTheServerBeforeSending(type: ProviderType, retry: Bool) async throws {
        let suite = "guarded-download-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = PendingSyncQueueStore(defaults: defaults)
        let connection = ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: type)
        let provider = ProgressProviderStub(connection: connection)
        let resolver = ProviderResolverStub()
        resolver.providers[connection.id] = provider
        let book = makeBook(providerId: connection.id)
        let baselineDate = Date(timeIntervalSince1970: 100)
        let entry = PendingServerSync(
            stableId: book.stableId, sourceRaw: book.source.rawValue, backendId: nil, serverItemId: book.id,
            position: 25, duration: 100, updatedAt: 300,
            downloadedBaseline: DownloadedProgressBaseline(position: 20, updatedAt: baselineDate, isFinished: false)
        )
        pending.enqueue(entry)
        let sink = ProviderSyncSink(providerResolver: resolver, pendingSync: pending)
        let transport = ProviderPendingSyncTransport(
            providerResolver: resolver, bookLookup: { _ in book }, pendingSync: pending,
            serialQueue: PerBookSerialQueue()
        )
        let update = ProgressUpdate(
            book: book, domain: .audiobook, positionSeconds: 25, progress: 0.25, locator: nil,
            sourceEngine: nil, sessionId: nil, isFinished: false, timeListened: 0, playbackRate: 1
        )

        provider.audiobookProgress = ProviderAudiobookProgress(
            positionSeconds: 10, percentage: 0.1, trackIndex: nil,
            updatedAt: Date(timeIntervalSince1970: 200), readState: .reading
        )
        await #expect(throws: DownloadedProgressConflict.self) {
            if retry { _ = try await transport.push(stableId: book.stableId, entry: entry) }
            else { try await sink.push(update) }
        }
        #expect(provider.playbackUpdates.isEmpty)
        #expect(pending.entries[book.stableId] == entry)

        provider.pullError = URLError(.notConnectedToInternet)
        await #expect(throws: URLError.self) {
            if retry { _ = try await transport.push(stableId: book.stableId, entry: entry) }
            else { try await sink.push(update) }
        }
        #expect(provider.playbackUpdates.isEmpty)
        #expect(pending.entries[book.stableId] == entry)

        provider.pullError = nil
        provider.audiobookProgress = ProviderAudiobookProgress(
            positionSeconds: 20, percentage: 0.2, trackIndex: nil,
            updatedAt: baselineDate, readState: .reading
        )
        if retry { _ = try await transport.push(stableId: book.stableId, entry: entry) }
        else { try await sink.push(update) }
        #expect(provider.playbackUpdates.map(\.currentTime) == [25])
        #expect(pending.entries[book.stableId] == nil)
    }

    @Test func aPreviouslyQueuedDownloadIsProtectedAfterRelaunch() async throws {
        let suite = "legacy-download-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex)
        let provider = ProgressProviderStub(connection: connection)
        let resolver = ProviderResolverStub()
        resolver.providers[connection.id] = provider
        let book = makeBook(providerId: connection.id)
        let entry = PendingServerSync(
            stableId: book.stableId, sourceRaw: book.source.rawValue, backendId: nil, serverItemId: book.id,
            position: 25, duration: 100, updatedAt: 100
        )
        PendingSyncQueueStore(defaults: defaults).enqueue(entry)
        let pending = PendingSyncQueueStore(defaults: defaults)
        let transport = ProviderPendingSyncTransport(
            providerResolver: resolver, bookLookup: { _ in book }, pendingSync: pending,
            serialQueue: PerBookSerialQueue(), isDownloaded: { _ in true }
        )
        provider.audiobookProgress = ProviderAudiobookProgress(
            positionSeconds: 45, percentage: 0.45, trackIndex: nil,
            updatedAt: Date(timeIntervalSince1970: 200), readState: .reading
        )

        await #expect(throws: DownloadedProgressConflict.self) {
            _ = try await transport.push(stableId: book.stableId, entry: entry)
        }

        #expect(provider.playbackUpdates.isEmpty)
        let reopened = PendingSyncQueueStore(defaults: defaults)
        #expect(reopened.entries[book.stableId]?.downloadedBaseline?.updatedAt == Date(timeIntervalSince1970: 100))
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
