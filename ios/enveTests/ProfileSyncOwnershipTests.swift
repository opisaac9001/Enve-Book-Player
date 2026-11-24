import Foundation
import Testing

@testable import enve

@MainActor
final class SyncTestProfile {
    let session: ProfileSession
    let defaults: UserDefaults
    private let root: URL
    private let suiteName: String

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "SyncTestProfile.\(UUID().uuidString)"
        self.root = root
        self.suiteName = suiteName
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let profile = FamilyProfile(id: UUID().uuidString, name: "Sync member", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        ProfileServerSyncPreferences(defaults: defaults, isOwner: false).isEnabled = true
    }

    func tearDown() async {
        await session.retire()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class SuspendedSink: SyncSink {
    let id: String
    let displayName = "Suspended"
    private let bookId: String
    private let snapshot: SyncSnapshot?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var pushCount = 0
    private(set) var observedCancellation = false

    init(id: String, bookId: String, snapshot: SyncSnapshot? = nil) {
        self.id = id
        self.bookId = bookId
        self.snapshot = snapshot
    }

    var isSuspended: Bool { continuation != nil }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        book.stableId == bookId
    }

    func pull(book: Book, domain: ProgressSyncDomain) async throws -> SyncSnapshot? {
        await suspend()
        return snapshot
    }

    func push(_ update: ProgressUpdate) async throws {
        pushCount += 1
        await suspend()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    // Like a slow network request, the wait ignores cancellation; the flag only shows retirement reached it.
    private func suspend() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.observedCancellation = true }
        }
    }
}

@MainActor
private final class RecordingSink: SyncSink {
    let id = "test.recording"
    let displayName = "Recording"
    private let bookId: String
    private(set) var pushCount = 0

    init(bookId: String) {
        self.bookId = bookId
    }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        book.stableId == bookId
    }

    func pull(book: Book, domain: ProgressSyncDomain) async throws -> SyncSnapshot? { nil }

    func push(_ update: ProgressUpdate) async throws {
        pushCount += 1
    }
}

@MainActor
private final class NoProviderResolver: LibraryProviderResolving {
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
private final class RetainingTransport: PendingSyncTransporting {
    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition { .retain }
}

@MainActor
private final class IdleRecentlyPlayed: RecentlyPlayedSyncing {
    func sync(trigger: ServerStatusSyncTrigger) async -> ServerStatusSyncResult { .idle }
}

@MainActor
struct ProfileSyncOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func retirementDuringProviderPushKeepsQueuedCheckpointAndHistory() async throws {
        let profile = try SyncTestProfile()
        let coordinator = makeCoordinator(profile.session)
        let book = ebook()
        profile.session.appState.libraryCache.ensureBookInMemory(book)
        profile.session.pendingSync.enqueue(
            PendingServerSync(
                stableId: book.stableId, sourceRaw: book.source.rawValue, backendId: nil,
                serverItemId: book.id, position: 0, duration: 0, updatedAt: 500,
                domainRaw: "ebook", progress: 0.3
            )
        )
        let provider = SuspendedSink(id: ProviderSyncSink.identifier, bookId: book.stableId)
        profile.session.registry.register(sink: provider)
        let events = coordinator.subscribe(book: book)

        let push = Task { await coordinator.pushProgress(book: book, forceImmediate: true, domain: .ebook) }
        while !provider.isSuspended { await Task.yield() }
        let retirement = Task { await coordinator.retire() }
        while !provider.observedCancellation { await Task.yield() }
        provider.release()
        await retirement.value
        await push.value

        var received: [SyncEvent] = []
        for await event in events { received.append(event) }
        #expect(received.count == 1)
        if case .pushStarted(let id)? = received.first {
            #expect(id == book.stableId)
        } else {
            Issue.record("Expected only the push start event")
        }
        #expect(profile.session.pendingSync.entries[book.stableId] != nil)
        #expect(PendingSyncQueueStore(defaults: profile.defaults).entries[book.stableId] != nil)
        #expect(profile.session.playbackHistory.entries.isEmpty)
        await profile.tearDown()
    }

    @Test(.timeLimit(.minutes(1)))
    func retirementDuringProviderPushDoesNotStartLaterSinks() async throws {
        let profile = try SyncTestProfile()
        let coordinator = makeCoordinator(profile.session)
        let book = ebook()
        profile.session.appState.libraryCache.ensureBookInMemory(book)
        let provider = SuspendedSink(id: ProviderSyncSink.identifier, bookId: book.stableId)
        let later = RecordingSink(bookId: book.stableId)
        profile.session.registry.register(sink: provider)
        profile.session.registry.register(sink: later)

        let push = Task { await coordinator.pushProgress(book: book, forceImmediate: true, domain: .ebook) }
        while !provider.isSuspended { await Task.yield() }
        let retirement = Task { await coordinator.retire() }
        while !provider.observedCancellation { await Task.yield() }
        provider.release()
        await retirement.value
        await push.value

        #expect(provider.pushCount == 1)
        #expect(later.pushCount == 0)
        #expect(profile.session.pendingSync.isEmpty)
        await profile.tearDown()
    }

    @Test(.timeLimit(.minutes(1)))
    func retirementDuringPullLeavesProfileProgressUntouched() async throws {
        let profile = try SyncTestProfile()
        let coordinator = makeCoordinator(profile.session)
        let book = Book(id: "ownership-audiobook", title: "Ownership", duration: 600, source: .booklore)
        profile.session.appState.libraryCache.ensureBookInMemory(book)
        let remote = SuspendedSink(
            id: "test.remote", bookId: book.stableId,
            snapshot: SyncSnapshot(
                progress: 0.5, positionSeconds: 300, locator: nil,
                lastUpdate: book.lastUpdate.addingTimeInterval(60), isFinished: false, source: "Remote"
            )
        )
        profile.session.registry.register(sink: remote)

        let pull = Task { await coordinator.pullOnOpen(book: book, domain: .audiobook) }
        while !remote.isSuspended { await Task.yield() }
        await coordinator.retire()
        remote.release()
        await pull.value

        #expect(profile.session.bookProgress.loadProgress(for: book) == nil)
        #expect(BookProgressStore(defaults: profile.defaults).loadProgress(for: book) == nil)
        #expect(profile.session.appState.bookInMemory(stableId: book.stableId)?.currentTime == book.currentTime)
        #expect(profile.session.playbackHistory.entries.isEmpty)
        await profile.tearDown()
    }

    @Test func memberProfilesNeverReachOwnerOnlyIntegrations() async throws {
        let profile = try SyncTestProfile()
        let coordinator = makeCoordinator(profile.session)
        let book = Book(id: "member-book", title: "Member", duration: 600, source: .local)

        #expect(await coordinator.persistCurrentPlayback(reason: .timerInterval) == false)
        #expect(await coordinator.persistCurrentPlayback(book: book, position: 10, playbackRate: 1, isFinished: false) == false)
        #expect(await coordinator.getCloudProgress(for: book) == nil)

        await coordinator.retire()
        await profile.tearDown()
    }

    private func ebook() -> Book {
        var book = Book(id: "ownership-ebook", title: "Ownership", source: .booklore, mediaType: .ebook, ebookProgress: 0.4)
        book.lastUpdate = Date(timeIntervalSince1970: 1_000)
        return book
    }

    private func makeCoordinator(_ session: ProfileSession) -> SyncCoordinator {
        SyncCoordinator(
            providerResolver: NoProviderResolver(),
            pendingSyncFlusher: PendingSyncQueueFlusher(store: session.pendingSync, transport: RetainingTransport()),
            recentlyPlayedSync: IdleRecentlyPlayed(),
            profileSession: session
        )
    }
}
