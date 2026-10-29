import Foundation
import Testing
@testable import enve

@MainActor
struct HardcoverReliabilityTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
    }

    private func update(account: String = "account-a", finished: Bool = false, progress: Double = 0.2) -> HardcoverPendingUpdate {
        HardcoverPendingUpdate(id: UUID(), account: account,
            book: HardcoverBookSnapshot(book: Book(id: "book", title: "Fixture", author: "Author", isbn: "9780306406157")),
            progress: progress, finished: finished, occurredAt: Date(timeIntervalSince1970: 100),
            startDate: "2026-10-01", eventDate: "2026-10-02", match: nil)
    }

    @Test func restartRestoresOfflineCompletionAndOriginalDate() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let event = update(finished: true, progress: 1)
        try HardcoverPendingStore(url: url).enqueue(event, inFlight: nil)
        let restored = HardcoverPendingStore(url: url)
        #expect(restored.updates.count == 1)
        #expect(restored.updates.first?.id == event.id)
        #expect(restored.updates.first?.eventDate == "2026-10-02")
        #expect(restored.updates.first?.book.isbn == "9780306406157")
        #expect(restored.updates.first?.finished == true)
    }

    @Test func completionRemainsBeforeLaterReread() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HardcoverPendingStore(url: url)
        let finish = update(finished: true, progress: 1)
        try store.enqueue(finish, inFlight: nil)
        try store.enqueue(update(progress: 0.05), inFlight: nil)
        try store.enqueue(update(progress: 0.1), inFlight: nil)
        #expect(store.updates.count == 2)
        #expect(store.heads(account: "account-a").first?.id == finish.id)
        try store.remove(id: finish.id)
        #expect(store.heads(account: "account-a").first?.progress == 0.1)
    }

    @Test func acknowledgementDoesNotRemoveNewerProgress() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HardcoverPendingStore(url: url)
        let old = update()
        try store.enqueue(old, inFlight: nil)
        let new = update(progress: 0.5)
        try store.enqueue(new, inFlight: old.id)
        try store.remove(id: old.id)
        #expect(store.updates.map(\.id) == [new.id])
    }

    @Test func accountsCannotDrainOrDeleteEachOthersUpdates() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HardcoverPendingStore(url: url)
        try store.enqueue(update(), inFlight: nil)
        try store.enqueue(update(account: "account-b"), inFlight: nil)
        #expect(store.heads(account: "account-a").count == 1)
        try store.discard(account: "account-a")
        #expect(HardcoverPendingStore(url: url).updates.map(\.account) == ["account-b"])
    }

    @Test func corruptedQueueIsPreservedAndNotOverwritten() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("invalid persisted queue".utf8)
        try bytes.write(to: url)
        let store = HardcoverPendingStore(url: url)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.enqueue(update(), inFlight: nil) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func diskWriteFailureDoesNotPretendAnUpdateIsQueued() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HardcoverPendingStore(url: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.enqueue(update(), inFlight: nil) }
        #expect(store.updates.isEmpty)
    }

    @Test func terminalFailureSurvivesRestartUntilExplicitRetry() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HardcoverPendingStore(url: url)
        var event = update()
        try store.enqueue(event, inFlight: nil)
        event.failure = "Choose an edition"
        event.attempts = 1
        try store.replace(event)
        let reopened = HardcoverPendingStore(url: url)
        #expect(reopened.heads(account: "account-a").first?.failure == "Choose an edition")
        try reopened.retry(account: "account-a")
        #expect(reopened.updates.first?.failure == nil)
        #expect(HardcoverPendingStore(url: url).updates.first?.attempts == 0)
    }

    @Test func identifiersValidateChecksumsAndNormalizeFormatting() {
        #expect(HardcoverIdentifiers(isbn: "978-0-306-40615-7", asin: " b012345678 ").isbn == "9780306406157")
        #expect(HardcoverIdentifiers(isbn: "0-8044-2957-X", asin: nil).isbn == "080442957X")
        #expect(HardcoverIdentifiers(isbn: "9780306406158", asin: "not-an-asin").isEmpty)
        #expect(HardcoverIdentifiers(isbn: nil, asin: " b012345678 ").asin == "B012345678")
    }

    @Test func conflictingIdentifierEditionsRequireManualChoice() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let editions = try decoder.decode([HardcoverIdentifierEdition].self, from: Data(#"[{"id":1,"book_id":11,"isbn_13":"9780306406157","book":{"id":11,"title":"One"}},{"id":2,"book_id":22,"asin":"B012345678","book":{"id":22,"title":"Two"}}]"#.utf8))
        #expect(throws: HardcoverSyncError.self) {
            try HardcoverIdentifierEdition.select(editions, identifiers: HardcoverIdentifiers(isbn: "9780306406157", asin: "B012345678"))
        }
        #expect(try HardcoverIdentifierEdition.select([editions[0]], identifiers: HardcoverIdentifiers(isbn: "9780306406157", asin: nil))?.id == 1)
    }

    @Test func longNumericAndHTTPDateRetryDelaysAreHonored() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(HardcoverRequestBudget.retryDate("120", now: now) == now.addingTimeInterval(120))
        #expect(HardcoverRequestBudget.retryDate("Thu, 01 Jan 1970 00:02:00 GMT", now: now) == now.addingTimeInterval(120))
        #expect(HardcoverRequestBudget.retryDate("NaN", now: now) == now.addingTimeInterval(60))
        var budget = HardcoverRequestBudget()
        budget.observe(status: 429, headers: ["Retry-After": "120"], now: now)
        #expect(budget.blockedUntil == now.addingTimeInterval(120))
        budget.observe(status: 200, headers: ["X-RateLimit-Remaining": "5"], now: now)
        #expect(budget.blockedUntil == now.addingTimeInterval(120))
    }

    @Test func structuredDailyLimitBlocksBeforeSending() {
        let now = Date(timeIntervalSince1970: 0)
        var budget = HardcoverRequestBudget()
        budget.observe(status: 200, headers: ["RateLimit": "\"Free\";r=4;t=1, \"daily\";r=0;t=3600"], now: now)
        #expect(budget.blockedUntil == now.addingTimeInterval(3600))
    }

    @Test func allRequestsSharePacingAndAccountsHaveSeparateBudgets() async throws {
        var now = Date(timeIntervalSince1970: 0)
        var waits: [Double] = []
        let pacer = HardcoverRequestPacer(now: { now }, sleep: { delay in waits.append(delay); now.addTimeInterval(delay) })
        try await pacer.acquire(account: "a", cost: 2, isCurrent: { true })
        try await pacer.acquire(account: "b", cost: 1, isCurrent: { true })
        try await pacer.acquire(account: "a", cost: 1, isCurrent: { true })
        #expect(waits == [2])
    }

    @Test func accountChangeWhileWaitingPreventsAdmission() async throws {
        var current = true
        let pacer = HardcoverRequestPacer(sleep: { _ in current = false })
        try await pacer.acquire(account: "a", cost: 1, isCurrent: { current })
        await #expect(throws: CancellationError.self) {
            try await pacer.acquire(account: "a", cost: 1, isCurrent: { current })
        }
    }

    @Test func permanentFailuresAreNotAutomaticallyRetried() {
        #expect(HardcoverSyncService.isTransient(URLError(.notConnectedToInternet)))
        #expect(HardcoverSyncService.isTransient(HardcoverError.httpError(statusCode: 503, message: "")))
        #expect(!HardcoverSyncService.isTransient(HardcoverError.graphQLError(message: "Invalid edition")))
        #expect(!HardcoverSyncService.isTransient(HardcoverError.httpError(statusCode: 403, message: "")))
    }

    @Test func rootFieldsAreCountedWithoutChargingNestedObjectsOrAliases() {
        #expect(HardcoverRequestPacer.requestCost("query { me { id user_books { id } } books(where: {title: {_eq: \"quoted { value\"}}) { id } }") == 2)
        #expect(HardcoverRequestPacer.requestCost("mutation { first: update_user_book(id: 1) { id } second: update_user_book(id: 2) { id } }") == 2)
    }
}
