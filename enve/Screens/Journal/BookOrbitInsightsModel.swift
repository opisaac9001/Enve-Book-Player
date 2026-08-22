import Foundation

enum BookOrbitInsightsRange: String, CaseIterable, Identifiable {
    case month = "30 days"
    case quarter = "90 days"
    case year = "Year"
    case allTime = "All time"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .allTime: 3650
        }
    }

    var caption: String {
        switch self {
        case .month: "Averaged over the last thirty days."
        case .quarter: "Averaged over the last ninety days."
        case .year: "Averaged over the last year."
        case .allTime: "Averaged over the whole record."
        }
    }
}

enum BookOrbitLoadState: Equatable {
    case loading
    case ready
    case unavailable
    case failed(String)
}

struct BookOrbitInsightsSnapshot {
    var summary: BookOrbitProvider.StatisticsSummary?
    var streak: BookOrbitProvider.ReadingStreakWidget?
    var goal: BookOrbitProvider.ReadingGoalWidget?
    var projection: BookOrbitProvider.YearProjectionWidget?
    var challenge: BookOrbitProvider.MonthlyChallengeWidget?
    var overview: BookOrbitProvider.LibraryOverviewWidget?
    var dna: BookOrbitProvider.ReadingDnaWidget?
    var diversity: BookOrbitProvider.DiversityScoreWidget?
    var highlight: BookOrbitProvider.HighlightOfTheDayWidget?
    var longWait: BookOrbitProvider.LongWaitWidget?
    var sources: BookOrbitProvider.SourceDistribution?
    var funnel: BookOrbitProvider.ProgressFunnelComparison?
    var latency: BookOrbitProvider.CompletionLatency?
    var daily: [BookOrbitProvider.DailyReading] = []
    var heatmapByDay: [String: TimeInterval] = [:]
    var peakHours: [BookOrbitProvider.PeakHour] = []
    var favoriteDays: [BookOrbitProvider.FavoriteDay] = []
    var genres: [BookOrbitProvider.GenreReadingTime] = []
    var gems: [BookOrbitProvider.NeglectedGem] = []

    var totalSeconds: TimeInterval {
        daily.reduce(0) { $0 + $1.readingSeconds }
    }

    var activeDays: Int {
        daily.filter { $0.readingSeconds > 0 }.count
    }

    var averageSecondsPerDay: TimeInterval {
        daily.isEmpty ? 0 : totalSeconds / Double(daily.count)
    }

    var hasHeatmap: Bool {
        heatmapByDay.values.contains { $0 > 0 }
    }

    var peakHourLabel: String? {
        let calendar = Calendar.current
        guard let peak = peakHours.max(by: { $0.readingSeconds < $1.readingSeconds }), peak.readingSeconds > 0,
            let date = calendar.date(byAdding: .hour, value: peak.hour, to: calendar.startOfDay(for: .now))
        else {
            return nil
        }
        return date.formatted(.dateTime.hour())
    }

    var favoriteDayLabel: String? {
        guard let best = favoriteDays.max(by: { $0.readingSeconds < $1.readingSeconds }), best.readingSeconds > 0 else {
            return nil
        }
        let symbols = Calendar.current.weekdaySymbols
        let index = ((best.dayOfWeek % 7) + 7) % 7
        return symbols.indices.contains(index) ? symbols[index] : nil
    }
}

@MainActor
@Observable
final class BookOrbitInsightsModel {
    private(set) var state: BookOrbitLoadState = .loading
    private(set) var snapshot = BookOrbitInsightsSnapshot()
    private(set) var connections: [ServerConnection] = []
    private(set) var connectionId: UUID?
    private(set) var range: BookOrbitInsightsRange = .year
    private(set) var books: [Int: Book] = [:]

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var serverName: String {
        connections.first { $0.id == connectionId }?.name ?? "BookOrbit"
    }

    func bind(preferred id: UUID?) {
        guard let id, connectionId == nil else { return }
        connectionId = id
    }

    func refresh() async {
        connections = BookOrbitAccess.connections
        if connectionId == nil || !connections.contains(where: { $0.id == connectionId }) {
            connectionId = connections.first?.id
            snapshot = BookOrbitInsightsSnapshot()
        }
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        await task.value
    }

    func select(connection id: UUID) {
        guard id != connectionId else { return }
        connectionId = id
        snapshot = BookOrbitInsightsSnapshot()
        state = .loading
        reload()
    }

    func select(range newRange: BookOrbitInsightsRange) {
        guard newRange != range else { return }
        range = newRange
        reload()
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        guard let connectionId, let provider = BookOrbitAccess.provider(connectionId) else {
            state = .unavailable
            return
        }

        let days = range.days
        do {
            let summary = try await provider.fetchStatisticsSummary()
            guard !Task.isCancelled else { return }
            snapshot.summary = summary
            state = .ready
        } catch BookOrbitProvider.FeatureError.unavailable {
            state = .unavailable
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(BookOrbitAccess.message(for: error))
            return
        }

        async let streakTask = provider.fetchReadingStreakWidget()
        async let goalTask = provider.fetchReadingGoalWidget()
        async let projectionTask = provider.fetchYearProjectionWidget()
        async let challengeTask = provider.fetchMonthlyChallengeWidget()
        async let dailyTask = provider.fetchDailyReading(days: days)
        let streak = try? await streakTask
        let goal = try? await goalTask
        let projection = try? await projectionTask
        let challenge = try? await challengeTask
        let daily = try? await dailyTask
        guard !Task.isCancelled else { return }
        snapshot.streak = streak
        snapshot.goal = goal
        snapshot.projection = projection
        snapshot.challenge = challenge
        snapshot.daily = daily ?? []

        async let heatmapTask = provider.fetchReadingHeatmap(days: 364)
        async let peakHoursTask = provider.fetchPeakHours(days: days)
        async let favoriteDaysTask = provider.fetchFavoriteDays(days: days)
        async let sourcesTask = provider.fetchSourceDistribution(days: days)
        async let genresTask = provider.fetchGenreReadingTime(days: days)
        let heatmap = try? await heatmapTask
        let peakHours = try? await peakHoursTask
        let favoriteDays = try? await favoriteDaysTask
        let sources = try? await sourcesTask
        let genres = try? await genresTask
        guard !Task.isCancelled else { return }
        snapshot.heatmapByDay = Self.heatmap(heatmap ?? [])
        snapshot.peakHours = peakHours ?? []
        snapshot.favoriteDays = favoriteDays ?? []
        snapshot.sources = sources
        snapshot.genres = genres ?? []

        async let funnelTask = provider.fetchProgressFunnel(days: days)
        async let latencyTask = provider.fetchCompletionLatency(days: days)
        async let dnaTask = provider.fetchReadingDnaWidget()
        async let diversityTask = provider.fetchDiversityScoreWidget()
        async let overviewTask = provider.fetchLibraryOverviewWidget()
        let funnel = try? await funnelTask
        let latency = try? await latencyTask
        let dna = try? await dnaTask
        let diversity = try? await diversityTask
        let overview = try? await overviewTask
        guard !Task.isCancelled else { return }
        snapshot.funnel = funnel
        snapshot.latency = latency
        snapshot.dna = dna
        snapshot.diversity = diversity
        snapshot.overview = overview

        async let highlightTask = provider.fetchHighlightOfTheDayWidget()
        async let longWaitTask = provider.fetchLongWaitWidget()
        async let gemsTask = provider.fetchNeglectedGems()
        let highlight = try? await highlightTask
        let longWait = try? await longWaitTask
        let gems = try? await gemsTask
        guard !Task.isCancelled else { return }
        snapshot.highlight = highlight ?? nil
        snapshot.longWait = longWait ?? nil
        snapshot.gems = gems ?? []

        var remoteIds = snapshot.gems.map(\.bookId)
        if let bookId = snapshot.highlight?.bookId { remoteIds.append(bookId) }
        if let bookId = snapshot.longWait?.bookId { remoteIds.append(bookId) }
        let resolved = await BookOrbitAccess.localBooks(connectionId: connectionId, remoteIds: remoteIds)
        guard !Task.isCancelled else { return }
        books = resolved
    }

    private static func heatmap(_ stats: [BookOrbitProvider.DailyReading]) -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for stat in stats where stat.readingSeconds > 0 {
            guard let key = dayKey(stat.day) else { continue }
            result[key, default: 0] += stat.readingSeconds
        }
        return result
    }

    private static func dayKey(_ raw: String) -> String? {
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else {
            return nil
        }
        return JournalStats.dayKey(for: date)
    }
}
