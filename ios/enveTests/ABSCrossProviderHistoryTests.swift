import Foundation
import Testing

@testable import enve

@MainActor
struct ABSCrossProviderHistoryTests {
    private let connection = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func book() -> Book {
        var book = Book(
            id: "li_1", title: "Matched book", author: "Author", narrator: nil,
            source: .audiobookshelf, backendId: nil, providerId: connection, libraryId: "library"
        )
        book.duration = 3_600
        return book
    }

    private func source(duration: Int = 28) -> HistorySession {
        HistorySession(
            id: "played-session", bookId: "grimmory-book", mediaType: "audiobook",
            startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_060),
            durationSeconds: duration, startProgress: nil, endProgress: nil,
            progressDelta: nil, startLocation: nil, endLocation: nil,
            pagesRead: nil, source: .local
        )
    }

    @Test func actualTimeAndAccountIdentityAreStable() throws {
        let first = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        ))
        let retry = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        ))
        let other = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-b",
            targetBook: book(), currentProgress: 500
        ))
        #expect(first.id == retry.id)
        #expect(first.id != other.id)
        #expect(first.timeListening == 28)
        #expect(first.currentTime == 500)
        #expect(ABSCrossProviderHistory.session(
            from: source(duration: 90), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        )?.timeListening == 60)
    }

    @Test func enqueueKeepsRetryIdempotent() throws {
        let store = ABSLocalListeningStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        ))
        store.enqueueHistory(session)
        store.enqueueHistory(session)
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-a").count == 1)
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-b").isEmpty)
        #expect(store.pendingUploads(connectionId: connection).isEmpty)
    }
    @Test func retryRefreshesProgressAndKeepsNativeUploadWhenHistoryLookupFails() async throws {
        let history = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        ))
        let refreshed = try await AudiobookshelfProvider.prepareHistoryUploads([history]) { _ in 900 }
        #expect(refreshed.first?.currentTime == 900)
        #expect(history.currentTime == 500)
        var native = history
        native.accountId = nil
        let preserved = try await AudiobookshelfProvider.prepareHistoryUploads([history, native]) { _ in
            throw ProviderError.invalidResponse
        }
        #expect(preserved.count == 1)
        #expect(preserved.first?.accountId == nil)
    }

    @Test func cancelledHistoryLookupAbortsTheWholeBatch() async throws {
        let history = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        ))
        var native = history
        native.accountId = nil
        do {
            _ = try await AudiobookshelfProvider.prepareHistoryUploads([native, history]) { _ in
                throw CancellationError()
            }
            Issue.record("Cancellation must abort the upload batch")
        } catch is CancellationError {}
        do {
            _ = try await AudiobookshelfProvider.prepareHistoryUploads([native, history]) { _ in
                throw URLError(.cancelled)
            }
            Issue.record("Cancelled URLSession request must abort the upload batch")
        } catch is CancellationError {}
    }

    @Test func nativeSameDayRecordDoesNotMutateCrossProviderHistory() throws {
        let store = ABSLocalListeningStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let history = try #require(ABSCrossProviderHistory.session(
            from: source(), targetConnectionId: connection, targetAccountId: "user-a",
            targetBook: book(), currentProgress: 500
        ))
        store.enqueueHistory(history)
        store.record(
            connectionId: connection, libraryItemId: history.libraryItemId, episodeId: nil,
            displayTitle: history.displayTitle, displayAuthor: nil, duration: 3_600,
            currentTime: 900, listened: 15, now: source().endTime
        )
        let sessions = store.pendingUploads(connectionId: connection, verifiedAccountId: "user-a")
        #expect(sessions.count == 2)
        #expect(sessions.first(where: { $0.id == history.id })?.timeListening == history.timeListening)
        #expect(sessions.first(where: { $0.id == history.id })?.currentTime == history.currentTime)
        #expect(sessions.first(where: { $0.accountId == nil })?.timeListening == 15)
    }

    @Test func currentSessionUploadsWithoutProgressWhileBackfillWaits() {
        let confirmed = Date(timeIntervalSince1970: 2_000)
        let currentStart = confirmed.addingTimeInterval(1)
        let currentEnd = currentStart.addingTimeInterval(30)
        #expect(CrossProviderHistorySessionSync.canUpload(
            sessionStart: currentStart, sessionEnd: currentEnd,
            confirmedAt: confirmed, includeEarlierHistory: false, progressUpdatedAt: nil
        ))
        let oldStart = confirmed.addingTimeInterval(-100)
        let oldEnd = confirmed.addingTimeInterval(-70)
        #expect(!CrossProviderHistorySessionSync.canUpload(
            sessionStart: oldStart, sessionEnd: oldEnd,
            confirmedAt: confirmed, includeEarlierHistory: false, progressUpdatedAt: nil
        ))
        #expect(!CrossProviderHistorySessionSync.canUpload(
            sessionStart: oldStart, sessionEnd: oldEnd,
            confirmedAt: confirmed, includeEarlierHistory: true, progressUpdatedAt: oldEnd
        ))
        #expect(!CrossProviderHistorySessionSync.canUpload(
            sessionStart: oldStart, sessionEnd: oldEnd,
            confirmedAt: confirmed, includeEarlierHistory: false,
            progressUpdatedAt: oldEnd.addingTimeInterval(1)
        ))
        #expect(CrossProviderHistorySessionSync.canUpload(
            sessionStart: oldStart, sessionEnd: oldEnd,
            confirmedAt: confirmed, includeEarlierHistory: true,
            progressUpdatedAt: oldEnd.addingTimeInterval(1)
        ))
    }
}
