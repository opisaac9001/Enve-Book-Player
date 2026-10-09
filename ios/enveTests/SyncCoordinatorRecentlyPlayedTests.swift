import Foundation
import Testing

@testable import enve

@MainActor
private final class SyncEventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
private final class RecentlyPlayedWorkerSpy: RecentlyPlayedSyncing {
    var result = ServerStatusSyncResult.idle
    var waitsForRelease = false
    private(set) var triggers: [ServerStatusSyncTrigger] = []
    private var gates: [CheckedContinuation<Void, Never>] = []

    private let log: SyncEventLog

    init(log: SyncEventLog) {
        self.log = log
    }

    func sync(trigger: ServerStatusSyncTrigger) async -> ServerStatusSyncResult {
        triggers.append(trigger)
        log.record("worker")
        if waitsForRelease {
            await withCheckedContinuation { gates.append($0) }
        }
        return result
    }

    var isWaiting: Bool { !gates.isEmpty }

    func releaseOldest() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
}

@MainActor
private final class FlushRecordingTransport: PendingSyncTransporting {
    private let log: SyncEventLog

    init(log: SyncEventLog) {
        self.log = log
    }

    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition {
        log.record("flush:\(stableId)")
        return .remove
    }
}

@MainActor
private final class InertProviderResolver: LibraryProviderResolving {
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
private final class ProgressSinkSpy: SyncSink {
    let id = "test.progress.\(UUID().uuidString)"
    let displayName = "Progress test"
    private let bookId: String
    private(set) var pullCount = 0
    private(set) var pushCount = 0
    private(set) var positions: [TimeInterval] = []

    init(bookId: String) {
        self.bookId = bookId
    }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        book.stableId == bookId
    }

    func pull(book: Book, domain: ProgressSyncDomain) async throws -> SyncSnapshot? {
        pullCount += 1
        return nil
    }

    func push(_ update: ProgressUpdate) async throws {
        pushCount += 1
        positions.append(update.positionSeconds)
    }
}

@MainActor
private struct CoordinatorFixture {
    let coordinator: SyncCoordinator
    let worker: RecentlyPlayedWorkerSpy
    let queue: PendingSyncQueueStore
    let log: SyncEventLog
    let suiteName: String
    private let defaults: UserDefaults

    init() {
        log = SyncEventLog()
        worker = RecentlyPlayedWorkerSpy(log: log)
        suiteName = "SyncCoordinatorRecentlyPlayedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        queue = PendingSyncQueueStore(defaults: defaults, storageKey: "queue")
        coordinator = SyncCoordinator(
            providerResolver: InertProviderResolver(),
            pendingSyncFlusher: PendingSyncQueueFlusher(
                store: queue,
                transport: FlushRecordingTransport(log: log)
            ),
            recentlyPlayedSync: worker
        )
    }

    func enqueue(_ stableId: String) {
        queue.enqueue(
            PendingServerSync(
                stableId: stableId,
                sourceRaw: Book.BookSource.local.rawValue,
                backendId: nil,
                serverItemId: "server-\(stableId)",
                position: 10,
                duration: 100,
                updatedAt: 10
            )
        )
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
struct SyncCoordinatorRecentlyPlayedTests {
    @Test func immediateAudiobookPushCancelsOlderDebounce() async throws {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        let book = Book(id: UUID().uuidString, title: "Debounce", source: .booklore)
        let sink = ProgressSinkSpy(bookId: book.stableId)
        PluginRegistry.shared.register(sink: sink)
        defer { PluginRegistry.shared.unregister(sinkId: sink.id) }
        await fixture.coordinator.pushAudiobookProgress(
            book: book, position: 10, sessionId: nil, isFinished: false, timeListened: 0
        )
        await fixture.coordinator.pushAudiobookProgress(
            book: book, position: 20, sessionId: nil, isFinished: false, timeListened: 0, forceImmediate: true
        )
        try await Task.sleep(for: .milliseconds(2200))
        #expect(sink.positions == [20])
        await fixture.coordinator.retire()
    }

    @Test func cancellingOneSubscriberKeepsTheOtherRegistered() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        let book = Book(id: UUID().uuidString, title: "Subscriptions", source: .booklore)
        let first = fixture.coordinator.subscribe(book: book)
        let second = fixture.coordinator.subscribe(book: book)
        let firstConsumer = Task { for await _ in first {} }
        firstConsumer.cancel()
        await firstConsumer.value
        await Task.yield()
        await fixture.coordinator.pullOnOpen(book: book, domain: .audiobook, excludingProvider: true)
        await fixture.coordinator.retire()
        var received = false
        for await event in second {
            if case .pullStarted(let id) = event { received = id == book.stableId }
        }
        #expect(received)
    }

    @Test func disablingICloudDoesNotDisableOtherProgressDestinations() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        let book = Book(
            id: "grimmory-progress",
            title: "Grimmory Progress",
            source: .booklore,
            mediaType: .ebook,
            ebookProgress: 0.42
        )
        let sink = ProgressSinkSpy(bookId: book.stableId)
        PluginRegistry.shared.register(sink: sink)
        defer { PluginRegistry.shared.unregister(sinkId: sink.id) }
        fixture.coordinator.setSyncEnabled(false)

        await fixture.coordinator.pullOnOpen(book: book, domain: .ebook)
        await fixture.coordinator.pushProgress(book: book, forceImmediate: true, domain: .ebook)

        #expect(sink.pullCount == 1)
        #expect(sink.pushCount == 1)
    }

    @Test func flushesPendingQueueBeforeRunningWorker() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        fixture.enqueue("queued")

        let result = await fixture.coordinator.runRecentlyPlayedSync(trigger: .appLaunch)

        #expect(fixture.log.events == ["flush:queued", "worker"])
        #expect(fixture.worker.triggers == [.appLaunch])
        #expect(result.wasCancelled == false)
    }

    @Test func reentrantRunIsRejectedWithoutFlushingOrRunningWorker() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        fixture.enqueue("first")
        fixture.worker.waitsForRelease = true
        let coordinator = fixture.coordinator

        let inFlight = Task { @MainActor in
            await coordinator.runRecentlyPlayedSync(trigger: .appLaunch)
        }
        while !fixture.worker.isWaiting {
            await Task.yield()
        }
        fixture.enqueue("second")

        let rejected = await fixture.coordinator.runRecentlyPlayedSync(trigger: .homePullToRefresh)

        #expect(rejected.attemptedBackendCount == 0)
        #expect(rejected.wasCancelled == false)
        #expect(fixture.worker.triggers == [.appLaunch])
        #expect(fixture.log.events == ["flush:first", "worker"])
        #expect(fixture.queue.entries["second"] != nil)

        fixture.worker.releaseOldest()
        _ = await inFlight.value
    }

    @Test func isSyncingIsHeldForTheDurationOfASuccessfulRun() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        fixture.worker.waitsForRelease = true
        let coordinator = fixture.coordinator

        #expect(coordinator.isSyncing == false)
        let inFlight = Task { @MainActor in
            await coordinator.runRecentlyPlayedSync(trigger: .appLaunch)
        }
        while !fixture.worker.isWaiting {
            await Task.yield()
        }

        #expect(fixture.coordinator.isSyncing)

        fixture.worker.releaseOldest()
        _ = await inFlight.value

        #expect(fixture.coordinator.isSyncing == false)
        #expect(fixture.coordinator.lastSyncDate != nil)
    }

    @Test func isSyncingResetsWhenTheWorkerReportsCancellation() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        fixture.worker.result = .cancelled

        let result = await fixture.coordinator.runRecentlyPlayedSync(trigger: .appLaunch)

        #expect(result.wasCancelled)
        #expect(fixture.coordinator.isSyncing == false)
    }

    @Test func isSyncingResetsWhenTheWorkerReportsBackendFailures() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        fixture.worker.result = ServerStatusSyncResult(
            attemptedBackendCount: 1,
            pulledItemCount: 0,
            pushedItemCount: 0,
            failedBackends: ["Books"],
            wasCancelled: false
        )

        let result = await fixture.coordinator.runRecentlyPlayedSync(trigger: .homePullToRefresh)

        #expect(result.hasFailures)
        #expect(fixture.coordinator.isSyncing == false)
    }

    @Test func supersededRunDoesNotClearTheNewerRunsSyncState() async {
        let fixture = CoordinatorFixture()
        defer { fixture.tearDown() }
        fixture.worker.waitsForRelease = true
        let coordinator = fixture.coordinator

        let older = Task { @MainActor in
            await coordinator.runRecentlyPlayedSync(trigger: .appLaunch)
        }
        while !fixture.worker.isWaiting {
            await Task.yield()
        }
        coordinator.endSync()

        let newer = Task { @MainActor in
            await coordinator.runRecentlyPlayedSync(trigger: .homePullToRefresh)
        }
        while fixture.worker.triggers.count < 2 {
            await Task.yield()
        }

        fixture.worker.releaseOldest()
        _ = await older.value
        #expect(fixture.coordinator.isSyncing)

        fixture.worker.releaseOldest()
        _ = await newer.value
        #expect(fixture.coordinator.isSyncing == false)
    }
}
