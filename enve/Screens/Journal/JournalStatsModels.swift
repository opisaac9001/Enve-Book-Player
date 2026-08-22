import Combine
import SwiftUI

struct JournalBookStatEntry: Identifiable {
    let id: String
    let book: Book
    let seconds: TimeInterval
    let sessions: Int
    let completed: Bool
    let completion: Double
    let pages: Int

    var hours: Double { seconds / 3600 }
    var authorName: String { book.author.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown author" }
}

enum JournalLeveling {
    static func level(for totalXP: Int) -> (level: Int, xpIntoLevel: Int, xpForNextLevel: Int, progress: Double) {
        let safeXP = max(0, totalXP)
        var level = 1
        var points = 0.0
        var currentLevelXP = 0
        var nextLevelXP = 83

        while level < 200 {
            points += floor(Double(level) + 300.0 * pow(2.0, Double(level) / 7.0))
            nextLevelXP = Int(floor(points / 4.0))
            if safeXP < nextLevelXP { break }
            currentLevelXP = nextLevelXP
            level += 1
        }

        let xpIntoLevel = max(0, safeXP - currentLevelXP)
        let xpForNextLevel = max(1, nextLevelXP - currentLevelXP)
        return (level, xpIntoLevel, xpForNextLevel, min(1.0, Double(xpIntoLevel) / Double(xpForNextLevel)))
    }

    static func listeningRank(for level: Int) -> String {
        switch level {
        case 1...3: "Page Turner"
        case 4...8: "Night Reader"
        case 9...15: "Story Chaser"
        case 16...25: "Chapter Champion"
        case 26...40: "Library Hero"
        default: "Audiobook Legend"
        }
    }

    static func readingRank(for level: Int) -> String {
        switch level {
        case 1...3: "Casual Reader"
        case 4...8: "Page Turner"
        case 9...15: "Bookworm"
        case 16...25: "Literary Explorer"
        case 26...40: "Library Legend"
        default: "Grand Bibliophile"
        }
    }
}

struct JournalBadge: Identifiable {
    let id: String
    let title: String
    let systemImage: String
}

enum JournalStatsBookLookup {
    static func build(ids: Set<String>, books: any BookQuerying = AppState.shared.bookStore) async -> [String: Book] {
        var map: [String: Book] = [:]
        func insertAliases(for book: Book, preferredKey: String? = nil) {
            if let preferredKey, !preferredKey.isEmpty { map[preferredKey] = book }
            map[book.id] = book
            map[book.stableId] = book
            map[book.ratingKey] = book
            map[book.downloadKey] = book
            map[book.uniqueId] = book
        }
        for snap in BookProgressStore.shared.loadSnapshots() {
            insertAliases(for: snap.book, preferredKey: snap.stableId)
        }
        let unresolved = ids.subtracting(map.keys)
        if !unresolved.isEmpty {
            let storeBooks = await books.booksByAnyIds(unresolved)
            map.merge(storeBooks) { current, _ in current }
        }
        return map
    }
}

@MainActor
@Observable
final class JournalListeningStatsModel {
    private(set) var snapshot: ListeningStatsSnapshot = .empty
    private(set) var bookLookup: [String: Book] = [:]
    private(set) var recentSessions: [HistorySession] = []
    private(set) var isLoading = false
    var weeklyGoalHours: Double = 0
    var monthlyBookGoal: Int = 4

    private var liveUpdates: AnyCancellable?

    func startLiveUpdates() {
        guard liveUpdates == nil else { return }
        liveUpdates = NotificationCenter.default.publisher(for: .listeningStatsDidChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refresh() }
            }
    }

    func stopLiveUpdates() {
        liveUpdates?.cancel()
        liveUpdates = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        snapshot = await ListeningStatsTracker.shared.currentSnapshot()
        bookLookup = await JournalStatsBookLookup.build(ids: Set(snapshot.perBook.keys))
        recentSessions = Array(await HistorySessionStore.shared.loadListeningSessions().prefix(12))
        weeklyGoalHours = PlayerStateStore.shared.loadWeeklyGoal()
        monthlyBookGoal = PlayerStateStore.shared.loadMonthlyBookGoal()
    }

    func setWeeklyGoal(hours: Double) {
        weeklyGoalHours = hours
        PlayerStateStore.shared.saveWeeklyGoal(hours: hours)
    }

    func setMonthlyBookGoal(count: Int) {
        monthlyBookGoal = count
        PlayerStateStore.shared.saveMonthlyBookGoal(count: count)
    }

    func weeklyHours() -> Double { journalHours(in: snapshot.dailySeconds, lastDays: 7) }
    func monthlyHours() -> Double { journalHours(in: snapshot.dailySeconds, lastDays: 30) }

    func weeklyGoalProgress() -> Double {
        guard weeklyGoalHours > 0 else { return 0 }
        return min(weeklyHours() / weeklyGoalHours, 1.0)
    }

    var entries: [JournalBookStatEntry] {
        snapshot.perBook.compactMap { key, stat in
            guard let book = bookLookup[key] ?? bookLookup[stat.bookId], !book.isPodcastEpisode else { return nil }
            return JournalBookStatEntry(
                id: key,
                book: book,
                seconds: stat.totalSeconds,
                sessions: stat.sessionCount,
                completed: stat.isCompleted || book.isFinished || book.isCompleted,
                completion: min(max(max(stat.progressPercentage, book.progressPercentage), 0), 1),
                pages: 0
            )
        }
    }

    var booksFinished: Int { entries.filter(\.completed).count }
    var uniqueAuthors: Int { Set(entries.map(\.authorName)).count }

    var averageCompletion: Double {
        guard !entries.isEmpty else { return 0 }
        return entries.map(\.completion).reduce(0, +) / Double(entries.count)
    }

    var consistencyScore: Int {
        min(60, entries.reduce(0) { $0 + $1.sessions } / 3) + min(40, snapshot.streak.current * 2)
    }

    var finisherScore: Int { Int(averageCompletion * 100) }
    var curatorScore: Int { min(100, uniqueAuthors * 5) }

    var totalXP: Int {
        Int(snapshot.totalHours * 10) + booksFinished * 35 + uniqueAuthors * 6
    }

    var topAuthors: [(name: String, hours: Double, books: Int)] {
        Dictionary(grouping: entries, by: \.authorName)
            .map { (name: $0.key, hours: $0.value.reduce(0) { $0 + $1.hours }, books: $0.value.count) }
            .sorted { $0.hours > $1.hours }
    }

    var topBooks: [JournalBookStatEntry] {
        entries.sorted { $0.seconds > $1.seconds }
    }

    var badges: [JournalBadge] {
        var list: [JournalBadge] = []
        let hours = snapshot.totalHours
        if hours >= 1 { list.append(.init(id: "first_hour", title: "First hour", systemImage: "1.circle.fill")) }
        if hours >= 10 { list.append(.init(id: "ten_hours", title: "10 hours", systemImage: "10.circle.fill")) }
        if hours >= 50 { list.append(.init(id: "fifty_hours", title: "50 hours", systemImage: "star.circle.fill")) }
        if booksFinished >= 5 { list.append(.init(id: "fin_5", title: "5 finished", systemImage: "checkmark.circle.fill")) }
        if booksFinished >= 20 { list.append(.init(id: "fin_20", title: "Book finisher", systemImage: "book.fill")) }
        if consistencyScore >= 80 { list.append(.init(id: "consistency_80", title: "Consistency", systemImage: "calendar.badge.clock")) }
        return list
    }
}

@MainActor
@Observable
final class JournalReadingStatsModel {
    private(set) var snapshot: ReadingStatsSnapshot = .empty
    private(set) var bookLookup: [String: Book] = [:]
    private(set) var recentSessions: [HistorySession] = []
    private(set) var averageWordsPerMinute: Int?
    private(set) var isLoading = false
    var weeklyGoalHours: Double = 0

    private var liveUpdates: AnyCancellable?

    func startLiveUpdates() {
        guard liveUpdates == nil else { return }
        liveUpdates = NotificationCenter.default.publisher(for: .readingStatsDidChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refresh() }
            }
    }

    func stopLiveUpdates() {
        liveUpdates?.cancel()
        liveUpdates = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        snapshot = await ReadingStatsTracker.shared.currentSnapshot()
        bookLookup = await JournalStatsBookLookup.build(ids: Set(snapshot.perBook.keys))
        recentSessions = Array(await HistorySessionStore.shared.loadReadingSessions().prefix(12))

        let listening = await ListeningStatsTracker.shared.currentSnapshot()
        averageWordsPerMinute = listening.averageReadingProgressPerMinute.map { Int($0 * 250) }
        weeklyGoalHours = PlayerStateStore.shared.loadWeeklyGoal()
    }

    func weeklyHours() -> Double { journalHours(in: snapshot.dailySecondsRead, lastDays: 7) }
    func monthlyHours() -> Double { journalHours(in: snapshot.dailySecondsRead, lastDays: 30) }

    var entries: [JournalBookStatEntry] {
        snapshot.perBook.compactMap { key, stat in
            guard let book = bookLookup[key] else { return nil }
            return JournalBookStatEntry(
                id: key,
                book: book,
                seconds: stat.totalSecondsRead,
                sessions: stat.sessionCount,
                completed: stat.isCompleted || book.isFinished,
                completion: min(max(stat.lastPositionProgression ?? 0, 0), 1),
                pages: stat.estimatedPagesRead
            )
        }
    }

    var booksFinished: Int { snapshot.totalBooksFinished }
    var totalPages: Int { snapshot.totalEstimatedPagesRead }
    var uniqueAuthors: Int { Set(entries.map(\.authorName)).count }

    var averageCompletion: Double {
        guard !entries.isEmpty else { return 0 }
        return entries.map(\.completion).reduce(0, +) / Double(entries.count)
    }

    var consistencyScore: Int {
        min(60, snapshot.totalSessions / 3) + min(40, snapshot.streak.current * 2)
    }

    var finisherScore: Int { Int(averageCompletion * 100) }
    var explorerScore: Int { min(100, uniqueAuthors * 8) }

    var totalXP: Int {
        Int(snapshot.totalHoursRead * 10) + booksFinished * 40 + uniqueAuthors * 6 + totalPages / 10
    }

    var topBooksByHours: [JournalBookStatEntry] {
        entries.sorted { $0.seconds > $1.seconds }
    }

    var topBooksByPages: [JournalBookStatEntry] {
        entries.sorted { $0.pages > $1.pages }
    }

    var badges: [JournalBadge] {
        var list: [JournalBadge] = []
        let hours = snapshot.totalHoursRead
        if hours >= 1 { list.append(.init(id: "first_hour", title: "First hour", systemImage: "1.circle.fill")) }
        if hours >= 10 { list.append(.init(id: "ten_hours", title: "10 hours", systemImage: "10.circle.fill")) }
        if hours >= 50 { list.append(.init(id: "fifty_hours", title: "50 hours", systemImage: "star.circle.fill")) }
        if booksFinished >= 1 { list.append(.init(id: "fin_1", title: "First finish", systemImage: "book.closed.fill")) }
        if booksFinished >= 5 { list.append(.init(id: "fin_5", title: "5 books done", systemImage: "checkmark.circle.fill")) }
        if booksFinished >= 20 { list.append(.init(id: "fin_20", title: "Voracious reader", systemImage: "books.vertical.fill")) }
        if totalPages >= 1000 { list.append(.init(id: "pages_1k", title: "A thousand pages", systemImage: "doc.text.fill")) }
        if snapshot.streak.current >= 7 { list.append(.init(id: "streak_7", title: "Week streak", systemImage: "flame.fill")) }
        if consistencyScore >= 80 { list.append(.init(id: "consistency", title: "Consistency", systemImage: "calendar.badge.clock")) }
        return list
    }
}

func journalHours(in daily: [String: TimeInterval], lastDays days: Int) -> Double {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    var total: TimeInterval = 0
    for back in 0..<days {
        guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
        total += daily[JournalStats.dayKey(for: day), default: 0]
    }
    return total / 3600
}
