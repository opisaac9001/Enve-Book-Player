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

struct JournalPeriodActivity {
    let totalSeconds: TimeInterval
    let listeningSeconds: TimeInterval
    let readingSeconds: TimeInterval
    let pagesRead: Int
    let sessions: Int
    let activeDays: Int
    let topBook: JournalInsightBookEntry?
    let topAuthor: JournalInsightNamedEntry?
    let topNarrator: JournalInsightNamedEntry?
}

enum JournalRecapScope: String, CaseIterable, Identifiable {
    case month
    case year

    var id: Self { self }

    var title: String {
        switch self {
        case .month: "Month"
        case .year: "Year"
        }
    }

    fileprivate var component: Calendar.Component {
        switch self {
        case .month: .month
        case .year: .year
        }
    }
}

struct JournalRecapPeriod: Hashable {
    let scope: JournalRecapScope
    let start: Date
    let end: Date

    static func containing(_ date: Date, scope: JournalRecapScope, calendar: Calendar) -> JournalRecapPeriod {
        let interval = calendar.dateInterval(of: scope.component, for: date) ?? DateInterval(start: date, duration: 0)
        return JournalRecapPeriod(scope: scope, start: interval.start, end: interval.end)
    }

    // DateInterval.contains includes its end; recap periods must not share a boundary instant.
    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    func shifted(by value: Int, calendar: Calendar) -> JournalRecapPeriod {
        let anchor = calendar.date(byAdding: scope.component, value: value, to: start) ?? start
        return .containing(anchor, scope: scope, calendar: calendar)
    }

    func rescoped(to scope: JournalRecapScope, now: Date, calendar: Calendar) -> JournalRecapPeriod {
        .containing(min(end.addingTimeInterval(-1), now), scope: scope, calendar: calendar)
    }

    func hasNext(now: Date) -> Bool {
        end <= now
    }

    func hasPrevious(earliestActivity: Date?) -> Bool {
        earliestActivity.map { start > $0 } ?? false
    }

    func title(calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        var style = scope == .month
            ? Date.FormatStyle.dateTime.month(.wide).year()
            : Date.FormatStyle.dateTime.year()
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return start.formatted(style)
    }
}

struct JournalRecapDay: Equatable {
    let date: Date
    let seconds: TimeInterval
}

struct JournalRecap {
    let period: JournalRecapPeriod
    let isInProgress: Bool
    let activity: JournalPeriodActivity
    let busiestDay: JournalRecapDay?

    var isEmpty: Bool { activity.sessions == 0 }

    func dateContext(now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String? {
        guard isInProgress else { return nil }
        return "So far, through \(Self.dayStyle(calendar: calendar, locale: locale).format(now))"
    }

    func shareText(now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        let title = period.title(calendar: calendar, locale: locale)
        var lines = ["My \(title) reading recap from Enve"]
        if let context = dateContext(now: now, calendar: calendar, locale: locale) {
            lines.append(context)
        }
        lines.append(
            "\(HearthFormat.duration(activity.totalSeconds)) total · "
                + "\(HearthFormat.duration(activity.listeningSeconds)) listening · "
                + "\(HearthFormat.duration(activity.readingSeconds)) reading"
        )
        var counts = [
            Self.counted(activity.activeDays, "active day", "active days", locale: locale),
            Self.counted(activity.sessions, "session", "sessions", locale: locale),
        ]
        if activity.pagesRead > 0 {
            counts.append(Self.counted(activity.pagesRead, "page", "pages", locale: locale))
        }
        lines.append(counts.joined(separator: " · "))
        if let day = busiestDay {
            lines.append(
                "Busiest day: \(Self.dayStyle(calendar: calendar, locale: locale).format(day.date)) · "
                    + HearthFormat.duration(day.seconds)
            )
        }
        if let book = activity.topBook?.book {
            let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append(author.isEmpty ? "Top title: \(book.title)" : "Top title: \(book.title) by \(author)")
        }
        if let author = activity.topAuthor {
            lines.append("Top author: \(author.name)")
        }
        if let narrator = activity.topNarrator {
            lines.append("Top narrator: \(narrator.name)")
        }
        return lines.joined(separator: "\n")
    }

    private static func dayStyle(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.wide).day()
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }

    private static func counted(_ value: Int, _ singular: String, _ plural: String, locale: Locale) -> String {
        "\(value.formatted(.number.locale(locale))) \(value == 1 ? singular : plural)"
    }
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
        let validSessions = recordedSessions(sessions, now: now)
        let booksByAlias = bookAliases(books)
        let thisWeekStart = startOfWeek(containing: now, calendar: calendar)
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart

        let thisWeek = validSessions.filter { $0.endTime >= thisWeekStart }
        let lastWeek = validSessions.filter { $0.endTime >= lastWeekStart && $0.endTime < thisWeekStart }
        let activeDays = Set(validSessions.map { calendar.startOfDay(for: $0.endTime) })

        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
        let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? .distantFuture
        let annualSessions = validSessions.filter { $0.endTime >= yearStart && $0.endTime < yearEnd }
        let annual = activity(annualSessions, booksByAlias: booksByAlias, calendar: calendar)
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
        let allAuthors = topNames(validSessions, booksByAlias: booksByAlias, value: \.author)
        let allNarrators = topNames(validSessions, booksByAlias: booksByAlias, value: \.narrator)

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
                totalSeconds: annual.totalSeconds,
                listeningSeconds: annual.listeningSeconds,
                readingSeconds: annual.readingSeconds,
                pagesRead: annual.pagesRead,
                sessions: annual.sessions,
                activeDays: annual.activeDays,
                booksFinished: finished.count,
                favoriteMonth: favoriteMonth(annualSessions, calendar: calendar),
                topBook: annual.topBook,
                topAuthor: annual.topAuthor,
                topNarrator: annual.topNarrator
            )
        )
    }

    // Finished-book counts are omitted: FinishedBookSummary.lastUpdate is the last edit, not a completion date.
    static func recap(
        sessions: [HistorySession],
        booksByAlias: [String: Book],
        period: JournalRecapPeriod,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> JournalRecap {
        let periodSessions = recordedSessions(sessions, now: now).filter { period.contains($0.endTime) }
        return JournalRecap(
            period: period,
            isInProgress: period.contains(now),
            activity: activity(periodSessions, booksByAlias: booksByAlias, calendar: calendar),
            busiestDay: busiestDay(periodSessions, calendar: calendar)
        )
    }

    static func earliestActivity(_ sessions: [HistorySession], now: Date = .now) -> Date? {
        recordedSessions(sessions, now: now).map(\.endTime).min()
    }

    private static func recordedSessions(_ sessions: [HistorySession], now: Date) -> [HistorySession] {
        var seen = Set<String>()
        return sessions.filter { $0.durationSeconds > 0 && $0.endTime <= now && seen.insert($0.id).inserted }
    }

    private static func activity(
        _ sessions: [HistorySession],
        booksByAlias: [String: Book],
        calendar: Calendar
    ) -> JournalPeriodActivity {
        JournalPeriodActivity(
            totalSeconds: duration(sessions),
            listeningSeconds: duration(sessions.filter { $0.mediaType == AppMediaType.audiobook.rawValue || $0.mediaType == AppMediaType.podcast.rawValue }),
            readingSeconds: duration(sessions.filter { $0.mediaType == AppMediaType.ebook.rawValue }),
            pagesRead: sessions.compactMap(\.pagesRead).reduce(0, +),
            sessions: sessions.count,
            activeDays: Set(sessions.map { calendar.startOfDay(for: $0.endTime) }).count,
            topBook: topBooks(sessions, booksByAlias: booksByAlias).first,
            topAuthor: topNames(sessions, booksByAlias: booksByAlias, value: \.author).first,
            topNarrator: topNames(sessions, booksByAlias: booksByAlias, value: \.narrator).first
        )
    }

    private static func busiestDay(_ sessions: [HistorySession], calendar: Calendar) -> JournalRecapDay? {
        Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.endTime) })
            .map { JournalRecapDay(date: $0.key, seconds: duration($0.value)) }
            .min { $0.seconds == $1.seconds ? $0.date < $1.date : $0.seconds > $1.seconds }
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
        .sorted {
            $0.seconds == $1.seconds
                ? ($0.book.title, $0.book.stableId) < ($1.book.title, $1.book.stableId)
                : $0.seconds > $1.seconds
        }
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
    private let history: HistorySessionStore
    private let progressCache: BookProgressStore

    init(library: any BookQuerying = AppState.shared.bookStore, history: HistorySessionStore = .shared, progressCache: BookProgressStore = .shared) {
        self.library = library
        self.history = history
        self.progressCache = progressCache
        let year = Calendar.current.component(.year, from: .now)
        selectedYear = year
        snapshot = .empty(year: year)
    }

    func refresh() async {
        async let listening = history.loadListeningSessions()
        async let reading = history.loadReadingSessions()
        sessions = await listening + reading
        async let storedBooks = JournalStatsBookLookup.build(ids: Set(sessions.map(\.bookId)), books: library, progressCache: progressCache)
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

@MainActor
@Observable
final class JournalRecapModel {
    private(set) var period: JournalRecapPeriod
    private(set) var recap: JournalRecap
    private(set) var earliestActivity: Date?
    private(set) var isLoaded = false

    private var sessions: [HistorySession] = []
    private var booksByAlias: [String: Book] = [:]
    private var loadGeneration = 0

    private let history: HistorySessionStore
    private let lookupBooks: @MainActor (Set<String>) async -> [String: Book]
    private let calendar: Calendar

    // Dependencies are captured here so a profile switch during a load cannot mix another profile's history in.
    init(history: HistorySessionStore, lookupBooks: @escaping @MainActor (Set<String>) async -> [String: Book]) {
        let calendar = Calendar.current
        self.history = history
        self.lookupBooks = lookupBooks
        self.calendar = calendar
        let period = JournalRecapPeriod.containing(.now, scope: .month, calendar: calendar)
        self.period = period
        recap = JournalInsightsPolicy.recap(sessions: [], booksByAlias: [:], period: period, calendar: calendar)
    }

    convenience init(profileSession: ProfileSession) {
        let books = profileSession.bookStore
        let progress = profileSession.bookProgress
        self.init(history: profileSession.historyStore) { ids in
            await JournalStatsBookLookup.build(ids: ids, books: books, progressCache: progress)
        }
    }

    var scope: JournalRecapScope {
        get { period.scope }
        set {
            guard newValue != period.scope else { return }
            show(period.rescoped(to: newValue, now: .now, calendar: calendar))
        }
    }

    var canShowPrevious: Bool { period.hasPrevious(earliestActivity: earliestActivity) }
    var canShowNext: Bool { period.hasNext(now: .now) }

    func showPrevious() {
        guard canShowPrevious else { return }
        show(period.shifted(by: -1, calendar: calendar))
    }

    func showNext() {
        guard canShowNext else { return }
        show(period.shifted(by: 1, calendar: calendar))
    }

    func title(for period: JournalRecapPeriod) -> String {
        period.title(calendar: calendar)
    }

    func dateContext() -> String? {
        recap.dateContext(now: .now, calendar: calendar)
    }

    func shareText() -> String {
        recap.shareText(now: .now, calendar: calendar)
    }

    func refresh() async {
        loadGeneration += 1
        let generation = loadGeneration
        let history = history
        async let listening = history.loadListeningSessions()
        async let reading = history.loadReadingSessions()
        let loaded = await listening + reading
        let books = await lookupBooks(Set(loaded.map(\.bookId)))
        guard generation == loadGeneration else { return }
        sessions = loaded
        booksByAlias = books
        earliestActivity = JournalInsightsPolicy.earliestActivity(loaded)
        isLoaded = true
        show(period)
    }

    private func show(_ period: JournalRecapPeriod) {
        self.period = period
        recap = JournalInsightsPolicy.recap(
            sessions: sessions,
            booksByAlias: booksByAlias,
            period: period,
            calendar: calendar
        )
    }
}
