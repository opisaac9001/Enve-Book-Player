import Foundation
import Testing

@testable import enve

struct JournalRecapTests {
    private let utc = JournalRecapTests.calendar("UTC")
    private let pacific = JournalRecapTests.calendar("America/Los_Angeles")
    private let english = Locale(identifier: "en_US")

    @Test func monthPeriodsAreEndExclusive() {
        let february = JournalRecapPeriod.containing(date("2026-02-15T12:00:00Z"), scope: .month, calendar: utc)
        let book = makeBook("book")
        let boundary = session("boundary", book: book, end: "2026-03-01T00:00:00Z", seconds: 600)
        let lastSecond = session("last", book: book, end: "2026-02-28T23:59:59Z", seconds: 300)

        #expect(february.start == date("2026-02-01T00:00:00Z"))
        #expect(february.end == date("2026-03-01T00:00:00Z"))
        #expect(february.title(calendar: utc, locale: english) == "February 2026")

        let feb = recap([boundary, lastSecond], books: [book], period: february, now: date("2026-06-01T00:00:00Z"))
        let march = recap([boundary, lastSecond], books: [book], period: february.shifted(by: 1, calendar: utc), now: date("2026-06-01T00:00:00Z"))
        #expect(feb.activity.totalSeconds == 300)
        #expect(march.activity.totalSeconds == 600)
    }

    @Test func leapYearFebruaryIncludesTheTwentyNinth() {
        let february = JournalRecapPeriod.containing(date("2024-02-10T00:00:00Z"), scope: .month, calendar: utc)
        let book = makeBook("book")
        let leapDay = session("leap", book: book, end: "2024-02-29T23:59:59Z", seconds: 900)

        #expect(february.end.timeIntervalSince(february.start) == 29 * 86_400)
        #expect(recap([leapDay], books: [book], period: february, now: date("2026-01-01T00:00:00Z")).activity.sessions == 1)
    }

    @Test func yearPeriodsSplitAtNewYear() {
        let book = makeBook("book")
        let sessions = [
            session("eve", book: book, end: "2026-12-31T23:59:59Z", seconds: 1_200),
            session("day", book: book, end: "2027-01-01T00:00:00Z", seconds: 2_400),
        ]
        let year2026 = JournalRecapPeriod.containing(date("2026-06-01T00:00:00Z"), scope: .year, calendar: utc)
        let now = date("2027-03-01T00:00:00Z")

        #expect(year2026.title(calendar: utc, locale: english) == "2026")
        #expect(recap(sessions, books: [book], period: year2026, now: now).activity.totalSeconds == 1_200)
        #expect(recap(sessions, books: [book], period: year2026.shifted(by: 1, calendar: utc), now: now).activity.totalSeconds == 2_400)
    }

    @Test func boundariesAndActiveDaysFollowTheCalendarTimeZone() {
        let book = makeBook("book")
        let halloweenNight = session("halloween", book: book, end: "2026-11-01T06:30:00Z", seconds: 600)
        let now = date("2026-12-15T00:00:00Z")

        let pacificNovember = JournalRecapPeriod.containing(date("2026-11-15T12:00:00Z"), scope: .month, calendar: pacific)
        #expect(pacificNovember.start == date("2026-11-01T07:00:00Z"))
        #expect(pacificNovember.end == date("2026-12-01T08:00:00Z"))

        let pacificOctober = pacificNovember.shifted(by: -1, calendar: pacific)
        let utcNovember = JournalRecapPeriod.containing(date("2026-11-15T12:00:00Z"), scope: .month, calendar: utc)
        #expect(recap([halloweenNight], books: [book], period: pacificOctober, now: now, calendar: pacific).activity.sessions == 1)
        #expect(recap([halloweenNight], books: [book], period: pacificNovember, now: now, calendar: pacific).isEmpty)
        #expect(recap([halloweenNight], books: [book], period: utcNovember, now: now, calendar: utc).activity.sessions == 1)

        let lateAndEarly = [
            session("late", book: book, end: "2026-07-10T06:00:00Z", seconds: 600),
            session("early", book: book, end: "2026-07-10T08:00:00Z", seconds: 600),
        ]
        let pacificJuly = JournalRecapPeriod.containing(date("2026-07-15T12:00:00Z"), scope: .month, calendar: pacific)
        let utcJuly = JournalRecapPeriod.containing(date("2026-07-15T12:00:00Z"), scope: .month, calendar: utc)
        #expect(recap(lateAndEarly, books: [book], period: pacificJuly, now: now, calendar: pacific).activity.activeDays == 2)
        #expect(recap(lateAndEarly, books: [book], period: utcJuly, now: now, calendar: utc).activity.activeDays == 1)
    }

    @Test func duplicateFutureAndNonpositiveSessionsAreIgnored() {
        let book = makeBook("book")
        let now = date("2026-11-14T12:00:00Z")
        let kept = session("kept", book: book, end: "2026-11-02T20:00:00Z", seconds: 600)
        let sessions = [
            kept,
            kept,
            session("future", book: book, end: "2026-11-20T20:00:00Z", seconds: 3_600),
            session("zero", book: book, end: "2026-11-03T20:00:00Z", seconds: 0),
            session("negative", book: book, end: "2026-11-04T20:00:00Z", seconds: -60),
            session("next-month", book: book, end: "2026-12-02T20:00:00Z", seconds: 3_600),
        ]
        let november = JournalRecapPeriod.containing(now, scope: .month, calendar: utc)
        let result = recap(sessions, books: [book], period: november, now: now)

        #expect(result.isInProgress)
        #expect(result.activity.sessions == 1)
        #expect(result.activity.totalSeconds == 600)
        #expect(result.activity.activeDays == 1)
        #expect(JournalInsightsPolicy.earliestActivity(sessions, now: now) == kept.endTime)
    }

    @Test func emptyMonthsStayEmpty() {
        let book = makeBook("book")
        let sessions = [
            session("august", book: book, end: "2026-08-20T12:00:00Z", seconds: 600),
            session("october", book: book, end: "2026-10-05T12:00:00Z", seconds: 600),
        ]
        let now = date("2026-11-14T12:00:00Z")
        let september = JournalRecapPeriod.containing(date("2026-09-10T00:00:00Z"), scope: .month, calendar: utc)
        let result = recap(sessions, books: [book], period: september, now: now)

        #expect(result.isEmpty)
        #expect(!result.isInProgress)
        #expect(result.activity.totalSeconds == 0)
        #expect(result.activity.activeDays == 0)
        #expect(result.activity.topBook == nil)
        #expect(result.busiestDay == nil)
        #expect(result.dateContext(now: now, calendar: utc, locale: english) == nil)
        #expect(september.hasPrevious(earliestActivity: JournalInsightsPolicy.earliestActivity(sessions, now: now)))
    }

    @Test func leaderTiesAreStableAcrossInputOrder() {
        let first = makeBook("tie-a", title: "Same Title", author: "Zed", narrator: "Narrator")
        let second = makeBook("tie-b", title: "Same Title", author: "Amy", narrator: "Narrator")
        let sessions = [
            session("a", book: first, end: "2026-05-03T12:00:00Z", seconds: 1_200),
            session("b", book: second, end: "2026-05-04T12:00:00Z", seconds: 1_200),
        ]
        let may = JournalRecapPeriod.containing(date("2026-05-15T00:00:00Z"), scope: .month, calendar: utc)
        let now = date("2026-06-01T00:00:00Z")
        let forward = recap(sessions, books: [first, second], period: may, now: now)
        let reversed = recap(Array(sessions.reversed()), books: [second, first], period: may, now: now)

        let expectedBook = min(first.stableId, second.stableId)
        #expect(forward.activity.topBook?.book.stableId == expectedBook)
        #expect(reversed.activity.topBook?.book.stableId == expectedBook)
        #expect(forward.activity.topAuthor?.name == "Amy")
        #expect(reversed.activity.topAuthor?.name == "Amy")
        #expect(forward.activity.topNarrator?.seconds == 2_400)
        #expect(forward.busiestDay?.date == date("2026-05-03T00:00:00Z"))
        #expect(reversed.busiestDay?.date == date("2026-05-03T00:00:00Z"))
    }

    @Test func listeningAndReadingAreTotaledSeparately() {
        let book = makeBook("book")
        let sessions = [
            session("listen", book: book, end: "2026-04-02T12:00:00Z", seconds: 3_600),
            session("podcast", book: book, end: "2026-04-02T13:00:00Z", seconds: 600, mediaType: .podcast),
            session("read", book: book, end: "2026-04-03T12:00:00Z", seconds: 1_800, mediaType: .ebook, pages: 12),
        ]
        let april = JournalRecapPeriod.containing(date("2026-04-15T00:00:00Z"), scope: .month, calendar: utc)
        let activity = recap(sessions, books: [book], period: april, now: date("2026-05-01T00:00:00Z")).activity

        #expect(activity.listeningSeconds == 4_200)
        #expect(activity.readingSeconds == 1_800)
        #expect(activity.totalSeconds == 6_000)
        #expect(activity.pagesRead == 12)
        #expect(activity.activeDays == 2)
    }

    @Test func navigationNeverReachesAFuturePeriod() {
        let now = date("2026-11-14T12:00:00Z")
        let current = JournalRecapPeriod.containing(now, scope: .month, calendar: utc)
        let previous = current.shifted(by: -1, calendar: utc)

        #expect(!current.hasNext(now: now))
        #expect(previous.hasNext(now: now))
        #expect(previous.shifted(by: 1, calendar: utc) == current)
        #expect(current.hasPrevious(earliestActivity: date("2026-10-15T00:00:00Z")))
        #expect(!previous.hasPrevious(earliestActivity: date("2026-10-15T00:00:00Z")))
        #expect(!current.hasPrevious(earliestActivity: nil))

        let currentYear = current.rescoped(to: .year, now: now, calendar: utc)
        #expect(!currentYear.hasNext(now: now))
        #expect(currentYear.rescoped(to: .month, now: now, calendar: utc) == current)
        let lastYear = currentYear.shifted(by: -1, calendar: utc)
        #expect(lastYear.rescoped(to: .month, now: now, calendar: utc).start == date("2025-12-01T00:00:00Z"))
    }

    @Test func shareTextDescribesAPartialPeriodWithoutFinishedCounts() {
        let book = makeBook("dune", title: "Dune", author: "Frank Herbert", narrator: "Scott Brick")
        let sessions = [
            session("listen", book: book, end: "2026-11-03T10:00:00Z", seconds: 3_600),
            session("read", book: book, end: "2026-11-03T20:00:00Z", seconds: 1_800, mediaType: .ebook, pages: 12),
        ]
        let now = date("2026-11-14T12:00:00Z")
        let november = JournalRecapPeriod.containing(now, scope: .month, calendar: utc)
        let text = recap(sessions, books: [book], period: november, now: now).shareText(now: now, calendar: utc, locale: english)

        #expect(text == [
            "My November 2026 reading recap from Enve",
            "So far, through November 14",
            "1h 30m total · 1h 0m listening · 30m reading",
            "1 active day · 2 sessions · 12 pages",
            "Busiest day: November 3 · 1h 30m",
            "Top title: Dune by Frank Herbert",
            "Top author: Frank Herbert",
            "Top narrator: Scott Brick",
        ].joined(separator: "\n"))
    }

    @Test @MainActor func modelReadsOnlyTheCapturedProfileHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JournalRecapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try HistorySessionStore(directory: root.appendingPathComponent("owner"))
        let child = try HistorySessionStore(directory: root.appendingPathComponent("child"))
        let ownerSession = session("owner", book: makeBook("owner-book"), end: "2025-03-10T12:00:00Z", seconds: 600)
        await owner.appendListeningSession(ownerSession)
        await child.appendReadingSession(
            session("child", book: makeBook("child-book"), end: "2024-01-10T12:00:00Z", seconds: 600, mediaType: .ebook)
        )

        var requested: [Set<String>] = []
        let model = JournalRecapModel(history: owner) { ids in
            requested.append(ids)
            return [:]
        }
        await model.refresh()

        #expect(model.isLoaded)
        #expect(model.earliestActivity == ownerSession.endTime)
        #expect(requested == [[ownerSession.bookId]])
    }

    private func recap(
        _ sessions: [HistorySession],
        books: [Book],
        period: JournalRecapPeriod,
        now: Date,
        calendar: Calendar? = nil
    ) -> JournalRecap {
        var aliases: [String: Book] = [:]
        for book in books {
            aliases[book.stableId] = book
        }
        return JournalInsightsPolicy.recap(
            sessions: sessions,
            booksByAlias: aliases,
            period: period,
            now: now,
            calendar: calendar ?? utc
        )
    }

    private func makeBook(
        _ id: String,
        title: String? = nil,
        author: String = "Author",
        narrator: String = "Narrator"
    ) -> Book {
        Book(
            id: id,
            title: title ?? id,
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
        seconds: Int,
        mediaType: AppMediaType = .audiobook,
        pages: Int? = nil
    ) -> HistorySession {
        let endDate = date(end)
        return HistorySession(
            id: id,
            bookId: book.stableId,
            mediaType: mediaType.rawValue,
            startTime: endDate.addingTimeInterval(TimeInterval(-max(seconds, 0))),
            endTime: endDate,
            durationSeconds: seconds,
            startProgress: nil,
            endProgress: nil,
            progressDelta: nil,
            startLocation: nil,
            endLocation: nil,
            pagesRead: pages,
            source: .local
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }
}
