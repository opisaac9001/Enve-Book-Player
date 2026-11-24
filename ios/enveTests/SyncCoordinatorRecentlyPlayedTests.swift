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
private final class CoordinatorFixture {
    let coordinator: SyncCoordinator
    let worker: RecentlyPlayedWorkerSpy
    let log: SyncEventLog
    private let profile: SyncTestProfile

    var session: ProfileSession { profile.session }
    var queue: PendingSyncQueueStore { session.pendingSync }

    init() throws {
        log = SyncEventLog()
        worker = RecentlyPlayedWorkerSpy(log: log)
        profile = try SyncTestProfile()
        let session = profile.session
        coordinator = SyncCoordinator(
            providerResolver: InertProviderResolver(),
            pendingSyncFlusher: PendingSyncQueueFlusher(
                store: session.pendingSync,
                transport: FlushRecordingTransport(log: log)
            ),
            recentlyPlayedSync: worker,
            profileSession: session
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

    func tearDown() async {
        await coordinator.retire()
        await profile.tearDown()
    }
}

@MainActor
struct SyncCoordinatorRecentlyPlayedTests {
    @Test func immediateAudiobookPushCancelsOlderDebounce() async throws {
        let fixture = try CoordinatorFixture()
        let book = Book(id: UUID().uuidString, title: "Debounce", source: .booklore)
        let sink = ProgressSinkSpy(bookId: book.stableId)
        fixture.session.registry.register(sink: sink)
        await fixture.coordinator.pushAudiobookProgress(
            book: book, position: 10, sessionId: nil, isFinished: false, timeListened: 0
        )
        await fixture.coordinator.pushAudiobookProgress(
            book: book, position: 20, sessionId: nil, isFinished: false, timeListened: 0, forceImmediate: true
        )
        try await Task.sleep(for: .milliseconds(2200))
        #expect(sink.positions == [20])
        await fixture.tearDown()
    }

    @Test func cancellingOneSubscriberKeepsTheOtherRegistered() async throws {
        let fixture = try CoordinatorFixture()
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
        await fixture.tearDown()
    }

    @Test func disablingICloudDoesNotDisableOtherProgressDestinations() async throws {
        let fixture = try CoordinatorFixture()
        let book = Book(
            id: "grimmory-progress",
            title: "Grimmory Progress",
            source: .booklore,
            mediaType: .ebook,
            ebookProgress: 0.42
        )
        let sink = ProgressSinkSpy(bookId: book.stableId)
        fixture.session.registry.register(sink: sink)
        fixture.coordinator.setSyncEnabled(false)

        await fixture.coordinator.pullOnOpen(book: book, domain: .ebook)
        await fixture.coordinator.pushProgress(book: book, forceImmediate: true, domain: .ebook)

        #expect(sink.pullCount == 1)
        #expect(sink.pushCount == 1)
        await fixture.tearDown()
    }

    @Test func launchPullRunsBeforePendingUploads() async throws {
        let fixture = try CoordinatorFixture()
        fixture.enqueue("queued")

        let result = await fixture.coordinator.runRecentlyPlayedSync(trigger: .appLaunch)

        #expect(fixture.log.events == ["worker", "flush:queued"])
        #expect(fixture.worker.triggers == [.appLaunch])
        #expect(result.wasCancelled == false)
        await fixture.tearDown()
    }

    @Test func reentrantRunIsRejectedWithoutFlushingOrRunningWorker() async throws {
        let fixture = try CoordinatorFixture()
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
        #expect(fixture.log.events == ["worker"])
        #expect(fixture.queue.entries["second"] != nil)

        fixture.worker.releaseOldest()
        _ = await inFlight.value
        await fixture.tearDown()
    }

    @Test func isSyncingIsHeldForTheDurationOfASuccessfulRun() async throws {
        let fixture = try CoordinatorFixture()
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
        await fixture.tearDown()
    }

    @Test func isSyncingResetsWhenTheWorkerReportsCancellation() async throws {
        let fixture = try CoordinatorFixture()
        fixture.worker.result = .cancelled

        let result = await fixture.coordinator.runRecentlyPlayedSync(trigger: .appLaunch)

        #expect(result.wasCancelled)
        #expect(fixture.coordinator.isSyncing == false)
        await fixture.tearDown()
    }

    @Test func isSyncingResetsWhenTheWorkerReportsBackendFailures() async throws {
        let fixture = try CoordinatorFixture()
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
        await fixture.tearDown()
    }

    @Test func supersededRunDoesNotClearTheNewerRunsSyncState() async throws {
        let fixture = try CoordinatorFixture()
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
        await fixture.tearDown()
    }
}
