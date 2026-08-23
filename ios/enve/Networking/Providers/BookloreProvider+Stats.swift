import Foundation

nonisolated struct GrimmoryStatsSnapshot: Sendable {
    let year: Int
    let streak: GrimmoryReadingStreak?
    let readingHeatmap: [GrimmoryActivityDay]
    let readingPeakHours: [GrimmoryPeakHour]
    let readingFavoriteDays: [GrimmoryFavoriteDay]
    let readingGenres: [GrimmoryGenreStat]
    let completionTimeline: [GrimmoryCompletionMonth]
    let completionHeatmap: [GrimmoryCompletionHeatmapMonth]
    let pageTurners: [GrimmoryPageTurner]
    let distributions: GrimmoryBookDistributions?
    let readingSpeed: [GrimmoryReadingSpeedDay]
    let readingSessions: [GrimmorySessionPoint]
    let bookTimeline: [GrimmoryBookTimelineEntry]
    let completionRace: [GrimmoryCompletionRacePoint]
    let listeningTrend: [GrimmoryListeningWeek]
    let listeningCompletion: GrimmoryListeningCompletion?
    let listeningPace: [GrimmoryListeningMonth]
    let listeningFunnel: GrimmoryListeningFunnel?
    let listeningPeakHours: [GrimmoryPeakHour]
    let listeningFavoriteDays: [GrimmoryFavoriteDay]
    let listeningGenres: [GrimmoryGenreStat]
    let listeningAuthors: [GrimmoryAuthorStat]
    let listeningSessions: [GrimmorySessionPoint]
    let longestAudiobooks: [GrimmoryLongestAudiobook]

    var hasData: Bool {
        streak != nil
            || !readingHeatmap.isEmpty
            || !readingPeakHours.isEmpty
            || !readingFavoriteDays.isEmpty
            || !readingGenres.isEmpty
            || !completionTimeline.isEmpty
            || !completionHeatmap.isEmpty
            || !pageTurners.isEmpty
            || distributions != nil
            || !readingSpeed.isEmpty
            || !readingSessions.isEmpty
            || !bookTimeline.isEmpty
            || !completionRace.isEmpty
            || !listeningTrend.isEmpty
            || listeningCompletion != nil
            || !listeningPace.isEmpty
            || listeningFunnel != nil
            || !listeningPeakHours.isEmpty
            || !listeningFavoriteDays.isEmpty
            || !listeningGenres.isEmpty
            || !listeningAuthors.isEmpty
            || !listeningSessions.isEmpty
            || !longestAudiobooks.isEmpty
    }
}

nonisolated struct GrimmoryReadingStreak: Decodable, Sendable {
    let currentStreak: Int
    let longestStreak: Int
    let totalReadingDays: Int
    let last52Weeks: [GrimmoryStreakDay]
}

nonisolated struct GrimmoryStreakDay: Decodable, Sendable, Identifiable {
    let date: String
    let active: Bool
    var id: String { date }
}

nonisolated struct GrimmoryActivityDay: Decodable, Sendable, Identifiable {
    let date: String
    let count: Int
    var id: String { date }
}

nonisolated struct GrimmoryPeakHour: Decodable, Sendable, Identifiable {
    let hourOfDay: Int
    let sessionCount: Int
    let totalDurationSeconds: Int
    var id: Int { hourOfDay }
}

nonisolated struct GrimmoryFavoriteDay: Decodable, Sendable, Identifiable {
    let dayOfWeek: Int
    let dayName: String
    let sessionCount: Int
    let totalDurationSeconds: Int
    var id: Int { dayOfWeek }
}

nonisolated struct GrimmoryGenreStat: Decodable, Sendable, Identifiable {
    let genre: String
    let bookCount: Int
    let totalSessions: Int
    let totalDurationSeconds: Int
    let averageSessionsPerBook: Double
    var id: String { genre }
}

nonisolated struct GrimmoryCompletionMonth: Decodable, Sendable, Identifiable {
    let year: Int
    let month: Int
    let totalBooks: Int
    let statusBreakdown: [String: Int]
    let finishedBooks: Int
    let completionRate: Double
    var id: String { "\(year)-\(month)" }
}

nonisolated struct GrimmoryCompletionHeatmapMonth: Decodable, Sendable, Identifiable {
    let year: Int
    let month: Int
    let count: Int
    var id: String { "\(year)-\(month)" }
}

nonisolated struct GrimmoryPageTurner: Decodable, Sendable, Identifiable {
    let bookId: Int
    let bookTitle: String
    let categories: [String]
    let pageCount: Int?
    let personalRating: Int?
    let gripScore: Int
    let totalSessions: Int
    let avgSessionDurationSeconds: Double
    let sessionAcceleration: Double
    let gapReduction: Double
    let finishBurst: Bool
    var id: Int { bookId }
}

nonisolated struct GrimmoryBookDistributions: Decodable, Sendable {
    let ratingDistribution: [GrimmoryRatingBucket]
    let progressDistribution: [GrimmoryProgressBucket]
    let statusDistribution: [GrimmoryStatusBucket]
}

nonisolated struct GrimmoryRatingBucket: Decodable, Sendable, Identifiable {
    let rating: Int
    let count: Int
    var id: Int { rating }
}

nonisolated struct GrimmoryProgressBucket: Decodable, Sendable, Identifiable {
    let range: String
    let min: Int
    let max: Int
    let count: Int
    var id: String { range }
}

nonisolated struct GrimmoryStatusBucket: Decodable, Sendable, Identifiable {
    let status: String
    let count: Int
    var id: String { status }
}

nonisolated struct GrimmoryReadingSpeedDay: Decodable, Sendable, Identifiable {
    let date: String
    let avgProgressPerMinute: Double
    let totalSessions: Int
    var id: String { date }
}

nonisolated struct GrimmorySessionPoint: Decodable, Sendable, Identifiable {
    let hourOfDay: Double
    let durationMinutes: Double
    let dayOfWeek: Int
    var id: String { "\(hourOfDay)-\(durationMinutes)-\(dayOfWeek)" }
}

nonisolated struct GrimmoryBookTimelineEntry: Decodable, Sendable, Identifiable {
    let bookId: Int
    let title: String
    let pageCount: Int?
    let firstSessionDate: String
    let lastSessionDate: String
    let totalSessions: Int
    let totalDurationSeconds: Int
    let maxProgress: Double
    let readStatus: String?
    var id: Int { bookId }
}

nonisolated struct GrimmoryCompletionRacePoint: Decodable, Sendable, Identifiable {
    let bookId: Int
    let bookTitle: String
    let sessionDate: String
    let endProgress: Double
    var id: String { "\(bookId)-\(sessionDate)-\(endProgress)" }
}

nonisolated struct GrimmoryListeningWeek: Decodable, Sendable, Identifiable {
    let year: Int
    let week: Int
    let totalDurationSeconds: Int
    let sessions: Int
    var id: String { "\(year)-\(week)" }
}

nonisolated struct GrimmoryListeningCompletion: Decodable, Sendable {
    let totalAudiobooks: Int
    let completed: Int
    let inProgressCount: Int
    let inProgress: [GrimmoryAudiobookProgress]
}

nonisolated struct GrimmoryAudiobookProgress: Decodable, Sendable, Identifiable {
    let bookId: Int
    let title: String
    let progressPercent: Double
    let totalDurationSeconds: Int
    let listenedDurationSeconds: Int
    var id: Int { bookId }
}

nonisolated struct GrimmoryListeningMonth: Decodable, Sendable, Identifiable {
    let year: Int
    let month: Int
    let booksCompleted: Int
    let totalListeningSeconds: Int
    var id: String { "\(year)-\(month)" }
}

nonisolated struct GrimmoryListeningFunnel: Decodable, Sendable {
    let totalStarted: Int
    let reached25: Int
    let reached50: Int
    let reached75: Int
    let completed: Int
}

nonisolated struct GrimmoryAuthorStat: Decodable, Sendable, Identifiable {
    let author: String
    let bookCount: Int
    let totalSessions: Int
    let totalDurationSeconds: Int
    var id: String { author }
}

nonisolated struct GrimmoryLongestAudiobook: Decodable, Sendable, Identifiable {
    let bookId: Int
    let title: String
    let totalDurationSeconds: Int
    let listenedDurationSeconds: Int
    let progressPercent: Double
    var id: Int { bookId }
}

extension BookloreProvider {
    func fetchGrimmoryStats(year: Int = Calendar.current.component(.year, from: .now)) async -> GrimmoryStatsSnapshot {
        async let streak: GrimmoryReadingStreak? = statsValue("/api/v1/user-stats/reading/streak")
        async let readingHeatmap: [GrimmoryActivityDay] = statsArray("/api/v1/user-stats/reading/heatmap", year: year)
        async let readingPeakHours: [GrimmoryPeakHour] = statsArray("/api/v1/user-stats/reading/peak-hours", year: year)
        async let readingFavoriteDays: [GrimmoryFavoriteDay] = statsArray("/api/v1/user-stats/reading/favorite-days", year: year)
        async let readingGenres: [GrimmoryGenreStat] = statsArray("/api/v1/user-stats/reading/genres")
        async let completionTimeline: [GrimmoryCompletionMonth] = statsArray("/api/v1/user-stats/reading/completion-timeline", year: year)
        async let completionHeatmap: [GrimmoryCompletionHeatmapMonth] = statsArray("/api/v1/user-stats/reading/book-completion-heatmap")
        async let pageTurners: [GrimmoryPageTurner] = statsArray("/api/v1/user-stats/reading/page-turner-scores")
        async let distributions: GrimmoryBookDistributions? = statsValue("/api/v1/user-stats/reading/book-distributions")
        async let readingSpeed: [GrimmoryReadingSpeedDay] = statsArray("/api/v1/user-stats/reading/speed", year: year)
        async let readingSessions: [GrimmorySessionPoint] = statsArray("/api/v1/user-stats/reading/session-scatter", year: year)
        async let bookTimeline: [GrimmoryBookTimelineEntry] = statsArray("/api/v1/user-stats/reading/book-timeline", year: year)
        async let completionRace: [GrimmoryCompletionRacePoint] = statsArray("/api/v1/user-stats/reading/completion-race", year: year)
        async let listeningTrend: [GrimmoryListeningWeek] = statsArray("/api/v1/user-stats/listening/weekly-trend", queryItems: [URLQueryItem(name: "weeks", value: "26")])
        async let listeningCompletion: GrimmoryListeningCompletion? = statsValue("/api/v1/user-stats/listening/completion")
        async let listeningPace: [GrimmoryListeningMonth] = statsArray("/api/v1/user-stats/listening/monthly-pace", queryItems: [URLQueryItem(name: "months", value: "12")])
        async let listeningFunnel: GrimmoryListeningFunnel? = statsValue("/api/v1/user-stats/listening/finish-funnel")
        async let listeningPeakHours: [GrimmoryPeakHour] = statsArray("/api/v1/user-stats/listening/peak-hours", year: year)
        async let listeningFavoriteDays: [GrimmoryFavoriteDay] = statsArray("/api/v1/user-stats/listening/favorite-days", year: year)
        async let listeningGenres: [GrimmoryGenreStat] = statsArray("/api/v1/user-stats/listening/genres")
        async let listeningAuthors: [GrimmoryAuthorStat] = statsArray("/api/v1/user-stats/listening/authors")
        async let listeningSessions: [GrimmorySessionPoint] = statsArray("/api/v1/user-stats/listening/session-scatter")
        async let longestAudiobooks: [GrimmoryLongestAudiobook] = statsArray("/api/v1/user-stats/listening/longest-books")

        return await GrimmoryStatsSnapshot(
            year: year,
            streak: streak,
            readingHeatmap: readingHeatmap,
            readingPeakHours: readingPeakHours,
            readingFavoriteDays: readingFavoriteDays,
            readingGenres: readingGenres,
            completionTimeline: completionTimeline,
            completionHeatmap: completionHeatmap,
            pageTurners: pageTurners,
            distributions: distributions,
            readingSpeed: readingSpeed,
            readingSessions: readingSessions,
            bookTimeline: bookTimeline,
            completionRace: completionRace,
            listeningTrend: listeningTrend,
            listeningCompletion: listeningCompletion,
            listeningPace: listeningPace,
            listeningFunnel: listeningFunnel,
            listeningPeakHours: listeningPeakHours,
            listeningFavoriteDays: listeningFavoriteDays,
            listeningGenres: listeningGenres,
            listeningAuthors: listeningAuthors,
            listeningSessions: listeningSessions,
            longestAudiobooks: longestAudiobooks
        )
    }

    private func statsArray<T: Decodable>(
        _ path: String,
        year: Int? = nil,
        queryItems: [URLQueryItem] = []
    ) async -> [T] {
        var items = queryItems
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        return (try? await statsRequest(path, queryItems: items, as: [T].self)) ?? []
    }

    private func statsValue<T: Decodable>(_ path: String) async -> T? {
        try? await statsRequest(path, as: T.self)
    }

    private func statsRequest<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        let request = try makeRequest(path: path, queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Grimmory stats returned HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
