import Foundation

extension BookOrbitProvider {

    struct StatisticsSummary: Decodable, Sendable {
        let trackedBooks: Int
        let startedBooks: Int
        let inProgressBooks: Int
        let completedBooks: Int
        let meanProgressPercent: Double
    }

    struct DailyReading: Decodable, Sendable {
        let day: String
        let readingSeconds: Double
    }

    struct SourceDistribution: Decodable, Sendable {
        struct Share: Decodable, Sendable {
            let bucket: String
            let readingSeconds: Double
        }

        let totalSeconds: Double
        let slices: [Share]
    }

    struct PeakHour: Decodable, Sendable {
        let hour: Int
        let readingSeconds: Double
    }

    struct FavoriteDay: Decodable, Sendable {
        let dayOfWeek: Int
        let readingSeconds: Double
    }

    struct GenreReadingTime: Decodable, Sendable {
        let genre: String
        let readingSeconds: Double
    }

    struct ProgressFunnel: Decodable, Sendable {
        let started: Int
        let reached25: Int
        let reached50: Int
        let reached75: Int
        let completed: Int
    }

    struct ProgressFunnelComparison: Decodable, Sendable {
        let days: Int
        let current: ProgressFunnel
        let previous: ProgressFunnel?
    }

    struct CompletionLatency: Decodable, Sendable {
        struct Bucket: Decodable, Sendable {
            let label: String
            let count: Int
        }

        let totalCompletions: Int
        let medianDays: Double?
        let percentile90Days: Double?
        let buckets: [Bucket]
    }

    struct ReadingStreakWidget: Decodable, Sendable {
        let currentStreak: Int
        let longestStreak: Int
        let lastSevenDays: [Bool]
    }

    struct ReadingGoalWidget: Decodable, Sendable {
        let goalBooks: Int?
        let completedBooks: Int
        let year: Int
    }

    struct LibraryOverviewWidget: Decodable, Sendable {
        let totalBooks: Int
        let totalAuthors: Int
        let totalSeries: Int
        let totalStorageBytes: Double
        let booksAddedThisYear: Int
    }

    struct YearProjectionWidget: Decodable, Sendable {
        let projectedBooks: Int
        let projectedPages: Int
        let projectedHours: Double
        let booksCompletedYtd: Int
        let daysRemaining: Int
        let trend: String
    }

    struct ReadingDnaWidget: Decodable, Sendable {
        let archetype: String
        let lengthScore: Double
        let varietyScore: Double
        let rhythmScore: Double
        let timeScore: Double
        let speedScore: Double?
        let lengthLabel: String
        let varietyLabel: String
        let rhythmLabel: String
        let timeLabel: String
        let speedLabel: String
        let booksAnalyzed: Int
    }

    struct DiversityScoreWidget: Decodable, Sendable {
        let score: Double
        let label: String
        let genreScore: Double
        let authorScore: Double
        let eraScore: Double
        let languageScore: Double
        let booksAnalyzed: Int
    }

    struct MonthlyChallengeWidget: Decodable, Sendable {
        let challengeType: String
        let title: String
        let description: String
        let progress: Double
        let target: Double
        let completed: Bool
        let month: Int
        let year: Int
    }

    struct HighlightOfTheDayWidget: Decodable, Sendable {
        let text: String
        let note: String?
        let bookTitle: String?
        let bookId: Int
        let chapterTitle: String?
        let createdAt: Date
    }

    struct NeglectedGem: Decodable, Sendable {
        let bookId: Int
        let title: String?
        let rating: Double
        let waitingDays: Int
        let genre: String?
    }

    struct LongWaitWidget: Decodable, Sendable {
        let bookId: Int
        let title: String?
        let waitingDays: Int
        let genre: String?
    }

    struct Achievement: Decodable, Sendable {
        let key: String
        let name: String
        let description: String
        let iconName: String
        let rarity: String
        let threshold: Double?
        let hidden: Bool
        let earned: Bool
        let currentProgress: Double?
    }

    struct AchievementCategory: Decodable, Sendable {
        let key: String
        let label: String
        let earnedCount: Int
        let totalCount: Int
        let achievements: [Achievement]
    }

    struct AchievementCatalogue: Decodable, Sendable {
        let categories: [AchievementCategory]
        let totalEarned: Int
        let totalAvailable: Int
    }

    struct RelatedBook: Decodable, Sendable, Identifiable {
        let id: Int
        let title: String?
        let hasCover: Bool
        let isAudiobook: Bool?
    }

    struct AnnotationHubItem: Decodable, Sendable, Identifiable {
        let id: Int
        let bookId: Int
        let text: String
        let note: String?
        let chapterTitle: String?
        let origin: String
        let createdAt: Date
        let bookTitle: String?
        let author: String?
    }

    struct AnnotationHubPage: Decodable, Sendable {
        struct Stats: Decodable, Sendable {
            let books: Int
            let withNotes: Int
        }

        let items: [AnnotationHubItem]
        let total: Int
        let stats: Stats
    }

    struct AnnotationHubBookFacet: Decodable, Sendable, Identifiable {
        let bookId: Int
        let bookTitle: String?
        let count: Int

        var id: Int { bookId }
    }

    struct AnnotationHubQuery: Sendable {
        var page = 1
        var pageSize = 50
        var bookId: Int?
        var search: String?
        var trashed = false

        var queryItems: [URLQueryItem] {
            var items = [
                URLQueryItem(name: "page", value: String(max(1, page))),
                URLQueryItem(name: "pageSize", value: String(min(max(1, pageSize), 100))),
                URLQueryItem(name: "status", value: trashed ? "trashed" : "active"),
            ]
            if let bookId { items.append(URLQueryItem(name: "bookId", value: String(bookId))) }
            if let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                items.append(URLQueryItem(name: "search", value: String(trimmed.prefix(200))))
            }
            return items
        }
    }

    var statisticsLibraryIds: [URLQueryItem] {
        (connection.selectedLibraryIds ?? [])
            .compactMap(Int.init)
            .sorted()
            .map { URLQueryItem(name: "libraryIds", value: String($0)) }
    }

    func coverURL(bookId: Int) -> URL? {
        URL(string: connection.url)?.appendingPathComponent("api/v1/books/\(bookId)/cover")
    }

    func fetchStatisticsSummary() async throws -> StatisticsSummary {
        try await requestJSON("user-statistics/summary", query: statisticsLibraryIds)
    }

    func fetchDailyReading(days: Int) async throws -> [DailyReading] {
        try await requestJSON("user-statistics/daily-reading", query: statisticsQuery(days: days))
    }

    func fetchReadingHeatmap(days: Int) async throws -> [DailyReading] {
        try await requestJSON("user-statistics/reading-heatmap", query: statisticsQuery(days: days))
    }

    func fetchSourceDistribution(days: Int) async throws -> SourceDistribution {
        try await requestJSON("user-statistics/reading-source-distribution", query: statisticsQuery(days: days))
    }

    func fetchPeakHours(days: Int) async throws -> [PeakHour] {
        try await requestJSON("user-statistics/peak-hours", query: statisticsQuery(days: days))
    }

    func fetchFavoriteDays(days: Int) async throws -> [FavoriteDay] {
        try await requestJSON("user-statistics/favorite-days", query: statisticsQuery(days: days))
    }

    func fetchGenreReadingTime(days: Int) async throws -> [GenreReadingTime] {
        try await requestJSON("user-statistics/genre-reading-time", query: statisticsQuery(days: days))
    }

    func fetchProgressFunnel(days: Int) async throws -> ProgressFunnelComparison {
        try await requestJSON(
            "user-statistics/progress-funnel",
            query: statisticsQuery(days: days) + [URLQueryItem(name: "comparePrevious", value: "true")]
        )
    }

    func fetchCompletionLatency(days: Int) async throws -> CompletionLatency {
        try await requestJSON("user-statistics/completion-latency", query: statisticsQuery(days: days))
    }

    func fetchReadingStreakWidget() async throws -> ReadingStreakWidget {
        try await requestJSON("dashboard/widgets/reading-streak")
    }

    func fetchReadingGoalWidget() async throws -> ReadingGoalWidget {
        try await requestJSON("dashboard/widgets/reading-goal")
    }

    func fetchLibraryOverviewWidget() async throws -> LibraryOverviewWidget {
        try await requestJSON("dashboard/widgets/library-overview")
    }

    func fetchYearProjectionWidget() async throws -> YearProjectionWidget {
        try await requestJSON("dashboard/widgets/year-projection")
    }

    func fetchReadingDnaWidget() async throws -> ReadingDnaWidget {
        try await requestJSON("dashboard/widgets/reading-dna")
    }

    func fetchDiversityScoreWidget() async throws -> DiversityScoreWidget {
        try await requestJSON("dashboard/widgets/diversity-score")
    }

    func fetchMonthlyChallengeWidget() async throws -> MonthlyChallengeWidget {
        try await requestJSON("dashboard/widgets/monthly-challenge")
    }

    func fetchHighlightOfTheDayWidget() async throws -> HighlightOfTheDayWidget? {
        try await requestOptionalJSON("dashboard/widgets/highlight-of-the-day")
    }

    func fetchLongWaitWidget() async throws -> LongWaitWidget? {
        try await requestOptionalJSON("dashboard/widgets/long-wait")
    }

    func fetchNeglectedGems() async throws -> [NeglectedGem] {
        let widget: NeglectedGemsWidget = try await requestJSON("dashboard/widgets/neglected-gems")
        return widget.gems
    }

    func fetchAchievementCatalogue() async throws -> AchievementCatalogue {
        try await requestJSON("achievements")
    }

    func fetchRecommendations(bookId: String) async throws -> [RelatedBook] {
        try await requestRelated(bookId: bookId, path: "recommendations")
    }

    func fetchSeriesBooks(bookId: String) async throws -> [RelatedBook] {
        try await requestRelated(bookId: bookId, path: "series-books")
    }

    func fetchAuthorBooks(bookId: String) async throws -> [RelatedBook] {
        try await requestRelated(bookId: bookId, path: "author-books")
    }

    func fetchAnnotations(_ query: AnnotationHubQuery) async throws -> AnnotationHubPage {
        try await requestJSON("annotations", query: query.queryItems)
    }

    func fetchAnnotationBooks(trashed: Bool, search: String?) async throws -> [AnnotationHubBookFacet] {
        var items = [
            URLQueryItem(name: "status", value: trashed ? "trashed" : "active"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: String(trimmed.prefix(200))))
        }
        return try await requestJSON("annotations/books", query: items)
    }

    func trashAnnotations(ids: [Int]) async throws {
        try await bulkAnnotations(ids: ids, action: "trash")
    }

    func restoreAnnotations(ids: [Int]) async throws {
        try await bulkAnnotations(ids: ids, action: "restore")
    }

    func purgeAnnotation(id: Int) async throws {
        try await requestVoid("annotations/\(id)", method: "DELETE")
    }

    func exportAnnotations(_ query: AnnotationHubQuery, format: String) async throws -> URL {
        let (data, http) = try await requestRaw(
            "annotations/export",
            query: query.queryItems + [URLQueryItem(name: "format", value: format)]
        )
        let name = Self.attachmentFilename(from: http) ?? "bookorbit-annotations.\(format)"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private struct NeglectedGemsWidget: Decodable {
        let gems: [NeglectedGem]
    }

    private func statisticsQuery(days: Int) -> [URLQueryItem] {
        statisticsLibraryIds + [URLQueryItem(name: "days", value: String(min(max(days, 1), 3650)))]
    }

    private func requestRelated(bookId: String, path: String) async throws -> [RelatedBook] {
        guard let id = Int(bookId) else { throw ProviderError.invalidURL }
        return try await requestJSON("books/\(id)/\(path)")
    }

    private func bulkAnnotations(ids: [Int], action: String) async throws {
        guard !ids.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: ["ids": Array(ids.prefix(500)), "action": action])
        try await requestVoid("annotations/bulk", method: "POST", body: body)
    }

    private static func attachmentFilename(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Content-Disposition"),
            let range = header.range(of: "filename=\"") ?? header.range(of: "filename=")
        else {
            return nil
        }
        let start = range.upperBound
        let end = header[start...].firstIndex(of: "\"") ?? header.endIndex
        let name = String(header[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name.replacingOccurrences(of: "/", with: "-")
    }
}
