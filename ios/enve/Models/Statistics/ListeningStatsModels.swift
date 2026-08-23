import Foundation

public struct BookListeningStat: Codable, Equatable, Sendable {
    public var bookId: String
    public var totalSeconds: TimeInterval
    public var sessionCount: Int
    public var lastPlayed: Date?
    public var lastPosition: TimeInterval?
    public var duration: TimeInterval?
    public var isCompleted: Bool

    nonisolated public init(
        bookId: String,
        totalSeconds: TimeInterval = 0,
        sessionCount: Int = 0,
        lastPlayed: Date? = nil,
        lastPosition: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        isCompleted: Bool = false
    ) {
        self.bookId = bookId
        self.totalSeconds = totalSeconds
        self.sessionCount = sessionCount
        self.lastPlayed = lastPlayed
        self.lastPosition = lastPosition
        self.duration = duration
        self.isCompleted = isCompleted
    }

    public var hoursListened: Double { totalSeconds / 3600.0 }

    public var progressPercentage: Double {
        guard let duration = duration, duration > 0, let position = lastPosition else { return 0 }
        return min(position / duration, 1.0)
    }
}

public struct ListeningStreak: Codable, Equatable, Sendable {
    public var current: Int
    public var longest: Int
    public var lastActiveDay: Date?

    nonisolated public init(current: Int = 0, longest: Int = 0, lastActiveDay: Date? = nil) {
        self.current = current
        self.longest = longest
        self.lastActiveDay = lastActiveDay
    }
}

public struct ListeningStatsSnapshot: Codable, Equatable, Sendable {
    public var totalSeconds: TimeInterval
    public var totalSessions: Int
    public var perBook: [String: BookListeningStat]
    public var dailySeconds: [String: TimeInterval]
    public var streak: ListeningStreak
    public var lastUpdated: Date
    public var totalBooksFinished: Int
    public var manuallyAddedSeconds: TimeInterval
    public var manuallyAddedBooksFinished: Int
    public var readingStats: [String: ReadingSpeedRecord]

    nonisolated public static let empty: ListeningStatsSnapshot = ListeningStatsSnapshot(
        totalSeconds: 0,
        totalSessions: 0,
        perBook: [:],
        dailySeconds: [:],
        streak: ListeningStreak(current: 0, longest: 0, lastActiveDay: nil),
        lastUpdated: Date(),
        totalBooksFinished: 0,
        manuallyAddedSeconds: 0,
        manuallyAddedBooksFinished: 0,
        readingStats: [:]
    )

    nonisolated public init(
        totalSeconds: TimeInterval,
        totalSessions: Int,
        perBook: [String: BookListeningStat],
        dailySeconds: [String: TimeInterval],
        streak: ListeningStreak,
        lastUpdated: Date,
        totalBooksFinished: Int,
        manuallyAddedSeconds: TimeInterval = 0,
        manuallyAddedBooksFinished: Int = 0,
        readingStats: [String: ReadingSpeedRecord] = [:]
    ) {
        self.totalSeconds = totalSeconds
        self.totalSessions = totalSessions
        self.perBook = perBook
        self.dailySeconds = dailySeconds
        self.streak = streak
        self.lastUpdated = lastUpdated
        self.totalBooksFinished = totalBooksFinished
        self.manuallyAddedSeconds = manuallyAddedSeconds
        self.manuallyAddedBooksFinished = manuallyAddedBooksFinished
        self.readingStats = readingStats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSeconds = try container.decode(TimeInterval.self, forKey: .totalSeconds)
        totalSessions = try container.decode(Int.self, forKey: .totalSessions)
        perBook = try container.decode([String: BookListeningStat].self, forKey: .perBook)
        dailySeconds = try container.decode([String: TimeInterval].self, forKey: .dailySeconds)
        streak = try container.decode(ListeningStreak.self, forKey: .streak)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        totalBooksFinished = try container.decode(Int.self, forKey: .totalBooksFinished)
        manuallyAddedSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .manuallyAddedSeconds) ?? 0
        manuallyAddedBooksFinished = try container.decodeIfPresent(Int.self, forKey: .manuallyAddedBooksFinished) ?? 0
        readingStats = try container.decodeIfPresent([String: ReadingSpeedRecord].self, forKey: .readingStats) ?? [:]
    }

    public var totalHours: Double { totalSeconds / 3600.0 }

    public var totalReadingSeconds: TimeInterval {
        readingStats.values.reduce(0) { $0 + $1.totalReadingSeconds }
    }

    public var averageReadingProgressPerMinute: Double? {
        let records = readingStats.values.filter { $0.totalReadingSeconds > 60 }
        guard !records.isEmpty else { return nil }
        let totalPPM = records.reduce(0.0) { $0 + $1.averageProgressPerMinute }
        return totalPPM / Double(records.count)
    }
    public var totalDays: Double { totalSeconds / 86400.0 }
    public var totalMonths: Double { totalSeconds / (86400.0 * 30) }

    public func hoursForBook(id: String) -> Double {
        perBook[id]?.hoursListened ?? 0
    }
}

public struct ReadingSpeedRecord: Codable, Equatable, Sendable {
    public var bookId: String
    public var averageProgressPerMinute: Double
    public var totalReadingSeconds: TimeInterval
    public var lastUpdated: Date

    nonisolated public init(
        bookId: String,
        averageProgressPerMinute: Double = 0,
        totalReadingSeconds: TimeInterval = 0,
        lastUpdated: Date = Date()
    ) {
        self.bookId = bookId
        self.averageProgressPerMinute = averageProgressPerMinute
        self.totalReadingSeconds = totalReadingSeconds
        self.lastUpdated = lastUpdated
    }
}

public enum ListeningSourceType: String, Codable, Sendable, CaseIterable {
    case audiobookshelf
    case plex
    case jellyfin
    case emby
    case manual
}

public enum ServerConnectionStatus: String, Codable, Sendable {
    case connected
    case disconnected
    case authenticating
    case error
}

public struct ServerBookProgress: Codable, Equatable, Sendable {
    public let serverItemId: String
    public let currentPosition: TimeInterval
    public let duration: TimeInterval
    public let progress: Double
    public let isFinished: Bool
    public let lastPlayedAt: Date?
    public let serverType: ListeningSourceType
    public let backendId: String?

    public init(
        serverItemId: String,
        currentPosition: TimeInterval,
        duration: TimeInterval,
        progress: Double,
        isFinished: Bool,
        lastPlayedAt: Date?,
        serverType: ListeningSourceType,
        backendId: String?
    ) {
        self.serverItemId = serverItemId
        self.currentPosition = currentPosition
        self.duration = duration
        self.progress = progress
        self.isFinished = isFinished
        self.lastPlayedAt = lastPlayedAt
        self.serverType = serverType
        self.backendId = backendId
    }

    public static func fromAudiobookshelf(
        itemId: String,
        currentTime: Double,
        duration: Double,
        progress: Double,
        isFinished: Bool,
        lastUpdate: TimeInterval?,
        backendId: String?
    ) -> ServerBookProgress {
        let lastPlayed = lastUpdate.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return ServerBookProgress(
            serverItemId: itemId,
            currentPosition: currentTime,
            duration: duration,
            progress: progress,
            isFinished: isFinished,
            lastPlayedAt: lastPlayed,
            serverType: .audiobookshelf,
            backendId: backendId
        )
    }

    public static func fromPlex(
        ratingKey: String,
        viewOffsetMs: Int,
        durationMs: Int,
        lastViewedAt: TimeInterval?,
        backendId: String?
    ) -> ServerBookProgress {
        let currentPosition = TimeInterval(viewOffsetMs) / 1000.0
        let duration = TimeInterval(durationMs) / 1000.0
        let progress = duration > 0 ? currentPosition / duration : 0
        let lastPlayed = lastViewedAt.map { Date(timeIntervalSince1970: $0) }
        return ServerBookProgress(
            serverItemId: ratingKey,
            currentPosition: currentPosition,
            duration: duration,
            progress: progress,
            isFinished: progress >= 0.99,
            lastPlayedAt: lastPlayed,
            serverType: .plex,
            backendId: backendId
        )
    }

    public static func fromJellyfinEmby(
        itemId: String,
        positionTicks: Int64,
        durationTicks: Int64,
        played: Bool,
        lastPlayedDate: Date?,
        serverType: ListeningSourceType,
        backendId: String?
    ) -> ServerBookProgress {
        let currentPosition = TimeInterval(positionTicks) / 10_000_000.0
        let duration = TimeInterval(durationTicks) / 10_000_000.0
        let progress = duration > 0 ? currentPosition / duration : 0
        return ServerBookProgress(
            serverItemId: itemId,
            currentPosition: currentPosition,
            duration: duration,
            progress: progress,
            isFinished: played || progress >= 0.99,
            lastPlayedAt: lastPlayedDate,
            serverType: serverType,
            backendId: backendId
        )
    }
}

public struct AudiobookshelfListeningStats: Codable, Sendable {
    public let totalTime: TimeInterval
    public let items: [String: AudiobookshelfItemStats]
    public let days: [String: TimeInterval]?
    public let dayOfWeek: [String: TimeInterval]?
    public let today: TimeInterval?
    public let recentSessions: [AudiobookshelfSession]?

    public struct AudiobookshelfItemStats: Codable, Sendable {
        public let id: String
        public let timeListening: TimeInterval
        public let mediaMetadata: AudiobookshelfMediaMetadata?
    }

    public struct AudiobookshelfMediaMetadata: Codable, Sendable {
        public let title: String?
        public let authorName: String?
    }

    public struct AudiobookshelfSession: Codable, Sendable {
        public let id: String
        public let timeListening: TimeInterval
        public let currentTime: TimeInterval?
        public let startedAt: TimeInterval?
        public let updatedAt: TimeInterval?
    }
}

public struct ServerSyncState: Codable, Equatable, Sendable {
    public var lastSyncTime: Date?
    public var lastSyncStatus: ServerConnectionStatus
    public var lastError: String?
    public var itemsSynced: Int

    public init(
        lastSyncTime: Date? = nil,
        lastSyncStatus: ServerConnectionStatus = .disconnected,
        lastError: String? = nil,
        itemsSynced: Int = 0
    ) {
        self.lastSyncTime = lastSyncTime
        self.lastSyncStatus = lastSyncStatus
        self.lastError = lastError
        self.itemsSynced = itemsSynced
    }
}
