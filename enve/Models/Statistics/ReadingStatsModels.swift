import Foundation

public struct BookReadingStat: Codable, Equatable, Sendable {
    public var bookId: String
    public var totalSecondsRead: TimeInterval
    public var sessionCount: Int
    public var lastRead: Date?
    public var lastPositionProgression: Double?
    public var totalPages: Int?
    public var isCompleted: Bool

    nonisolated public init(
        bookId: String,
        totalSecondsRead: TimeInterval = 0,
        sessionCount: Int = 0,
        lastRead: Date? = nil,
        lastPositionProgression: Double? = nil,
        totalPages: Int? = nil,
        isCompleted: Bool = false
    ) {
        self.bookId = bookId
        self.totalSecondsRead = totalSecondsRead
        self.sessionCount = sessionCount
        self.lastRead = lastRead
        self.lastPositionProgression = lastPositionProgression
        self.totalPages = totalPages
        self.isCompleted = isCompleted
    }

    public var hoursRead: Double { totalSecondsRead / 3600.0 }

    public var estimatedPagesRead: Int {
        guard let total = totalPages, let progression = lastPositionProgression else { return 0 }
        return Int(Double(total) * progression)
    }
}

public struct ReadingStreak: Codable, Equatable, Sendable {
    public var current: Int
    public var longest: Int
    public var lastActiveDay: Date?

    nonisolated public init(current: Int = 0, longest: Int = 0, lastActiveDay: Date? = nil) {
        self.current = current
        self.longest = longest
        self.lastActiveDay = lastActiveDay
    }
}

public struct ReadingStatsSnapshot: Codable, Equatable, Sendable {
    public var totalSecondsRead: TimeInterval
    public var totalSessions: Int
    public var perBook: [String: BookReadingStat]
    public var dailySecondsRead: [String: TimeInterval]
    public var streak: ReadingStreak
    public var lastUpdated: Date
    public var totalBooksFinished: Int

    nonisolated public static let empty: ReadingStatsSnapshot = ReadingStatsSnapshot(
        totalSecondsRead: 0,
        totalSessions: 0,
        perBook: [:],
        dailySecondsRead: [:],
        streak: ReadingStreak(current: 0, longest: 0, lastActiveDay: nil),
        lastUpdated: Date(),
        totalBooksFinished: 0
    )

    nonisolated public init(
        totalSecondsRead: TimeInterval,
        totalSessions: Int,
        perBook: [String: BookReadingStat],
        dailySecondsRead: [String: TimeInterval],
        streak: ReadingStreak,
        lastUpdated: Date,
        totalBooksFinished: Int
    ) {
        self.totalSecondsRead = totalSecondsRead
        self.totalSessions = totalSessions
        self.perBook = perBook
        self.dailySecondsRead = dailySecondsRead
        self.streak = streak
        self.lastUpdated = lastUpdated
        self.totalBooksFinished = totalBooksFinished
    }

    public var totalHoursRead: Double { totalSecondsRead / 3600.0 }
    public var totalDaysRead: Double { totalSecondsRead / 86400.0 }

    public var totalEstimatedPagesRead: Int {
        perBook.values.reduce(0) { $0 + $1.estimatedPagesRead }
    }

    public func hoursForBook(id: String) -> Double {
        perBook[id]?.hoursRead ?? 0
    }
}
