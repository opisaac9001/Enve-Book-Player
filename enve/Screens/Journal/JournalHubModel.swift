import Combine
import SwiftUI

enum JournalStatsRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case allTime = "All time"

    var id: String { rawValue }
}

enum JournalStatsSource: String, CaseIterable, Identifiable {
    case enveAudiobook = "enve_audiobook"
    case enveEbook = "enve_ebook"
    case grimmory
    case kavita
    case audiobookshelf
    case plex
    case jellyfin
    case hardcover

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .enveAudiobook: "Enve audiobooks"
        case .enveEbook: "Enve ebooks"
        case .grimmory: "Grimmory"
        case .kavita: "Kavita"
        case .audiobookshelf: "Audiobookshelf"
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .hardcover: "Hardcover"
        }
    }

    var systemImage: String {
        switch self {
        case .enveAudiobook: "headphones"
        case .enveEbook: "book.fill"
        case .grimmory: "text.book.closed.fill"
        case .kavita: "books.vertical.fill"
        case .audiobookshelf: "waveform"
        case .plex: "play.rectangle.fill"
        case .jellyfin: "sparkles.tv.fill"
        case .hardcover: "bookmark.fill"
        }
    }

    var isListening: Bool {
        switch self {
        case .enveAudiobook, .audiobookshelf, .plex, .jellyfin, .grimmory: true
        case .enveEbook, .kavita, .hardcover: false
        }
    }

    var isReading: Bool {
        switch self {
        case .enveEbook, .grimmory, .kavita, .hardcover: true
        case .enveAudiobook, .audiobookshelf, .plex, .jellyfin: false
        }
    }

    var category: JournalServiceCategory {
        switch self {
        case .enveAudiobook, .enveEbook: .internalLibrary
        case .grimmory, .kavita, .audiobookshelf: .selfHosted
        case .plex, .jellyfin: .streaming
        case .hardcover: .metadataOnly
        }
    }
}

enum JournalServiceCategory: String, CaseIterable {
    case internalLibrary = "This device"
    case selfHosted = "Self-hosted"
    case streaming = "Streaming"
    case metadataOnly = "Tracking"
}

struct JournalServiceStats: Identifiable {
    let id: String
    let serviceName: String
    let systemImage: String
    let totalSeconds: TimeInterval
    let readingSeconds: TimeInterval
    let listeningSeconds: TimeInterval
    let sessionsCount: Int
    let booksFinished: Int
    let booksInProgress: Int
    let totalBooks: Int
    let currentStreak: Int
    let longestStreak: Int
    let dailySeconds: [String: TimeInterval]
    let pagesRead: Int
    let isAvailable: Bool
    let category: JournalServiceCategory

    var totalHours: Double { totalSeconds / 3600 }
}

@MainActor
@Observable
final class JournalHubModel {
    var serviceStats: [JournalStatsSource: JournalServiceStats] = [:]
    var grimmoryInsights: GrimmoryStatsSnapshot?
    var serviceErrors: [JournalStatsSource: String] = [:]
    var loadingServices: Set<JournalStatsSource> = []
    var isLoading = false
    var lastRefresh: Date?
    var selectedRange: JournalStatsRange = .week

    var combinedTotalSeconds: TimeInterval = 0
    var combinedSessions = 0
    var combinedBooksFinished = 0
    var combinedBooksInProgress = 0
    var combinedTotalBooks = 0
    var combinedCurrentStreak = 0
    var combinedLongestStreak = 0
    var combinedPagesRead = 0
    var combinedDailySeconds: [String: TimeInterval] = [:]
    var totalListeningSeconds: TimeInterval = 0
    var totalReadingSeconds: TimeInterval = 0

    var recentSessions: [HistorySession] = []
    var allSessions: [HistorySession] = []

    var bestDayDate: String?
    var bestDaySeconds: TimeInterval = 0
    var longestSession: HistorySession?
    var weeklyGoalHours: Double = 0

    private var listeningUpdates: AnyCancellable?
    private var readingUpdates: AnyCancellable?
    private let journal: JournalEngine

    var combinedTotalHours: Double { combinedTotalSeconds / 3600 }
    var listeningHours: Double { totalListeningSeconds / 3600 }
    var readingHours: Double { totalReadingSeconds / 3600 }

    var sortedServiceStats: [JournalServiceStats] {
        serviceStats.values.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    var activeServiceCount: Int {
        serviceStats.values.filter(\.isAvailable).count
    }

    private let providerConnections: any ProviderConnectionAccessing

    init(
        journal: JournalEngine = EnveEngine.shared.journal,
        providerConnections: any ProviderConnectionAccessing = AppState.shared.providerConnections
    ) {
        self.journal = journal
        self.providerConnections = providerConnections
    }

    func startLiveUpdates() {
        guard listeningUpdates == nil else { return }
        listeningUpdates = NotificationCenter.default.publisher(for: .listeningStatsDidChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshLocal() }
            }
        readingUpdates = NotificationCenter.default.publisher(for: .readingStatsDidChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshLocal() }
            }
    }

    func stopLiveUpdates() {
        listeningUpdates?.cancel()
        listeningUpdates = nil
        readingUpdates?.cancel()
        readingUpdates = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            lastRefresh = Date()
        }
        serviceErrors.removeAll()

        await refreshLocal()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadGrimmoryStats() }
            group.addTask { await self.loadKavitaStats() }
            group.addTask { await self.loadAudiobookshelfStats() }
            group.addTask { await self.loadHardcoverStats() }
        }
        await loadSessions()
        loadSessionBackedStats()
        recomputeCombined()
    }

    func refreshLocal() async {
        await loadEnveAudiobookStats()
        await loadEnveEbookStats()
        await loadSessions()
        loadSessionBackedStats()
        recomputeCombined()
    }

    private func loadEnveAudiobookStats() async {
        let snapshot = await ListeningStatsTracker.shared.currentSnapshot()
        serviceStats[.enveAudiobook] = JournalServiceStats(
            id: JournalStatsSource.enveAudiobook.rawValue,
            serviceName: JournalStatsSource.enveAudiobook.displayName,
            systemImage: JournalStatsSource.enveAudiobook.systemImage,
            totalSeconds: snapshot.totalSeconds,
            readingSeconds: 0,
            listeningSeconds: snapshot.totalSeconds,
            sessionsCount: snapshot.totalSessions,
            booksFinished: snapshot.totalBooksFinished,
            booksInProgress: snapshot.perBook.values.filter { !$0.isCompleted && $0.totalSeconds > 0 }.count,
            totalBooks: snapshot.perBook.count,
            currentStreak: Self.journalCurrentStreak(snapshot.dailySeconds),
            longestStreak: Self.journalLongestStreak(snapshot.dailySeconds),
            dailySeconds: snapshot.dailySeconds,
            pagesRead: 0,
            isAvailable: true,
            category: .internalLibrary
        )
    }

    private func loadEnveEbookStats() async {
        let snapshot = await ReadingStatsTracker.shared.currentSnapshot()
        serviceStats[.enveEbook] = JournalServiceStats(
            id: JournalStatsSource.enveEbook.rawValue,
            serviceName: JournalStatsSource.enveEbook.displayName,
            systemImage: JournalStatsSource.enveEbook.systemImage,
            totalSeconds: snapshot.totalSecondsRead,
            readingSeconds: snapshot.totalSecondsRead,
            listeningSeconds: 0,
            sessionsCount: snapshot.totalSessions,
            booksFinished: snapshot.totalBooksFinished,
            booksInProgress: snapshot.perBook.values.filter { !$0.isCompleted && $0.totalSecondsRead > 0 }.count,
            totalBooks: snapshot.perBook.count,
            currentStreak: Self.journalCurrentStreak(snapshot.dailySecondsRead),
            longestStreak: Self.journalLongestStreak(snapshot.dailySecondsRead),
            dailySeconds: snapshot.dailySecondsRead,
            pagesRead: snapshot.totalEstimatedPagesRead,
            isAvailable: true,
            category: .internalLibrary
        )
    }

    private func loadGrimmoryStats() async {
        grimmoryInsights = nil
        let payload: JournalGrimmoryStatsPayload?
        do {
            payload = try await journal.grimmoryStatsPayload()
        } catch {
            serviceErrors[.grimmory] = error.localizedDescription
            serviceStats[.grimmory] = Self.journalEmptyStats(for: .grimmory)
            return
        }
        guard let payload else {
            serviceStats[.grimmory] = Self.journalEmptyStats(for: .grimmory)
            return
        }

        loadingServices.insert(.grimmory)
        defer { loadingServices.remove(.grimmory) }

        let books = payload.books
        let sessions = payload.sessions
        grimmoryInsights = payload.insights

        var readSeconds: TimeInterval = 0
        var listenSeconds: TimeInterval = 0
        var daily: [String: TimeInterval] = [:]
        for session in sessions {
            let duration = TimeInterval(session.durationSeconds ?? 0)
            guard duration > 0 else { continue }
            if session.bookType?.lowercased() == "audiobook" {
                listenSeconds += duration
            } else {
                readSeconds += duration
            }
            if let date = Self.journalParseISO8601(session.startTime) {
                daily[JournalStats.dayKey(for: date), default: 0] += duration
            }
        }

        var finished = 0
        var inProgress = 0
        for book in books {
            if Self.journalGrimmoryFinished(book) { finished += 1 } else if Self.journalGrimmoryInProgress(book) { inProgress += 1 }
        }

        serviceStats[.grimmory] = JournalServiceStats(
            id: JournalStatsSource.grimmory.rawValue,
            serviceName: JournalStatsSource.grimmory.displayName,
            systemImage: JournalStatsSource.grimmory.systemImage,
            totalSeconds: readSeconds + listenSeconds,
            readingSeconds: readSeconds,
            listeningSeconds: listenSeconds,
            sessionsCount: sessions.count,
            booksFinished: finished,
            booksInProgress: inProgress,
            totalBooks: books.count,
            currentStreak: Self.journalCurrentStreak(daily),
            longestStreak: Self.journalLongestStreak(daily),
            dailySeconds: daily,
            pagesRead: 0,
            isAvailable: true,
            category: .selfHosted
        )
    }

    private func loadAudiobookshelfStats() async {
        let absStats: AudiobookshelfListeningStats?
        do {
            absStats = try await journal.audiobookshelfListeningStats()
        } catch {
            serviceErrors[.audiobookshelf] = error.localizedDescription
            serviceStats[.audiobookshelf] = Self.journalEmptyStats(for: .audiobookshelf)
            return
        }
        guard let absStats else {
            serviceStats[.audiobookshelf] = Self.journalEmptyStats(for: .audiobookshelf)
            return
        }

        loadingServices.insert(.audiobookshelf)
        defer { loadingServices.remove(.audiobookshelf) }

        let daily = absStats.days ?? [:]

        serviceStats[.audiobookshelf] = JournalServiceStats(
            id: JournalStatsSource.audiobookshelf.rawValue,
            serviceName: JournalStatsSource.audiobookshelf.displayName,
            systemImage: JournalStatsSource.audiobookshelf.systemImage,
            totalSeconds: absStats.totalTime,
            readingSeconds: 0,
            listeningSeconds: absStats.totalTime,
            sessionsCount: absStats.recentSessions?.count ?? 0,
            booksFinished: 0,
            booksInProgress: absStats.items.count,
            totalBooks: absStats.items.count,
            currentStreak: Self.journalCurrentStreak(daily),
            longestStreak: Self.journalLongestStreak(daily),
            dailySeconds: daily,
            pagesRead: 0,
            isAvailable: true,
            category: .selfHosted
        )
    }

    private func loadKavitaStats() async {
        guard let connection = providerConnections.connections.first(where: { $0.type == .kavita && !$0.isArchived }),
              let provider = providerConnections.provider(for: connection.id) as? KavitaProvider
        else {
            serviceStats[.kavita] = Self.journalEmptyStats(for: .kavita)
            return
        }

        loadingServices.insert(.kavita)
        defer { loadingServices.remove(.kavita) }

        do {
            let account = try await provider.fetchAccount()
            async let profileTask = provider.fetchProfileBar(userId: account.id, days: 365)
            async let totalsTask = provider.fetchReadTotals(userId: account.id)
            async let activityTask = provider.fetchReadingActivity(
                userId: account.id,
                year: Calendar.current.component(.year, from: .now)
            )
            async let historyTask = provider.fetchReadingHistory(page: 1, pageSize: 100, days: 365)
            let (profile, totals, daily, history) = try await (profileTask, totalsTask, activityTask, historyTask)
            let totalSeconds = TimeInterval(totals.timeSpentReading * 3600)
            let finished = profile.booksRead + profile.comicsRead

            serviceStats[.kavita] = JournalServiceStats(
                id: JournalStatsSource.kavita.rawValue,
                serviceName: JournalStatsSource.kavita.displayName,
                systemImage: JournalStatsSource.kavita.systemImage,
                totalSeconds: totalSeconds,
                readingSeconds: totalSeconds,
                listeningSeconds: 0,
                sessionsCount: history.count,
                booksFinished: finished,
                booksInProgress: 0,
                totalBooks: finished,
                currentStreak: Self.journalCurrentStreak(daily),
                longestStreak: Self.journalLongestStreak(daily),
                dailySeconds: daily,
                pagesRead: profile.pagesRead,
                isAvailable: true,
                category: .selfHosted
            )
        } catch KavitaProvider.InsightsError.unavailable {
            serviceStats[.kavita] = Self.journalEmptyStats(for: .kavita)
        } catch {
            serviceErrors[.kavita] = error.localizedDescription
            serviceStats[.kavita] = Self.journalEmptyStats(for: .kavita)
        }
    }

    private func loadHardcoverStats() async {
        let apiKey = SettingsManager.shared.hardcoverApiKey ?? ""
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            serviceStats[.hardcover] = Self.journalEmptyStats(for: .hardcover)
            return
        }

        loadingServices.insert(.hardcover)
        defer { loadingServices.remove(.hardcover) }

        do {
            _ = try await HardcoverService.shared.getCurrentUser()
            let userBooks = try await HardcoverService.shared.getUserBooks(limit: 200)
            serviceStats[.hardcover] = JournalServiceStats(
                id: JournalStatsSource.hardcover.rawValue,
                serviceName: JournalStatsSource.hardcover.displayName,
                systemImage: JournalStatsSource.hardcover.systemImage,
                totalSeconds: 0,
                readingSeconds: 0,
                listeningSeconds: 0,
                sessionsCount: 0,
                booksFinished: userBooks.filter { $0.statusId == 3 }.count,
                booksInProgress: userBooks.filter { $0.statusId == 2 }.count,
                totalBooks: userBooks.count,
                currentStreak: 0,
                longestStreak: 0,
                dailySeconds: [:],
                pagesRead: 0,
                isAvailable: true,
                category: .metadataOnly
            )
        } catch {
            serviceErrors[.hardcover] = error.localizedDescription
            serviceStats[.hardcover] = Self.journalEmptyStats(for: .hardcover)
        }
    }

    private func loadSessions() async {
        let listening = await HistorySessionStore.shared.loadListeningSessions()
        let reading = await HistorySessionStore.shared.loadReadingSessions()
        let remote = await journal.remoteHistorySessions()

        var seen = Set<String>()
        var unique: [HistorySession] = []
        for session in (listening + reading + remote).sorted(by: { $0.startTime > $1.startTime }) {
            guard seen.insert(session.id).inserted else { continue }
            unique.append(session)
        }
        allSessions = unique
        recentSessions = Array(unique.prefix(20))
    }

    private func loadSessionBackedStats() {
        for (source, historySource) in [(JournalStatsSource.plex, HistorySource.plex), (.jellyfin, .jellyfin)] {
            let sessions = allSessions.filter { $0.source == historySource }
            guard !sessions.isEmpty else {
                serviceStats[source] = Self.journalEmptyStats(for: source)
                continue
            }

            var daily: [String: TimeInterval] = [:]
            for session in sessions {
                daily[JournalStats.dayKey(for: session.startTime), default: 0] += TimeInterval(session.durationSeconds)
            }
            let books = Dictionary(grouping: sessions, by: \.bookId)
            let finished = books.values.filter { sessions in
                sessions.compactMap(\.endProgress).max().map { $0 >= 0.99 } ?? false
            }.count
            let totalSeconds = TimeInterval(sessions.reduce(0) { $0 + $1.durationSeconds })

            serviceStats[source] = JournalServiceStats(
                id: source.rawValue,
                serviceName: source.displayName,
                systemImage: source.systemImage,
                totalSeconds: totalSeconds,
                readingSeconds: 0,
                listeningSeconds: totalSeconds,
                sessionsCount: sessions.count,
                booksFinished: finished,
                booksInProgress: max(0, books.count - finished),
                totalBooks: books.count,
                currentStreak: Self.journalCurrentStreak(daily),
                longestStreak: Self.journalLongestStreak(daily),
                dailySeconds: daily,
                pagesRead: sessions.compactMap(\.pagesRead).reduce(0, +),
                isAvailable: true,
                category: source.category
            )
        }
    }

    func recomputeCombined() {
        let active = serviceStats.values.filter(\.isAvailable)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let cutoff: Date? = {
            switch selectedRange {
            case .week: calendar.date(byAdding: .day, value: -7, to: today)
            case .month: calendar.date(byAdding: .day, value: -30, to: today)
            case .year: calendar.date(byAdding: .year, value: -1, to: today)
            case .allTime: nil
            }
        }()

        var mergedDaily: [String: TimeInterval] = [:]
        var periodTotal: TimeInterval = 0
        var periodListening: TimeInterval = 0
        var periodReading: TimeInterval = 0

        for stat in active {
            for (key, value) in stat.dailySeconds {
                guard let date = Self.journalDayFormatter.date(from: key) else { continue }
                if let cutoff, date < cutoff { continue }
                mergedDaily[key, default: 0] += value
                periodTotal += value
                if stat.totalSeconds > 0 {
                    periodListening += value * (stat.listeningSeconds / stat.totalSeconds)
                    periodReading += value * (stat.readingSeconds / stat.totalSeconds)
                }
            }
        }

        let isAllTime = selectedRange == .allTime
        combinedDailySeconds = mergedDaily
        combinedTotalSeconds = isAllTime ? active.reduce(0) { $0 + $1.totalSeconds } : periodTotal
        combinedSessions =
            isAllTime
            ? active.reduce(0) { $0 + $1.sessionsCount }
            : allSessions.filter { s in cutoff.map { s.startTime >= $0 } ?? true }.count
        combinedPagesRead = active.reduce(0) { $0 + $1.pagesRead }
        combinedBooksFinished = active.reduce(0) { $0 + $1.booksFinished }
        combinedBooksInProgress = active.reduce(0) { $0 + $1.booksInProgress }
        combinedTotalBooks = active.reduce(0) { $0 + $1.totalBooks }
        combinedCurrentStreak = active.map(\.currentStreak).max() ?? 0
        combinedLongestStreak = active.map(\.longestStreak).max() ?? 0

        if isAllTime {
            totalListeningSeconds = 0
            totalReadingSeconds = 0
            for (source, stat) in serviceStats where stat.isAvailable {
                if source.isListening { totalListeningSeconds += stat.totalSeconds }
                if source.isReading { totalReadingSeconds += stat.totalSeconds }
            }
        } else {
            totalListeningSeconds = periodListening
            totalReadingSeconds = periodReading
        }

        if let best = combinedDailySeconds.max(by: { $0.value < $1.value }), best.value > 0 {
            bestDayDate = best.key
            bestDaySeconds = best.value
        } else {
            bestDayDate = nil
            bestDaySeconds = 0
        }
        longestSession = allSessions.max { $0.durationSeconds < $1.durationSeconds }
        weeklyGoalHours = PlayerStateStore.shared.loadWeeklyGoal()
    }

    func hourlyDistribution() -> [Int: TimeInterval] {
        let calendar = Calendar.current
        var buckets: [Int: TimeInterval] = [:]
        for hour in 0..<24 {
            buckets[hour] = 0
        }
        for session in allSessions {
            let hour = calendar.component(.hour, from: session.startTime)
            buckets[hour, default: 0] += TimeInterval(session.durationSeconds)
        }
        return buckets
    }

    func peakHourLabel() -> String? {
        let dist = hourlyDistribution()
        guard let peak = dist.max(by: { $0.value < $1.value }), peak.value > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let calendar = Calendar.current
        guard let start = calendar.date(from: DateComponents(hour: peak.key)),
            let end = calendar.date(byAdding: .hour, value: 1, to: start)
        else { return nil }
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    func averageMinutesPerDay() -> Double {
        let days: Double = {
            switch selectedRange {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            case .allTime:
                guard
                    let earliest = combinedDailySeconds.keys
                        .compactMap({ Self.journalDayFormatter.date(from: $0) }).min()
                else { return 1 }
                return max(Date().timeIntervalSince(earliest) / 86400, 1)
            }
        }()
        return (combinedTotalSeconds / 60) / days
    }

    func weeklyHours() -> Double { journalHours(in: combinedDailySeconds, lastDays: 7) }

    func chartData() -> [(label: String, seconds: TimeInterval)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        func dayValue(_ date: Date) -> TimeInterval {
            combinedDailySeconds[JournalStats.dayKey(for: date)] ?? 0
        }

        switch selectedRange {
        case .week:
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE"
            return (0..<7).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -6 + offset, to: today) else { return nil }
                return (fmt.string(from: day), dayValue(day))
            }
        case .month, .allTime:
            let fmt = DateFormatter()
            fmt.dateFormat = "d"
            return (0..<30).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -29 + offset, to: today) else { return nil }
                return (offset % 5 == 0 ? fmt.string(from: day) : "", dayValue(day))
            }
        case .year:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM"
            return (0..<52).compactMap { week in
                guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -51 + week, to: today) else { return nil }
                var total: TimeInterval = 0
                for d in 0..<7 {
                    if let day = calendar.date(byAdding: .day, value: d, to: weekStart) {
                        total += dayValue(day)
                    }
                }
                return (week % 8 == 0 ? fmt.string(from: weekStart) : "", total)
            }
        }
    }

    private static func journalEmptyStats(for source: JournalStatsSource) -> JournalServiceStats {
        JournalServiceStats(
            id: source.rawValue,
            serviceName: source.displayName,
            systemImage: source.systemImage,
            totalSeconds: 0,
            readingSeconds: 0,
            listeningSeconds: 0,
            sessionsCount: 0,
            booksFinished: 0,
            booksInProgress: 0,
            totalBooks: 0,
            currentStreak: 0,
            longestStreak: 0,
            dailySeconds: [:],
            pagesRead: 0,
            isAvailable: false,
            category: source.category
        )
    }

    private static let journalDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        return fmt
    }()

    private static func journalCurrentStreak(_ daily: [String: TimeInterval]) -> Int {
        JournalStats.streak(daily)
    }

    private static func journalLongestStreak(_ daily: [String: TimeInterval]) -> Int {
        let dates = daily.filter { $0.value > 0 }.keys.compactMap { journalDayFormatter.date(from: $0) }.sorted()
        guard var previous = dates.first else { return 0 }
        var longest = 1
        var run = 1
        for date in dates.dropFirst() {
            if date.timeIntervalSince(previous) <= 86400 * 1.5 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    private static func journalParseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func journalGrimmoryFinished(_ book: GrimmoryRecentBook) -> Bool {
        let status = book.readStatus?.lowercased() ?? ""
        return status == "read" || status == "completed" || status == "finished" || (book.readProgress ?? 0) >= 99
    }

    private static func journalGrimmoryInProgress(_ book: GrimmoryRecentBook) -> Bool {
        let status = book.readStatus?.lowercased() ?? ""
        if journalGrimmoryFinished(book) || status == "abandoned" { return false }
        return (book.readProgress ?? 0) > 0 || status == "reading" || status == "in_progress"
    }
}
