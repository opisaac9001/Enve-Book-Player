import Foundation
import Testing

@testable import enve

@MainActor
private final class BookEditTransportStub: PendingBookEditTransporting {
    var results: [Result<PendingBookEditDisposition, any Error>] = []
    private(set) var sent: [PendingBookEdit] = []
    var beforeSending: (@MainActor () -> Void)?
    var beforeReturning: (@MainActor (PendingBookEdit) -> Void)?

    func send(_ edit: PendingBookEdit, isCurrent: @escaping @MainActor () -> Bool) async throws -> PendingBookEditDisposition {
        beforeSending?()
        guard isCurrent() else { return .unavailable }
        sent.append(edit)
        beforeReturning?(edit)
        guard !results.isEmpty else { return .delivered }
        return try results.removeFirst().get()
    }
}

@MainActor
private final class BookEditClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
struct PendingBookEditQueueTests {
    @MainActor
    private final class Fixture {
        let suiteName = "pending-book-edits-\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: PendingBookEditStore
        let transport = BookEditTransportStub()
        let clock = BookEditClock()
        var connections: [UUID: ServerConnection] = [:]
        var enabled = true
        private(set) var acknowledged: [PendingBookEdit] = []
        private(set) lazy var queue: PendingBookEditQueue = {
            let queue = PendingBookEditQueue(
                store: store,
                transport: transport,
                connection: { [unowned self] in self.connections[$0] },
                isEnabled: { [unowned self] in self.enabled },
                now: { [clock] in clock.date }
            )
            queue.onAcknowledged = { [unowned self] in self.acknowledged.append($0) }
            return queue
        }()

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            store = PendingBookEditStore(defaults: defaults)
        }

        func connect(username: String = "reader") -> ServerConnection {
            let connection = ServerConnection(
                name: "Fixture", url: "http://localhost:3000", type: .bookOrbit, username: username, isConnected: true
            )
            connections[connection.id] = connection
            return connection
        }

        func book(_ id: String, on connection: ServerConnection) -> Book {
            Book(id: id, title: "Fixture \(id)", providerId: connection.id, source: .bookOrbit)
        }

        func reopenedStore() -> PendingBookEditStore {
            PendingBookEditStore(defaults: defaults)
        }

        func close() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test func editsAreScopedByConnectionAccountBookAndKind() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.connect()
        let second = fixture.connect()
        let bookOnFirst = fixture.book("7", on: first)
        let sameIdOnSecond = fixture.book("7", on: second)

        fixture.queue.submit(.rating(4), for: bookOnFirst)
        fixture.queue.submit(.readStatus("reading"), for: bookOnFirst)
        fixture.queue.submit(.rating(2), for: sameIdOnSecond)

        #expect(fixture.store.entries.count == 3)
        #expect(fixture.queue.pendingRating(for: bookOnFirst) == 4)
        #expect(fixture.queue.pendingRating(for: sameIdOnSecond) == 2)
        #expect(fixture.queue.pendingEdit(for: bookOnFirst, kind: .readStatus)?.value == .readStatus("reading"))
        #expect(fixture.queue.pendingEdit(for: fixture.book("8", on: first), kind: .rating) == nil)

        // The same connection signed in as someone else neither sees nor sends the first account's edit.
        fixture.connections[first.id]?.username = "someone-else"
        #expect(fixture.queue.pendingRating(for: bookOnFirst) == nil)
    }

    @Test func latestEditReplacesEarlierOneForTheSameBookAndKind() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())

        let earlier = try #require(fixture.queue.submit(.rating(2), for: book))
        fixture.clock.date.addTimeInterval(1)
        let latest = try #require(fixture.queue.submit(.rating(5), for: book))

        #expect(fixture.store.entries.count == 1)
        #expect(earlier.revision != latest.revision)
        #expect(fixture.queue.pendingRating(for: book) == 5)
        #expect(!fixture.store.isCurrent(earlier))
    }

    @Test func pendingEditsSurviveRelaunchWithTheirDeliveryState() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        let edit = try #require(fixture.queue.submit(.readStatus("on_hold"), for: book))
        fixture.store.markRetry(
            edit,
            failure: PendingBookEditFailure(category: .transient, message: "This device is offline.", occurredAt: 1),
            at: fixture.clock.date
        )

        let reopened = fixture.reopenedStore()
        let restored = try #require(reopened.entry(for: edit.key))
        #expect(restored.revision == edit.revision)
        #expect(restored.value == .readStatus("on_hold"))
        #expect(restored.retryCount == 1)
        #expect(restored.lastFailure?.message == "This device is offline.")
        #expect(reopened.entriesReady(at: fixture.clock.date).isEmpty)
        #expect(reopened.entriesReady(at: fixture.clock.date.addingTimeInterval(restored.backoffDelay)).count == 1)
    }

    @Test func deliveredEditIsAcknowledgedAndRemoved() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        let edit = try #require(fixture.queue.submit(.rating(3), for: book))

        await fixture.queue.flush()

        #expect(fixture.transport.sent.map(\.revision) == [edit.revision])
        #expect(fixture.store.isEmpty)
        #expect(fixture.acknowledged.map(\.revision) == [edit.revision])
        #expect(fixture.queue.status(for: book, kind: .rating) == nil)
    }

    @Test func acknowledgementOfAnOlderRevisionKeepsTheNewerEditAndSendsIt() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        let first = try #require(fixture.queue.submit(.rating(1), for: book))
        var replaced = false
        fixture.transport.beforeReturning = { _ in
            guard !replaced else { return }
            replaced = true
            fixture.queue.submit(.rating(5), for: book)
        }

        await fixture.queue.flush()

        #expect(fixture.transport.sent.count == 2)
        #expect(fixture.transport.sent.first?.revision == first.revision)
        #expect(fixture.transport.sent.last?.value == .rating(5))
        #expect(fixture.acknowledged.map(\.value) == [.rating(5)])
        #expect(fixture.store.isEmpty)
    }

    @Test func transientFailureKeepsTheEditAndBacksOff() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        fixture.queue.submit(.rating(4), for: book)
        fixture.transport.results = [.failure(URLError(.notConnectedToInternet))]

        await fixture.queue.flush()

        #expect(fixture.queue.pendingRating(for: book) == 4)
        #expect(fixture.queue.status(for: book, kind: .rating) == .retrying(message: "This device is offline."))
        #expect(fixture.acknowledged.isEmpty)

        // Still inside the backoff window: no hot retry.
        await fixture.queue.flush()
        #expect(fixture.transport.sent.count == 1)

        fixture.clock.date.addTimeInterval(11)
        await fixture.queue.flush()
        #expect(fixture.transport.sent.count == 2)
        #expect(fixture.store.isEmpty)
    }

    @Test func manualRetrySkipsTheBackoff() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        fixture.queue.submit(.readStatus("read"), for: book)
        fixture.transport.results = [.failure(ProviderError.serverError("Failed to update BookOrbit read status (HTTP 503)"))]
        await fixture.queue.flush()
        #expect(fixture.queue.status(for: book, kind: .readStatus) == .retrying(message: "The server returned an error (HTTP 503)."))

        await fixture.queue.retry(book, kind: .readStatus)

        #expect(fixture.transport.sent.count == 2)
        #expect(fixture.store.isEmpty)
    }

    @Test func authenticationFailureParksTheEditUntilTheConnectionIsVerifiedAgain() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let connection = fixture.connect()
        let book = fixture.book("7", on: connection)
        fixture.queue.submit(.rating(4), for: book)
        fixture.transport.results = [.failure(ProviderError.unauthorized)]

        await fixture.queue.flush()
        #expect(fixture.queue.status(for: book, kind: .rating) == .needsSignIn)

        fixture.clock.date.addTimeInterval(3_600)
        await fixture.queue.flush()
        #expect(fixture.transport.sent.count == 1)
        #expect(fixture.queue.pendingRating(for: book) == 4)

        fixture.connections[connection.id]?.lastVerified = fixture.clock.date
        fixture.clock.date.addTimeInterval(1)
        await fixture.queue.flush()
        #expect(fixture.transport.sent.count == 2)
        #expect(fixture.store.isEmpty)
    }

    @Test func refusedEditIsReportedAndOnlyRetriedOrDiscardedByTheUser() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        fixture.queue.submit(.rating(4), for: book)
        fixture.transport.results = [.failure(ProviderError.serverError("Failed to update BookOrbit rating (HTTP 403)"))]

        await fixture.queue.flush()
        guard case .rejected = fixture.queue.status(for: book, kind: .rating) else {
            Issue.record("A refused edit must not read as waiting or synced")
            return
        }
        #expect(fixture.acknowledged.isEmpty)

        fixture.clock.date.addTimeInterval(86_400)
        await fixture.queue.flush()
        #expect(fixture.transport.sent.count == 1)

        #expect(fixture.queue.discard(book, kind: .rating))
        #expect(fixture.store.isEmpty)
    }

    @Test func cancellationLeavesTheEditUntouched() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        let edit = try #require(fixture.queue.submit(.rating(4), for: book))
        fixture.transport.results = [.failure(CancellationError())]

        await fixture.queue.flush()

        #expect(fixture.store.entry(for: edit.key) == edit)
        #expect(fixture.queue.status(for: book, kind: .rating) == .waiting)
    }

    @Test func disabledSyncAndForeignAccountsSendNothing() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let connection = fixture.connect()
        let book = fixture.book("7", on: connection)
        let edit = try #require(fixture.queue.submit(.rating(4), for: book))

        fixture.enabled = false
        await fixture.queue.flush()
        #expect(fixture.transport.sent.isEmpty)

        fixture.enabled = true
        fixture.connections[connection.id]?.username = "someone-else"
        await fixture.queue.flush()
        #expect(fixture.transport.sent.isEmpty)
        #expect(fixture.store.entry(for: edit.key) == edit)

        fixture.connections[connection.id]?.username = "reader"
        await fixture.queue.flush()
        #expect(fixture.store.isEmpty)
    }

    @Test func unavailableProviderRetainsAndObsoleteBookDrops() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        fixture.queue.submit(.rating(4), for: book)
        fixture.transport.results = [.success(.unavailable), .success(.obsolete)]

        await fixture.queue.flush()
        #expect(fixture.queue.status(for: book, kind: .rating) == .waiting)

        await fixture.queue.flush()
        #expect(fixture.store.isEmpty)
        #expect(fixture.acknowledged.isEmpty)
    }
    @Test func reconnectionRetriesBeforeThePreviousBackoffExpires() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let book = fixture.book("7", on: fixture.connect())
        fixture.transport.results = [.failure(URLError(.notConnectedToInternet)), .success(.delivered)]
        fixture.queue.submit(.rating(4), for: book)
        await fixture.queue.flush()
        #expect(fixture.transport.sent.count == 1)
        await fixture.queue.flush(afterReconnect: true)
        #expect(fixture.transport.sent.count == 2)
        #expect(fixture.store.isEmpty)
    }

    @Test func changingAccountsWhileDeliveryWaitsKeepsTheEditUnsent() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let connection = fixture.connect()
        let book = fixture.book("7", on: connection)
        fixture.queue.submit(.rating(4), for: book)
        fixture.transport.beforeSending = { fixture.connections[connection.id]?.username = "other-reader" }
        await fixture.queue.flush()
        #expect(fixture.transport.sent.isEmpty)
        #expect(fixture.store.entries.count == 1)
    }

}
