import Foundation

extension KavitaProvider {

    enum InsightsError: Error {
        case unavailable
    }

    struct Account: Decodable, Sendable {
        let id: Int
        let username: String?
        let email: String?
        let roles: [String]?

        var isAdmin: Bool {
            roles?.contains { $0.caseInsensitiveCompare("Admin") == .orderedSame } ?? false
        }

        var displayName: String { username ?? email ?? "Account" }
    }

    struct ProfileBar: Decodable, Sendable {
        let booksRead: Int
        let comicsRead: Int
        let pagesRead: Int
        let wordsRead: Int
        let authorsRead: Int
    }

    struct ReadTotals: Decodable, Sendable {
        let totalPagesRead: Int
        let totalWordsRead: Int
        let timeSpentReading: Int
        let lastActiveUtc: String?
        let avgHoursPerWeekSpentReading: Double
    }

    struct ReadingPace: Decodable, Sendable {
        let hoursRead: Int
        let pagesRead: Int
        let wordsRead: Int
        let booksRead: Int
        let comicsRead: Int
        let daysInRange: Int

        static let zero = ReadingPace(hoursRead: 0, pagesRead: 0, wordsRead: 0, booksRead: 0, comicsRead: 0, daysInRange: 0)

        func merged(with other: ReadingPace) -> ReadingPace {
            ReadingPace(
                hoursRead: hoursRead + other.hoursRead,
                pagesRead: pagesRead + other.pagesRead,
                wordsRead: wordsRead + other.wordsRead,
                booksRead: booksRead + other.booksRead,
                comicsRead: comicsRead + other.comicsRead,
                daysInRange: max(daysInRange, other.daysInRange)
            )
        }
    }

    struct ActivityDay: Decodable, Sendable {
        let totalTimeReadingSeconds: Int
        let totalPages: Int
        let totalWords: Int
        let totalChaptersFullyRead: Int
    }

    struct IntCount: Decodable, Sendable {
        let value: Int
        let count: Int
    }

    struct StringCount: Decodable, Sendable {
        let value: String?
        let count: Int
    }

    struct Breakdown: Decodable, Sendable {
        let data: [StringCount]?
        let total: Int
        let missing: Int
    }

    struct HourBreakdown: Decodable, Sendable {
        let stats: [IntCount]?
    }

    struct FavoriteAuthor: Decodable, Sendable, Identifiable {
        let authorId: Int
        let authorName: String?
        let totalChaptersRead: Int

        var id: Int { authorId }
    }

    struct HistoryEntry: Decodable, Sendable, Identifiable {
        let sessionId: Int
        let startTimeUtc: String
        let endTimeUtc: String
        let localDate: String
        let seriesId: Int
        let seriesName: String?
        let libraryId: Int
        let libraryName: String?
        let pagesRead: Int
        let wordsRead: Int
        let durationSeconds: Int
        let totalPages: Int

        var id: Int { sessionId }

        var day: Date? { KavitaInsightsDate.parse(localDate) ?? KavitaInsightsDate.parse(startTimeUtc) }
    }

    struct Annotation: Decodable, Sendable, Identifiable {
        let id: Int
        let selectedText: String?
        let commentPlainText: String?
        let chapterTitle: String?
        let pageNumber: Int
        let seriesName: String?
        let libraryName: String?
        let seriesId: Int
        let chapterId: Int
        let createdUtc: String

        var createdAt: Date? { KavitaInsightsDate.parse(createdUtc) }
        var text: String { (selectedText?.isEmpty == false ? selectedText : commentPlainText) ?? "" }
        var note: String? {
            guard let comment = commentPlainText, !comment.isEmpty, comment != selectedText else { return nil }
            return comment
        }
    }

    func fetchAccount() async throws -> Account {
        try await insightsJSON("/api/Account/refresh-account")
    }

    func fetchProfileBar(userId: Int, days: Int) async throws -> ProfileBar {
        try await insightsJSON("/api/Stats/user-stats", queryItems: statsFilter(days: days, userId: userId))
    }

    func fetchReadTotals(userId: Int) async throws -> ReadTotals {
        try await insightsJSON("/api/Stats/user-read", queryItems: [URLQueryItem(name: "userId", value: String(userId))])
    }

    func fetchReadingPace(userId: Int, days: Int, booksOnly: Bool) async throws -> ReadingPace {
        try await insightsJSON(
            "/api/Stats/reading-pace",
            queryItems: statsFilter(days: days, userId: userId) + [
                URLQueryItem(name: "year", value: String(Calendar.current.component(.year, from: .now))),
                URLQueryItem(name: "booksOnly", value: booksOnly ? "true" : "false"),
            ]
        )
    }

    func fetchReadingActivity(userId: Int, year: Int) async throws -> [String: TimeInterval] {
        let raw: [String: ActivityDay] = try await insightsJSON(
            "/api/Stats/reading-activity",
            queryItems: [
                URLQueryItem(name: "userId", value: String(userId)),
                URLQueryItem(name: "year", value: String(year)),
                URLQueryItem(name: "TimeZoneId", value: TimeZone.current.identifier),
            ]
        )
        return raw.compactMapValues { $0.totalTimeReadingSeconds > 0 ? TimeInterval($0.totalTimeReadingSeconds) : nil }
    }

    func fetchDayBreakdown(userId: Int) async throws -> [IntCount] {
        try await insightsJSON("/api/Stats/day-breakdown", queryItems: [URLQueryItem(name: "userId", value: String(userId))])
    }

    func fetchHourBreakdown(userId: Int, days: Int) async throws -> [IntCount] {
        let breakdown: HourBreakdown = try await insightsJSON(
            "/api/Stats/avg-time-by-hour",
            queryItems: statsFilter(days: days, userId: userId)
        )
        return breakdown.stats ?? []
    }

    func fetchGenreBreakdown(userId: Int, days: Int) async throws -> [StringCount] {
        let breakdown: Breakdown = try await insightsJSON(
            "/api/Stats/genre-breakdown",
            queryItems: statsFilter(days: days, userId: userId)
        )
        return (breakdown.data ?? []).filter { ($0.value?.isEmpty == false) && $0.count > 0 }
    }

    func fetchFavoriteAuthors(userId: Int, days: Int) async throws -> [FavoriteAuthor] {
        try await insightsJSON("/api/Stats/favorite-authors", queryItems: statsFilter(days: days, userId: userId))
    }

    func fetchTotalReads(userId: Int) async throws -> Int {
        try await insightsJSON("/api/Stats/total-reads", queryItems: [URLQueryItem(name: "userId", value: String(userId))])
    }

    func fetchReadingHistory(page: Int, pageSize: Int, days: Int) async throws -> [HistoryEntry] {
        try await insightsJSON(
            "/api/Stats/reading-history",
            queryItems: statsFilter(days: days, userId: nil) + [
                URLQueryItem(name: "PageNumber", value: String(max(1, page))),
                URLQueryItem(name: "PageSize", value: String(min(max(1, pageSize), 100))),
            ]
        )
    }

    func fetchAnnotations(page: Int, pageSize: Int) async throws -> [Annotation] {
        let filter: [String: Any] = [
            "statements": [],
            "combination": 0,
            "sortOptions": ["sortField": 2, "isAscending": false],
            "limitTo": 0,
        ]
        try await ensureAuthenticated()
        var request = try makeRequest(
            path: "/api/Annotation/all-filtered",
            queryItems: [
                URLQueryItem(name: "PageNumber", value: String(max(1, page))),
                URLQueryItem(name: "PageSize", value: String(min(max(1, pageSize), 100))),
            ]
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: filter)
        return try await insightsDecode(request)
    }

    func fetchAnnotations(seriesId: Int) async throws -> [Annotation] {
        try await insightsJSON(
            "/api/Annotation/all-for-series",
            queryItems: [URLQueryItem(name: "seriesId", value: String(seriesId))]
        )
    }

    private func statsFilter(days: Int, userId: Int?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "TimeZoneId", value: TimeZone.current.identifier)]
        if let start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: .now) {
            items.append(URLQueryItem(name: "StartDate", value: KavitaInsightsDate.request(start)))
        }
        if let userId {
            items.append(URLQueryItem(name: "userId", value: String(userId)))
        }
        return items
    }

    private func insightsJSON<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        try await ensureAuthenticated()
        return try await insightsDecode(try makeRequest(path: path, queryItems: queryItems))
    }

    private func insightsDecode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200...299:
            break
        case 400, 403, 404, 405, 501:
            throw InsightsError.unavailable
        case 401:
            throw ProviderError.unauthorized
        default:
            throw ProviderError.serverError("Kavita returned HTTP \(response.statusCode)")
        }
        guard !data.isEmpty else { throw InsightsError.unavailable }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum KavitaInsightsDate {
    private static let formatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        .map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }

    private static let requestFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.hasSuffix("Z") ? String(raw.dropLast()) : raw
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func request(_ date: Date) -> String {
        requestFormatter.string(from: date)
    }
}
