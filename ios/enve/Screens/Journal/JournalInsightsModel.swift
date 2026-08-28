import Foundation

struct JournalInsightBookEntry: Identifiable {
    let book: Book
    let seconds: TimeInterval

    var id: String { book.stableId }
}

struct JournalInsightNamedEntry: Identifiable {
    let name: String
    let seconds: TimeInterval

    var id: String { name }
}

struct JournalYearReview {
    let year: Int
    let totalSeconds: TimeInterval
    let listeningSeconds: TimeInterval
    let readingSeconds: TimeInterval
    let pagesRead: Int
    let sessions: Int
    let activeDays: Int
    let booksFinished: Int
    let favoriteMonth: String?
    let topBook: JournalInsightBookEntry?
    let topAuthor: JournalInsightNamedEntry?
    let topNarrator: JournalInsightNamedEntry?
}

struct JournalInsightsSnapshot {
    let thisWeekSeconds: TimeInterval
    let lastWeekSeconds: TimeInterval
    let currentStreak: Int
    let longestStreak: Int
    let favoriteWeekday: String?
    let topBooks: [JournalInsightBookEntry]
    let topAuthors: [JournalInsightNamedEntry]
    let topNarrators: [JournalInsightNamedEntry]
    let availableYears: [Int]
    let yearReview: JournalYearReview

    var hasActivity: Bool {
        thisWeekSeconds > 0 || lastWeekSeconds > 0 || !topBooks.isEmpty || yearReview.totalSeconds > 0
    }

    static func empty(year: Int) -> JournalInsightsSnapshot {
        JournalInsightsSnapshot(
            thisWeekSeconds: 0,
            lastWeekSeconds: 0,
            currentStreak: 0,
            longestStreak: 0,
            favoriteWeekday: nil,
            topBooks: [],
            topAuthors: [],
            topNarrators: [],
            availableYears: [year],
            yearReview: JournalYearReview(
                year: year,
                totalSeconds: 0,
                listeningSeconds: 0,
                readingSeconds: 0,
                pagesRead: 0,
                sessions: 0,
                activeDays: 0,
                booksFinished: 0,
                favoriteMonth: nil,
                topBook: nil,
                topAuthor: nil,
                topNarrator: nil
            )
        )
    }
}

enum JournalInsightsPolicy {
    static func snapshot(
        sessions: [HistorySession],
        books: [Book],
        finishedBooks: [FinishedBookSummary]? = nil,
        year: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> JournalInsightsSnapshot {
        let validSessions = deduplicated(sessions)
            .filter { $0.durationSeconds > 0 && $0.endTime <= now }
        let booksByAlias = bookAliases(books)
        let thisWeekStart = startOfWeek(containing: now, calendar: calendar)
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart

        let thisWeek = validSessions.filter { $0.endTime >= thisWeekStart }
        let lastWeek = validSessions.filter { $0.endTime >= lastWeekStart && $0.endTime < thisWeekStart }
        let activeDays = Set(validSessions.map { calendar.startOfDay(for: $0.endTime) })

        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
        let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? .distantFuture
        let annualSessions = validSessions.filter { $0.endTime >= yearStart && $0.endTime < yearEnd }
        let annualDays = Set(annualSessions.map { calendar.startOfDay(for: $0.endTime) })
        let finishedBooks = finishedBooks ?? books.compactMap { book in
            guard book.isFinished else { return nil }
            return FinishedBookSummary(
                stableId: book.stableId,
                mediaType: book.mediaType,
                lastUpdate: book.lastUpdate
            )
        }
        let finished = finishedBooks.filter {
            $0.mediaType != .podcast
                && $0.lastUpdate >= yearStart
                && $0.lastUpdate < yearEnd
                && $0.lastUpdate <= now
        }

        let allBookEntries = topBooks(validSessions, booksByAlias: booksByAlias)
        let annualBookEntries = topBooks(annualSessions, booksByAlias: booksByAlias)
        let allAuthors = topNames(validSessions, booksByAlias: booksByAlias, value: \.author)
        let annualAuthors = topNames(annualSessions, booksByAlias: booksByAlias, value: \.author)
        let allNarrators = topNames(validSessions, booksByAlias: booksByAlias, value: \.narrator)
        let annualNarrators = topNames(annualSessions, booksByAlias: booksByAlias, value: \.narrator)

        let availableYears = Set(
            validSessions.map { calendar.component(.year, from: $0.endTime) }
                + finishedBooks.filter { $0.lastUpdate <= now }
                .map { calendar.component(.year, from: $0.lastUpdate) }
                + [calendar.component(.year, from: now)]
        ).sorted(by: >)

        return JournalInsightsSnapshot(
            thisWeekSeconds: duration(thisWeek),
            lastWeekSeconds: duration(lastWeek),
            currentStreak: currentStreak(activeDays: activeDays, now: now, calendar: calendar),
            longestStreak: longestStreak(activeDays: activeDays, calendar: calendar),
            favoriteWeekday: favoriteWeekday(validSessions, calendar: calendar),
            topBooks: Array(allBookEntries.prefix(8)),
            topAuthors: Array(allAuthors.prefix(8)),
            topNarrators: Array(allNarrators.prefix(8)),
            availableYears: availableYears,
            yearReview: JournalYearReview(
                year: year,
                totalSeconds: duration(annualSessions),
                listeningSeconds: duration(annualSessions.filter { $0.mediaType == AppMediaType.audiobook.rawValue }),
                readingSeconds: duration(annualSessions.filter { $0.mediaType == AppMediaType.ebook.rawValue }),
                pagesRead: annualSessions.compactMap(\.pagesRead).reduce(0, +),
                sessions: annualSessions.count,
                activeDays: annualDays.count,
                booksFinished: finished.count,
                favoriteMonth: favoriteMonth(annualSessions, calendar: calendar),
                topBook: annualBookEntries.first,
                topAuthor: annualAuthors.first,
                topNarrator: annualNarrators.first
            )
        )
    }

    private static func deduplicated(_ sessions: [HistorySession]) -> [HistorySession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert($0.id).inserted }
    }

    private static func duration(_ sessions: [HistorySession]) -> TimeInterval {
        sessions.reduce(0) { $0 + TimeInterval($1.durationSeconds) }
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    private static func currentStreak(activeDays: Set<Date>, now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor: Date
        if activeDays.contains(today) {
            cursor = today
        } else if activeDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while activeDays.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func longestStreak(activeDays: Set<Date>, calendar: Calendar) -> Int {
        let days = activeDays.sorted()
        guard var previous = days.first else { return 0 }
        var longest = 1
        var run = 1
        for day in days.dropFirst() {
            if calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        return longest
    }

    private static func favoriteWeekday(_ sessions: [HistorySession], calendar: Calendar) -> String? {
        let totals = Dictionary(grouping: sessions, by: { calendar.component(.weekday, from: $0.endTime) })
            .mapValues(duration)
        guard let weekday = totals.max(by: { $0.value < $1.value })?.key else { return nil }
        return calendar.weekdaySymbols[weekday - 1]
    }

    private static func favoriteMonth(_ sessions: [HistorySession], calendar: Calendar) -> String? {
        let totals = Dictionary(grouping: sessions, by: { calendar.component(.month, from: $0.endTime) })
            .mapValues(duration)
        guard let month = totals.max(by: { $0.value < $1.value })?.key else { return nil }
        return calendar.monthSymbols[month - 1]
    }

    private static func bookAliases(_ books: [Book]) -> [String: Book] {
        var aliases: [String: Book] = [:]
        for book in books {
            aliases[book.id] = book
            aliases[book.stableId] = book
            aliases[book.ratingKey] = book
            aliases[book.uniqueId] = book
        }
        return aliases
    }

    private static func topBooks(
        _ sessions: [HistorySession],
        booksByAlias: [String: Book]
    ) -> [JournalInsightBookEntry] {
        var totals: [String: TimeInterval] = [:]
        var resolved: [String: Book] = [:]
        for session in sessions {
            guard let book = booksByAlias[session.bookId] else { continue }
            totals[book.stableId, default: 0] += TimeInterval(session.durationSeconds)
            resolved[book.stableId] = book
        }
        return totals.compactMap { id, seconds in
            resolved[id].map { JournalInsightBookEntry(book: $0, seconds: seconds) }
        }
        .sorted { $0.seconds == $1.seconds ? $0.book.title < $1.book.title : $0.seconds > $1.seconds }
    }

    private static func topNames(
        _ sessions: [HistorySession],
        booksByAlias: [String: Book],
        value: KeyPath<Book, String?>
    ) -> [JournalInsightNamedEntry] {
        var totals: [String: TimeInterval] = [:]
        for session in sessions {
            guard let book = booksByAlias[session.bookId],
                let name = book[keyPath: value]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else {
                continue
            }
            totals[name, default: 0] += TimeInterval(session.durationSeconds)
        }
        return totals.map { JournalInsightNamedEntry(name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
    }
}

@MainActor
@Observable
final class JournalInsightsModel {
    private var sessions: [HistorySession] = []
    private var books: [Book] = []
    private var finishedBooks: [FinishedBookSummary] = []

    private(set) var snapshot: JournalInsightsSnapshot
    var selectedYear: Int {
        didSet { recompute() }
    }

    private let library: any BookQuerying

    init(library: any BookQuerying = AppState.shared.bookStore) {
        self.library = library
        let year = Calendar.current.component(.year, from: .now)
        selectedYear = year
        snapshot = .empty(year: year)
    }

    func refresh() async {
        async let listening = HistorySessionStore.shared.loadListeningSessions()
        async let reading = HistorySessionStore.shared.loadReadingSessions()
        sessions = await listening + reading
        async let storedBooks = JournalStatsBookLookup.build(ids: Set(sessions.map(\.bookId)), books: library)
        async let storedFinishedBooks = library.finishedBookSummaries()
        let storedBookMap = await storedBooks
        var seen = Set<String>()
        books = storedBookMap.values.filter { seen.insert($0.stableId).inserted }
        finishedBooks = await storedFinishedBooks
        let years = JournalInsightsPolicy.snapshot(
            sessions: sessions,
            books: books,
            finishedBooks: finishedBooks,
            year: selectedYear
        ).availableYears
        if !years.contains(selectedYear), let newest = years.first {
            selectedYear = newest
        } else {
            recompute()
        }
    }

    private func recompute() {
        snapshot = JournalInsightsPolicy.snapshot(
            sessions: sessions,
            books: books,
            finishedBooks: finishedBooks,
            year: selectedYear
        )
    }
}
