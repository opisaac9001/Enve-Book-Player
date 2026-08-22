import Combine
import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
private final class ProviderConnectionStub: ProviderConnectionAccessing {
    var connections: [ServerConnection] = []
    var backends: [BackendConfig] = []

    func backend(id: String) -> BackendConfig? { backends.first { $0.id == id } }
    func allBackends() -> [BackendConfig] { backends }
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
private final class PlaybackStateStub: PlaybackStateProvider {
    var snapshot: PlaybackSnapshot = .idle

    func setCurrentBook(_ book: Book?) {
        snapshot = PlaybackSnapshot(
            currentBook: book,
            isPlaying: book != nil,
            position: 0,
            duration: 0,
            playbackSpeed: 1,
            volume: 1,
            isLoaded: book != nil,
            isLoading: false,
            isOverlayPlaybackActive: false,
            errorDescription: nil
        )
    }
}

@MainActor
private final class ProgressAPIStub: RecentlyPlayedProgressAPI {
    struct AudiobookPush: Equatable {
        let libraryItemId: String
        let currentTime: TimeInterval
        let duration: TimeInterval
        let isFinished: Bool
    }

    struct EbookPush: Equatable {
        let libraryItemId: String
        let progress: Double
        let isFinished: Bool
    }

    var progressByBackend: [String: Result<[ABSMediaProgress], Error>] = [:]
    var audiobookPushError: Error?
    var ebookPushError: Error?
    private(set) var queriedBackends: [String] = []
    private(set) var audiobookPushes: [AudiobookPush] = []
    private(set) var ebookPushes: [EbookPush] = []

    func allProgress(backend: BackendConfig) async throws -> [ABSMediaProgress] {
        queriedBackends.append(backend.id)
        return try progressByBackend[backend.id, default: .success([])].get()
    }

    func pushAudiobookProgress(
        libraryItemId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool,
        backend: BackendConfig
    ) async throws {
        if let audiobookPushError { throw audiobookPushError }
        audiobookPushes.append(
            AudiobookPush(libraryItemId: libraryItemId, currentTime: currentTime, duration: duration, isFinished: isFinished)
        )
    }

    func pushEbookProgress(libraryItemId: String, progress: Double, isFinished: Bool, backend: BackendConfig) async throws {
        if let ebookPushError { throw ebookPushError }
        ebookPushes.append(EbookPush(libraryItemId: libraryItemId, progress: progress, isFinished: isFinished))
    }
}

@MainActor
private final class ProgressCacheStub: RecentlyPlayedProgressCaching {
    struct StoredProgress {
        var progress: TimeInterval
        var duration: TimeInterval
        var lastUpdated: TimeInterval
    }

    var stored: [String: StoredProgress] = [:]
    private(set) var savedProgress: [String: TimeInterval] = [:]
    private(set) var recentlyPlayed: [String: Date] = [:]

    func loadProgress(for book: Book) -> (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)? {
        guard let entry = stored[book.stableId] else { return nil }
        return (entry.progress, entry.duration, entry.lastUpdated)
    }

    func saveProgress(for book: Book, progress: TimeInterval, duration: TimeInterval, at date: Date) {
        savedProgress[book.stableId] = progress
        stored[book.stableId] = StoredProgress(progress: progress, duration: duration, lastUpdated: date.timeIntervalSince1970)
    }

    func saveRecentlyPlayed(_ book: Book, date: Date) {
        recentlyPlayed[book.stableId] = date
    }
}

@MainActor
private final class LibraryCacheStub: RecentlyPlayedLibraryCaching {
    var allBooks: [Book] = []
    let allBooksChanged = PassthroughSubject<Void, Never>()
    private(set) var batchCount = 0
    private(set) var transactionCount = 0
    private(set) var mutatedStableIds: [String] = []

    func performAllBooksBatch(_ body: () -> Void) {
        batchCount += 1
        body()
    }

    func withAllBooksTransaction(_ body: () async -> Void) async {
        transactionCount += 1
        await body()
    }

    @discardableResult
    func mutateBook(stableId: String, _ transform: (inout Book) -> Void) -> Book? {
        guard let index = allBooks.firstIndex(where: { $0.stableId == stableId }) else { return nil }
        transform(&allBooks[index])
        mutatedStableIds.append(stableId)
        return allBooks[index]
    }

}

@MainActor
private final class EbookLinkStub: EbookLinkPersisting {
    private(set) var relationshipSaveCount = 0

    @discardableResult
    func saveLinks() -> Task<Void, Never>? {
        relationshipSaveCount += 1
        return nil
    }
}

@MainActor
private final class SyncStrategyStub: ProviderSyncStrategy {
    let id: String
    let displayName: String
    var result: ProviderSyncResult
    private(set) var invocations: [(force: Bool, launchOptimized: Bool)] = []

    init(id: String, result: ProviderSyncResult) {
        self.id = id
        displayName = id
        self.result = result
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        invocations.append((force, launchOptimized))
        return result
    }
}

@MainActor
private final class SyncStrategyRegistryStub: SyncStrategyProviding {
    var syncStrategies: [any ProviderSyncStrategy] = []
}

@MainActor
private struct WorkerFixture {
    let connections = ProviderConnectionStub()
    let playback = PlaybackStateStub()
    let progressAPI = ProgressAPIStub()
    let progressCache = ProgressCacheStub()
    let libraryCache = LibraryCacheStub()
    let ebookLinks = EbookLinkStub()
    let strategies = SyncStrategyRegistryStub()
    let store: SwiftDataBookStore

    init() throws {
        let schema = Schema([
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
        ])
        let configuration = ModelConfiguration(
            "RecentlyPlayedSyncServiceTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        store = SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    func makeService() -> RecentlyPlayedSyncService {
        RecentlyPlayedSyncService(
            playbackState: playback,
            providerConnections: connections,
            bookQuerying: store,
            bookWriting: store,
            progressRepository: store,
            progressAPI: progressAPI,
            progressCache: progressCache,
            libraryCache: libraryCache,
            ebookLinks: ebookLinks,
            strategyRegistry: strategies
        )
    }
}

private let testProviderId = UUID(uuidString: "6B1F5F1E-6C5B-4E3E-9C2A-9F52A0F6A001")!

private func makeBook(
    id: String,
    mediaType: AppMediaType = .audiobook,
    duration: TimeInterval? = 600,
    ebookProgress: Double? = nil,
    lastUpdate: Date = Date(timeIntervalSince1970: 1_000),
    readAloudSourceStableId: String? = nil
) -> Book {
    Book(
        id: id,
        title: "Book \(id)",
        duration: duration,
        mediaType: mediaType,
        ebookProgress: ebookProgress,
        lastUpdate: lastUpdate,
        libraryId: "library",
        providerId: testProviderId,
        backendId: "backend",
        source: .audiobookshelf,
        readAloudSourceStableId: readAloudSourceStableId
    )
}

private func makeBackend(
    id: String,
    type: BackendConfig.BackendType = .audiobookshelf,
    enabled: Bool = true
) -> BackendConfig {
    BackendConfig(
        id: id,
        name: "Backend \(id)",
        type: type,
        url: "http://backend.invalid",
        token: "token",
        enabled: enabled,
        username: nil,
        password: nil,
        userId: nil,
        selectedLibraryIds: nil
    )
}

private func makeConnection(type: ProviderType, isConnected: Bool = true, isArchived: Bool = false) -> ServerConnection {
    ServerConnection(
        name: "\(type.rawValue) connection",
        url: "http://connection.invalid",
        type: type,
        isConnected: isConnected,
        isArchived: isArchived
    )
}

private func makeProgress(
    libraryItemId: String,
    currentTime: Double? = nil,
    duration: Double? = nil,
    ebookProgress: Double? = nil,
    progress: Double? = nil,
    isFinished: Bool? = false,
    lastUpdateSeconds: TimeInterval
) -> ABSMediaProgress {
    ABSMediaProgress(
        id: "progress-\(libraryItemId)",
        libraryItemId: libraryItemId,
        episodeId: nil,
        duration: duration,
        progress: progress,
        currentTime: currentTime,
        isFinished: isFinished,
        hideFromContinueListening: nil,
        ebookProgress: ebookProgress,
        lastUpdate: lastUpdateSeconds * 1_000,
        startedAt: nil,
        finishedAt: nil
    )
}

@MainActor
struct RecentlyPlayedSyncServiceTests {
    @Test func returnsIdleWhenNoBackendOrStrategyConnectionExists() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs", enabled: false)]
        fixture.connections.connections = [makeConnection(type: .komga, isConnected: false)]
        let strategy = SyncStrategyStub(id: "strategy", result: ProviderSyncResult(pulled: 3, pushed: 2))
        fixture.strategies.syncStrategies = [strategy]

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.attemptedBackendCount == 0)
        #expect(result.mergedItemCount == 0)
        #expect(result.wasCancelled == false)
        #expect(fixture.progressAPI.queriedBackends.isEmpty)
        #expect(strategy.invocations.isEmpty)
        #expect(fixture.libraryCache.transactionCount == 0)
    }

    @Test func countsEnabledProgressBackendsAndActiveStrategyConnections() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [
            makeBackend(id: "abs"),
            makeBackend(id: "emby", type: .emby),
            makeBackend(id: "jellyfin-off", type: .jellyfin, enabled: false),
            makeBackend(id: "plex", type: .plex),
        ]
        fixture.connections.connections = [
            makeConnection(type: .booklore),
            makeConnection(type: .booklore),
            makeConnection(type: .komga),
            makeConnection(type: .komga, isArchived: true),
            makeConnection(type: .silo, isConnected: false),
            makeConnection(type: .kavita),
        ]

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.attemptedBackendCount == 5)
        #expect(fixture.progressAPI.queriedBackends == ["abs", "emby"])
    }

    @Test func skipsAbsorbedAndCurrentlyPlayingBooks() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]

        let absorbed = makeBook(id: "absorbed")
        let companion = makeBook(id: "companion", mediaType: .ebook, readAloudSourceStableId: absorbed.stableId)
        let playing = makeBook(id: "playing")
        let syncable = makeBook(id: "syncable")
        await fixture.store.upsertBooks([absorbed, companion, playing, syncable])
        fixture.playback.setCurrentBook(playing)

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "absorbed", currentTime: 300, duration: 600, lastUpdateSeconds: 5_000),
            makeProgress(libraryItemId: "playing", currentTime: 300, duration: 600, lastUpdateSeconds: 5_000),
            makeProgress(libraryItemId: "syncable", currentTime: 300, duration: 600, lastUpdateSeconds: 5_000),
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.pulledItemCount == 1)
        #expect(Set(fixture.progressCache.savedProgress.keys) == [syncable.stableId])
        #expect(Set(fixture.progressCache.recentlyPlayed.keys) == [syncable.stableId])
    }

    @Test func pullsEbookProgressWhenTheServerIsNewer() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]

        let book = makeBook(id: "ebook", mediaType: .ebook, duration: nil, ebookProgress: 0.1)
        await fixture.store.upsertBooks([book])
        fixture.libraryCache.allBooks = [book]

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "ebook", ebookProgress: 0.5, lastUpdateSeconds: 5_000)
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.pulledItemCount == 1)
        #expect(result.pushedItemCount == 0)
        #expect(fixture.progressAPI.ebookPushes.isEmpty)
        #expect(fixture.libraryCache.mutatedStableIds == [book.stableId])
        #expect(fixture.ebookLinks.relationshipSaveCount == 1)
        #expect(fixture.libraryCache.allBooks[0].ebookProgress == 0.5)
        #expect(await fixture.store.book(uniqueId: book.uniqueId)?.ebookProgress == 0.5)
    }

    @Test func pushesEbookProgressWhenTheLocalCopyIsNewer() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]

        let book = makeBook(
            id: "ebook",
            mediaType: .ebook,
            duration: nil,
            ebookProgress: 0.6,
            lastUpdate: Date(timeIntervalSince1970: 9_000)
        )
        await fixture.store.upsertBooks([book])
        fixture.libraryCache.allBooks = [book]

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "ebook", ebookProgress: 0.2, lastUpdateSeconds: 5_000)
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.pushedItemCount == 1)
        #expect(result.pulledItemCount == 0)
        #expect(fixture.progressAPI.ebookPushes == [.init(libraryItemId: "ebook", progress: 0.6, isFinished: false)])
        #expect(fixture.libraryCache.mutatedStableIds.isEmpty)
    }

    @Test func failedEbookPushDoesNotMarkTheBackendFailed() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]
        fixture.progressAPI.ebookPushError = URLError(.badServerResponse)

        let book = makeBook(
            id: "ebook",
            mediaType: .ebook,
            duration: nil,
            ebookProgress: 0.6,
            lastUpdate: Date(timeIntervalSince1970: 9_000)
        )
        await fixture.store.upsertBooks([book])

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "ebook", ebookProgress: 0.2, lastUpdateSeconds: 5_000)
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.pushedItemCount == 0)
        #expect(result.failedBackends.isEmpty)
        #expect(fixture.progressCache.recentlyPlayed.keys.contains(book.stableId))
    }

    @Test func pullsAudiobookProgressWhenTheServerIsNewer() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]

        let book = makeBook(id: "audiobook")
        await fixture.store.upsertBooks([book])
        fixture.progressCache.stored[book.stableId] = .init(progress: 30, duration: 600, lastUpdated: 1_000)

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "audiobook", currentTime: 300, duration: 600, lastUpdateSeconds: 5_000)
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.pulledItemCount == 1)
        #expect(fixture.progressCache.savedProgress[book.stableId] == 300)
        #expect(fixture.progressAPI.audiobookPushes.isEmpty)
        #expect(fixture.progressCache.recentlyPlayed[book.stableId] == Date(timeIntervalSince1970: 5_000))
    }

    @Test func pushesAudiobookProgressWhenTheLocalCopyIsNewer() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]

        let book = makeBook(id: "audiobook")
        await fixture.store.upsertBooks([book])
        fixture.progressCache.stored[book.stableId] = .init(progress: 300, duration: 600, lastUpdated: 9_000)

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "audiobook", currentTime: 30, duration: 600, lastUpdateSeconds: 5_000)
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.pushedItemCount == 1)
        #expect(
            fixture.progressAPI.audiobookPushes == [
                .init(libraryItemId: "audiobook", currentTime: 300, duration: 600, isFinished: false)
            ]
        )
        #expect(fixture.progressCache.savedProgress.isEmpty)
    }

    @Test func matchingPositionsResolveToANoOp() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]

        let book = makeBook(id: "audiobook")
        await fixture.store.upsertBooks([book])
        fixture.progressCache.stored[book.stableId] = .init(progress: 300, duration: 600, lastUpdated: 9_000)

        fixture.progressAPI.progressByBackend["abs"] = .success([
            makeProgress(libraryItemId: "audiobook", currentTime: 301, duration: 600, lastUpdateSeconds: 5_000)
        ])

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.mergedItemCount == 0)
        #expect(fixture.progressAPI.audiobookPushes.isEmpty)
        #expect(fixture.progressCache.savedProgress.isEmpty)
        #expect(fixture.progressCache.recentlyPlayed[book.stableId] != nil)
    }

    @Test func mergesStrategyCountsAndForwardsTriggerFlags() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]
        let first = SyncStrategyStub(id: "first", result: ProviderSyncResult(pulled: 2, pushed: 1))
        let second = SyncStrategyStub(id: "second", result: ProviderSyncResult(pulled: 0, pushed: 4))
        fixture.strategies.syncStrategies = [first, second]

        let refreshed = await fixture.makeService().sync(trigger: .homePullToRefresh)

        #expect(refreshed.pulledItemCount == 2)
        #expect(refreshed.pushedItemCount == 5)
        #expect(first.invocations.map(\.force) == [true])
        #expect(first.invocations.map(\.launchOptimized) == [false])
        #expect(fixture.libraryCache.transactionCount == 1)

        _ = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(second.invocations.map(\.force) == [true, false])
        #expect(second.invocations.map(\.launchOptimized) == [false, true])
    }

    @Test func cancelledBackendFetchStopsRemainingBackendsWithoutMarkingFailures() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs"), makeBackend(id: "emby", type: .emby)]
        fixture.progressAPI.progressByBackend["abs"] = .failure(CancellationError())

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.wasCancelled)
        #expect(result.failedBackends.isEmpty)
        #expect(fixture.progressAPI.queriedBackends == ["abs"])
    }

    @Test func urlCancellationIsTreatedAsCancellationRatherThanFailure() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs"), makeBackend(id: "emby", type: .emby)]
        fixture.progressAPI.progressByBackend["abs"] = .failure(URLError(.cancelled))

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.wasCancelled)
        #expect(result.failedBackends.isEmpty)
        #expect(fixture.progressAPI.queriedBackends == ["abs"])
    }

    @Test func ordinaryBackendFailureIsRecordedAndTheNextBackendStillRuns() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs"), makeBackend(id: "emby", type: .emby)]
        fixture.progressAPI.progressByBackend["abs"] = .failure(URLError(.timedOut))

        let result = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(result.wasCancelled == false)
        #expect(result.failedBackends == ["Backend abs"])
        #expect(fixture.progressAPI.queriedBackends == ["abs", "emby"])
    }

    @Test func refreshesAudiobookSnapshotsForASmallLibrary() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]
        fixture.strategies.syncStrategies = [SyncStrategyStub(id: "strategy", result: ProviderSyncResult(pulled: 1, pushed: 0))]

        let audiobook = makeBook(id: "audiobook")
        let ebook = makeBook(id: "ebook", mediaType: .ebook, duration: nil)
        await fixture.store.upsertBooks([audiobook, ebook])
        fixture.libraryCache.allBooks = [audiobook, ebook]
        fixture.progressCache.stored[audiobook.stableId] = .init(progress: 420, duration: 600, lastUpdated: 7_000)
        fixture.progressCache.stored[ebook.stableId] = .init(progress: 99, duration: 100, lastUpdated: 7_000)

        _ = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(fixture.libraryCache.batchCount == 1)
        #expect(fixture.libraryCache.allBooks[0].currentTime == 420)
        #expect(fixture.libraryCache.allBooks[0].lastUpdate == Date(timeIntervalSince1970: 7_000))
        #expect(fixture.libraryCache.allBooks[1].currentTime == 0)
        #expect(await fixture.store.book(uniqueId: audiobook.uniqueId)?.currentTime == 420)
    }

    @Test func skipsSnapshotRefreshForALargeLibrary() async throws {
        let fixture = try WorkerFixture()
        fixture.connections.backends = [makeBackend(id: "abs")]
        fixture.strategies.syncStrategies = [SyncStrategyStub(id: "strategy", result: ProviderSyncResult(pulled: 1, pushed: 0))]

        await fixture.store.upsertBooks((0...5_000).map { makeBook(id: "bulk-\($0)") })
        let audiobook = makeBook(id: "audiobook")
        await fixture.store.upsertBooks([audiobook])
        fixture.libraryCache.allBooks = [audiobook]
        fixture.progressCache.stored[audiobook.stableId] = .init(progress: 420, duration: 600, lastUpdated: 7_000)

        #expect(await fixture.store.bookCount(mediaType: "audiobook") > 5_000)

        _ = await fixture.makeService().sync(trigger: .appLaunch)

        #expect(fixture.libraryCache.batchCount == 0)
        #expect(fixture.libraryCache.allBooks[0].currentTime == 0)
    }
}
