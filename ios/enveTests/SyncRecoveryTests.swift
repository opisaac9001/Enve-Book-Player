import Foundation
import Testing

@testable import enve

@MainActor
private final class SyncRecoveryTransportStub: PendingSyncTransporting {
    var results: [String: [Result<PendingSyncDisposition, Error>]] = [:]
    private(set) var attempts: [String] = []

    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition {
        attempts.append(stableId)
        guard var queued = results[stableId], !queued.isEmpty else { return .remove }
        let result = queued.removeFirst()
        results[stableId] = queued
        return try result.get()
    }
}

@MainActor
struct SyncRecoveryTests {
    @Test func retryNowResetsBackoffForOnlyTheSelectedCheckpoint() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "selected", updatedAt: 10))
        fixture.store.enqueue(entry(id: "other", updatedAt: 20))
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<3 {
            fixture.store.markRetry(stableId: "selected", at: now)
            fixture.store.markRetry(stableId: "other", at: now)
        }
        let selected = try #require(fixture.store.entries["selected"])

        #expect(fixture.store.retryNow(selected))

        #expect(fixture.store.entries["selected"]?.retryCount == 0)
        #expect(fixture.store.entriesReady(at: now).keys.sorted() == ["selected"])
        #expect(fixture.store.entries["other"]?.retryCount == 3)
    }

    @Test func retryNowRefusesAReplacedCheckpoint() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let selected = try #require(fixture.store.entries["book"])
        let newer = entry(id: "book", updatedAt: 30, position: 90)
        fixture.store.enqueue(newer)
        fixture.store.markRetry(stableId: "book", at: Date(timeIntervalSince1970: 1_000))

        #expect(!fixture.store.retryNow(selected))
        #expect(fixture.store.entries["book"]?.retryCount == 1)
        #expect(fixture.store.entries["book"]?.position == 90)
    }

    @Test func retryNowIgnoresBookkeepingChangesToTheSameCheckpoint() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let selected = try #require(fixture.store.entries["book"])
        fixture.store.markRetry(stableId: "book", failure: transient, at: Date(timeIntervalSince1970: 1_000))

        #expect(fixture.store.retryNow(selected))
        #expect(fixture.store.entries["book"]?.nextRetryAfter == 0)
    }

    @Test func retryNowLeavesValidationFailuresBlocked() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        fixture.store.suspend(stableId: "book", validationFailureMessage: "Invalid reading position")
        let selected = try #require(fixture.store.entries["book"])

        #expect(!fixture.store.retryNow(selected))
        #expect(fixture.store.entries["book"]?.isSuspended == true)
        #expect(fixture.store.entries["book"]?.deliveryStatus() == .validation(message: "Invalid reading position"))
    }

    @Test func retryNowKeepsTheDownloadedBaselineOfAConflict() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let baseline = DownloadedProgressBaseline(position: 10, updatedAt: Date(timeIntervalSince1970: 10), isFinished: false)
        var guarded = entry(id: "book", updatedAt: 10)
        guarded.downloadedBaseline = baseline
        fixture.store.enqueue(guarded)
        fixture.store.markRetry(stableId: "book", failure: conflict, at: Date(timeIntervalSince1970: 1_000))
        let selected = try #require(fixture.store.entries["book"])

        #expect(fixture.store.retryNow(selected))
        #expect(fixture.store.entries["book"]?.downloadedBaseline == baseline)
        #expect(fixture.store.entries["book"]?.deliveryStatus() == .conflict)
    }

    @Test func discardRemovesOnlyTheSelectedUnchangedCheckpoint() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "selected", updatedAt: 10))
        fixture.store.enqueue(entry(id: "other", updatedAt: 20))
        let selected = try #require(fixture.store.entries["selected"])

        #expect(fixture.store.discard(selected))

        #expect(fixture.store.entries["selected"] == nil)
        #expect(fixture.store.entries["other"] != nil)
        let restored = PendingSyncQueueStore(defaults: fixture.defaults, storageKey: fixture.storageKey)
        #expect(restored.entries.keys.sorted() == ["other"])
    }

    @Test func discardNeverRemovesANewerCheckpointThatArrivedDuringConfirmation() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let selected = try #require(fixture.store.entries["book"])
        let newer = entry(id: "book", updatedAt: 30, position: 90)

        fixture.store.enqueue(newer)

        #expect(!fixture.store.discard(selected))
        #expect(fixture.store.entries["book"] == newer)
    }

    @Test func discardRefusesAConflictedCheckpoint() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var guarded = entry(id: "book", updatedAt: 10)
        guarded.downloadedBaseline = DownloadedProgressBaseline(position: 10, updatedAt: Date(timeIntervalSince1970: 10), isFinished: false)
        fixture.store.enqueue(guarded)
        let selected = try #require(fixture.store.entries["book"])
        fixture.store.markRetry(stableId: "book", failure: conflict, at: Date(timeIntervalSince1970: 1_000))

        #expect(!fixture.store.discard(selected))
        #expect(fixture.store.entries["book"]?.downloadedBaseline != nil)
    }

    @Test func discardOfADeliveredCheckpointIsANoOp() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let selected = try #require(fixture.store.entries["book"])
        fixture.store.remove(stableId: "book")

        #expect(!fixture.store.discard(selected))
        #expect(!fixture.store.retryNow(selected))
    }

    @Test func failureSurvivesStoreRecreation() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        fixture.store.markRetry(stableId: "book", failure: transient, at: Date(timeIntervalSince1970: 1_000))

        let restored = PendingSyncQueueStore(defaults: fixture.defaults, storageKey: fixture.storageKey)

        #expect(restored.entries["book"]?.lastFailure == transient)
        #expect(restored.entries["book"] == fixture.store.entries["book"])
    }

    @Test func entriesPersistedBeforeFailureTrackingStillDecode() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let legacyQueue: [String: Any] = [
            "legacy": [
                "stableId": "legacy",
                "sourceRaw": Book.BookSource.audiobookshelf.rawValue,
                "serverItemId": "server-legacy",
                "position": 30.0,
                "duration": 100.0,
                "updatedAt": 10.0,
                "retryCount": 2,
                "nextRetryAfter": 20.0,
                "validationFailureMessage": "Invalid reading position",
            ]
        ]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacyQueue), forKey: fixture.storageKey)

        let restored = PendingSyncQueueStore(defaults: fixture.defaults, storageKey: fixture.storageKey)

        #expect(restored.entries["legacy"]?.lastFailure == nil)
        #expect(restored.entries["legacy"]?.deliveryStatus() == .validation(message: "Invalid reading position"))
    }

    @Test func newCheckpointClearsThePreviousFailure() {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        fixture.store.markRetry(stableId: "book", failure: transient, at: Date(timeIntervalSince1970: 1_000))

        fixture.store.enqueue(entry(id: "book", updatedAt: 20))

        #expect(fixture.store.entries["book"]?.deliveryStatus() == .waiting)
    }

    @Test func authenticationRecoveryClearsTheAuthenticationStatus() {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        fixture.store.suspend(
            stableId: "book",
            failure: PendingSyncFailure(category: .authentication, message: "Sign in", occurredAt: 1_000)
        )
        #expect(fixture.store.entries["book"]?.deliveryStatus() == .authentication)

        fixture.store.resumeSuspended()

        #expect(fixture.store.entries["book"]?.deliveryStatus() == .waiting)
    }

    @Test func retryingStatusReportsTheNextAttemptOnlyWhileInBackoff() throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        fixture.store.markRetry(stableId: "book", failure: transient, at: Date(timeIntervalSince1970: 1_000))
        let pending = try #require(fixture.store.entries["book"])

        #expect(
            pending.deliveryStatus(at: Date(timeIntervalSince1970: 1_001))
                == .retrying(lastFailure: transient, nextAttempt: Date(timeIntervalSince1970: 1_010))
        )
        #expect(
            pending.deliveryStatus(at: Date(timeIntervalSince1970: 1_011))
                == .retrying(lastFailure: transient, nextAttempt: nil)
        )
    }

    @Test(arguments: [
        (URLError(.notConnectedToInternet) as Error, "This device is offline."),
        (URLError(.timedOut) as Error, "The server took too long to respond."),
        (URLError(.cannotConnectToHost) as Error, "The server couldn't be reached."),
        (URLError(.serverCertificateUntrusted) as Error, "A secure connection to the server couldn't be made."),
        (ProviderError.serverError("HTTP 503 from http://10.0.0.1/api?token=secret") as Error, "The server returned an error (HTTP 503)."),
        (ProviderError.networkError("http://10.0.0.1/api?token=secret") as Error, "The update couldn't be sent."),
    ])
    func flusherRecordsASanitizedTransientFailure(error: Error, message: String) async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let transport = SyncRecoveryTransportStub()
        transport.results["book"] = [.failure(error)]
        let flusher = PendingSyncQueueFlusher(
            store: fixture.store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) }
        )

        await flusher.flush()

        let failure = try #require(fixture.store.entries["book"]?.lastFailure)
        #expect(failure.category == .transient)
        #expect(failure.message == message)
        #expect(failure.occurredAt == 1_000)
        #expect(!failure.message.contains("token"))
        #expect(!failure.message.contains("10.0.0.1"))
    }

    @Test(arguments: [
        ProviderError.serverError("HTTP 401") as Error,
        ProviderError.serverError("HTTP 403") as Error,
        ProviderError.unauthorized as Error,
    ])
    func flusherSuspendsAuthenticationFailuresWithACategory(error: Error) async {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let transport = SyncRecoveryTransportStub()
        transport.results["book"] = [.failure(error)]
        let flusher = PendingSyncQueueFlusher(store: fixture.store, transport: transport)

        await flusher.flush()

        #expect(fixture.store.entries["book"]?.isSuspended == true)
        #expect(fixture.store.entries["book"]?.lastFailure?.category == .authentication)
        #expect(fixture.store.entries["book"]?.deliveryStatus() == .authentication)
    }

    @Test func flusherRecordsAConflictWithoutDroppingTheBaseline() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let baseline = DownloadedProgressBaseline(position: 10, updatedAt: Date(timeIntervalSince1970: 10), isFinished: false)
        var guarded = entry(id: "book", updatedAt: 10)
        guarded.downloadedBaseline = baseline
        fixture.store.enqueue(guarded)
        let transport = SyncRecoveryTransportStub()
        transport.results["book"] = [.failure(DownloadedProgressConflict(serverPosition: 50))]
        let flusher = PendingSyncQueueFlusher(store: fixture.store, transport: transport)
        var conflicts: [(String, TimeInterval)] = []
        flusher.onDownloadedConflict = { conflicts.append(($0, $1)) }

        await flusher.flush()

        let pending = try #require(fixture.store.entries["book"])
        #expect(pending.downloadedBaseline == baseline)
        #expect(pending.deliveryStatus() == .conflict)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.1 == 50)
    }

    @Test func flusherKeepsValidationHandlingAndDoesNotRecordAGenericFailure() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let transport = SyncRecoveryTransportStub()
        let validation = ProgressValidationError(message: "This reading position can't be sent.")
        transport.results["book"] = [.failure(validation)]
        let flusher = PendingSyncQueueFlusher(store: fixture.store, transport: transport)

        await flusher.flush()

        let pending = try #require(fixture.store.entries["book"])
        #expect(pending.lastFailure == nil)
        #expect(pending.validationFailureMessage == validation.localizedDescription)
        #expect(pending.deliveryStatus() == .validation(message: validation.localizedDescription))
    }

    @Test func retriedCheckpointFlushesOnTheNextPass() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.enqueue(entry(id: "book", updatedAt: 10))
        let transport = SyncRecoveryTransportStub()
        transport.results["book"] = [.failure(URLError(.timedOut)), .success(.remove)]
        let flusher = PendingSyncQueueFlusher(
            store: fixture.store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) }
        )
        await flusher.flush()
        await flusher.flush()
        #expect(transport.attempts == ["book"])

        let selected = try #require(fixture.store.entries["book"])
        #expect(fixture.store.retryNow(selected))
        await flusher.flush()

        #expect(transport.attempts == ["book", "book"])
        #expect(fixture.store.isEmpty)
    }

    private var transient: PendingSyncFailure {
        PendingSyncFailure(category: .transient, message: "The server took too long to respond.", occurredAt: 1_000)
    }

    private var conflict: PendingSyncFailure {
        PendingSyncFailure(category: .conflict, message: "The server has newer progress than this download.", occurredAt: 1_000)
    }

    private func entry(id: String, updatedAt: TimeInterval, position: TimeInterval = 10) -> PendingServerSync {
        PendingServerSync(
            stableId: id,
            sourceRaw: Book.BookSource.audiobookshelf.rawValue,
            backendId: nil,
            serverItemId: "server-\(id)",
            position: position,
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
        let suiteName = "SyncRecoveryTests.\(UUID().uuidString)"
        let storageKey = "queue"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (PendingSyncQueueStore(defaults: defaults, storageKey: storageKey), defaults, suiteName, storageKey)
    }
}
