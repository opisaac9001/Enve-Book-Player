import Foundation
import Testing

@testable import enve

struct JournalInsightsPolicyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func comparesMondayBasedWeeksAndBuildsStreaks() {
        let now = date("2026-07-29T12:00:00Z")
        let book = makeBook("book", author: "Author", narrator: "Narrator")
        let sessions = [
            session("mon", book: book, end: "2026-07-27T12:00:00Z", seconds: 3_600),
            session("tue", book: book, end: "2026-07-28T12:00:00Z", seconds: 1_800),
            session("sun", book: book, end: "2026-07-26T12:00:00Z", seconds: 7_200),
        ]

        let snapshot = JournalInsightsPolicy.snapshot(
            sessions: sessions,
            books: [book],
            year: 2026,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.thisWeekSeconds == 5_400)
        #expect(snapshot.lastWeekSeconds == 7_200)
        #expect(snapshot.currentStreak == 3)
        #expect(snapshot.longestStreak == 3)
    }

    @Test func annualReviewUsesOnlyTheSelectedYear() {
        var finished = makeBook("finished", author: "Octavia Butler", narrator: "Robin Miles")
        finished.isFinished = true
        finished.lastUpdate = date("2026-06-12T12:00:00Z")
        var future = makeBook("future", author: "Future Author", narrator: "Future Narrator")
        future.isFinished = true
        future.lastUpdate = date("2026-12-12T12:00:00Z")
        let older = session("older", book: finished, end: "2025-12-31T12:00:00Z", seconds: 9_000)
        let current = session("current", book: finished, end: "2026-06-10T12:00:00Z", seconds: 3_600)

        let snapshot = JournalInsightsPolicy.snapshot(
            sessions: [older, current],
            books: [finished, future],
            year: 2026,
            now: date("2026-07-29T12:00:00Z"),
            calendar: calendar
        )

        #expect(snapshot.yearReview.totalSeconds == 3_600)
        #expect(snapshot.yearReview.booksFinished == 1)
        #expect(snapshot.yearReview.topBook?.book.id == finished.id)
        #expect(snapshot.yearReview.topAuthor?.name == "Octavia Butler")
        #expect(snapshot.yearReview.topNarrator?.name == "Robin Miles")
        #expect(snapshot.availableYears == [2026, 2025])
    }

    private func makeBook(_ id: String, author: String, narrator: String) -> Book {
        Book(
            id: id,
            title: id,
            author: author,
            narrator: narrator,
            source: .local,
            backendId: "unit",
            providerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            libraryId: "library"
        )
    }

    private func session(
        _ id: String,
        book: Book,
        end: String,
        seconds: Int
    ) -> HistorySession {
        let endDate = date(end)
        return HistorySession(
            id: id,
            bookId: book.stableId,
            mediaType: AppMediaType.audiobook.rawValue,
            startTime: endDate.addingTimeInterval(TimeInterval(-seconds)),
            endTime: endDate,
            durationSeconds: seconds,
            startProgress: nil,
            endProgress: nil,
            progressDelta: nil,
            startLocation: nil,
            endLocation: nil,
            pagesRead: nil,
            source: .local
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
