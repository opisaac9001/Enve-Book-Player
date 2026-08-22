import Foundation
import Testing

@testable import enve

@MainActor
private final class PendingSyncTransportStub: PendingSyncTransporting {
    var results: [String: [Result<PendingSyncDisposition, Error>]] = [:]
    private(set) var attempts: [String] = []
    var waitsForRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition {
        attempts.append(stableId)
        if waitsForRelease {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        guard var queued = results[stableId], !queued.isEmpty else { return .remove }
        let result = queued.removeFirst()
        results[stableId] = queued
        return try result.get()
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class PendingSyncProviderResolverStub: LibraryProviderResolving {
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
private final class PendingSyncTestClock {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

@MainActor
struct PendingSyncQueueFlusherTests {
    @Test func providerTransportUsesInjectedBookLookup() async throws {
        var requestedStableIds: [String] = []
        let transport = ProviderPendingSyncTransport(
            providerResolver: PendingSyncProviderResolverStub(),
            bookLookup: { stableId in
                requestedStableIds.append(stableId)
                return nil
            }
        )

        let remote = PendingServerSync(
            stableId: "remote",
            sourceRaw: Book.BookSource.audiobookshelf.rawValue,
            backendId: UUID().uuidString,
            serverItemId: "server-remote",
            position: 10,
            duration: 100,
            updatedAt: 10
        )
        let local = PendingServerSync(
            stableId: "local",
            sourceRaw: Book.BookSource.local.rawValue,
            backendId: nil,
            serverItemId: "server-local",
            position: 10,
            duration: 100,
            updatedAt: 10
        )

        #expect(try await transport.push(stableId: "remote", entry: remote) == .retain)
        #expect(try await transport.push(stableId: "local", entry: local) == .remove)
        #expect(requestedStableIds == ["remote", "local"])
    }

    @Test func flushesReadyEntriesOnceInStableOrder() async {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "later", updatedAt: 20))
        fixture.store.enqueue(entry(id: "earlier", updatedAt: 10))
        let transport = PendingSyncTransportStub()
        let flusher = PendingSyncQueueFlusher(store: fixture.store, transport: transport)

        await flusher.flush()
        await flusher.flush()

        #expect(transport.attempts == ["earlier", "later"])
        #expect(fixture.store.isEmpty)
    }

    @Test func overlappingFlushesDoNotPushAnEntryTwice() async {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let transport = PendingSyncTransportStub()
        transport.waitsForRelease = true
        let flusher = PendingSyncQueueFlusher(store: fixture.store, transport: transport)

        let first = Task { @MainActor in await flusher.flush() }
        while transport.attempts.isEmpty {
            await Task.yield()
        }
        let overlapping = Task { @MainActor in await flusher.flush() }
        await overlapping.value

        #expect(transport.attempts == ["book"])
        transport.release()
        await first.value
        #expect(fixture.store.isEmpty)
    }

    @Test func retryUsesInjectedClockAndDoesNotPushDuringBackoff() async {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let transport = PendingSyncTransportStub()
        transport.results["book"] = [
            .failure(URLError(.timedOut)),
            .success(.remove),
        ]
        let clock = PendingSyncTestClock(Date(timeIntervalSince1970: 1_000))
        let flusher = PendingSyncQueueFlusher(
            store: fixture.store,
            transport: transport,
            now: { clock.date }
        )

        await flusher.flush()
        await flusher.flush()
        #expect(transport.attempts == ["book"])
        #expect(fixture.store.entries["book"]?.retryCount == 1)
        #expect(fixture.store.entries["book"]?.nextRetryAfter == 1_010)

        clock.date = Date(timeIntervalSince1970: 1_011)
        await flusher.flush()
        #expect(transport.attempts == ["book", "book"])
        #expect(fixture.store.isEmpty)
    }

    @Test func persistedEntriesRecoverAfterStoreRecreation() {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))

        let restored = PendingSyncQueueStore(
            defaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        #expect(restored.entries["book"] == fixture.store.entries["book"])
    }

    @Test func ebookRetryStateSurvivesStoreRecreation() {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(
            PendingServerSync(
                stableId: "ebook",
                sourceRaw: Book.BookSource.booklore.rawValue,
                backendId: UUID().uuidString,
                serverItemId: "server-ebook",
                position: 0,
                duration: 0,
                updatedAt: 10,
                domainRaw: "ebook",
                progress: 0.42,
                locator: #"{"href":"chapter-4.xhtml"}"#,
                isFinished: false
            )
        )

        let restored = PendingSyncQueueStore(
            defaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        #expect(restored.entries["ebook"]?.domain == .ebook)
        #expect(restored.entries["ebook"]?.progress == 0.42)
        #expect(restored.entries["ebook"]?.locator == #"{"href":"chapter-4.xhtml"}"#)
        #expect(restored.entries["ebook"]?.isFinished == false)
    }

    @Test func legacyAudiobookEntriesDecodeWithoutNewDomainFields() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let legacyQueue: [String: Any] = [
            "legacy": [
                "stableId": "legacy",
                "sourceRaw": Book.BookSource.local.rawValue,
                "serverItemId": "server-legacy",
                "position": 30.0,
                "duration": 100.0,
                "updatedAt": 10.0,
                "retryCount": 2,
                "nextRetryAfter": 20.0,
            ]
        ]
        fixture.defaults.set(
            try JSONSerialization.data(withJSONObject: legacyQueue),
            forKey: fixture.storageKey
        )

        let restored = PendingSyncQueueStore(
            defaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        #expect(restored.entries["legacy"]?.domain == .audiobook)
        #expect(restored.entries["legacy"]?.position == 30)
        #expect(restored.entries["legacy"]?.retryCount == 2)
    }

    @Test func authenticationFailureSuspendsAndPermanentFailureDrops() async {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "auth", updatedAt: 10))
        fixture.store.enqueue(entry(id: "missing", updatedAt: 20))
        let transport = PendingSyncTransportStub()
        transport.results["auth"] = [.failure(ProviderError.serverError("Authentication failed (HTTP 401)"))]
        transport.results["missing"] = [.failure(ProviderError.serverError("HTTP 404: progress record missing"))]
        let flusher = PendingSyncQueueFlusher(store: fixture.store, transport: transport)

        await flusher.flush()

        #expect(fixture.store.entries["auth"]?.nextRetryAfter == Date.distantFuture.timeIntervalSince1970)
        #expect(fixture.store.entries["missing"] == nil)
    }

    @Test func suspendedEntriesResumeAndPersistAfterAuthenticationRecovery() {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "auth", updatedAt: 10))
        fixture.store.suspend(stableId: "auth")

        fixture.store.resumeSuspended()

        #expect(fixture.store.entriesReady().keys.contains("auth"))
        let restored = PendingSyncQueueStore(
            defaults: fixture.defaults,
            storageKey: fixture.storageKey
        )
        #expect(restored.entriesReady().keys.contains("auth"))
    }

    private func entry(id: String, updatedAt: TimeInterval) -> PendingServerSync {
        PendingServerSync(
            stableId: id,
            sourceRaw: Book.BookSource.local.rawValue,
            backendId: nil,
            serverItemId: "server-\(id)",
            position: 10,
            duration: 100,
            updatedAt: updatedAt
        )
    }

    private func makeStore() -> (
        store: PendingSyncQueueStore,
        defaults: UserDefaults,
        suiteName: String,
        storageKey: String
    ) {
        let suiteName = "PendingSyncQueueFlusherTests.\(UUID().uuidString)"
        let storageKey = "queue"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            PendingSyncQueueStore(defaults: defaults, storageKey: storageKey),
            defaults,
            suiteName,
            storageKey
        )
    }
}
