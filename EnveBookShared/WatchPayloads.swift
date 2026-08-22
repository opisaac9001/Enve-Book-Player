import Foundation

nonisolated enum WatchWire {
    static let schemaVersion = 1

    enum Kind: String {

        case requestLibrary
        case requestSearch
        case requestDescriptor
        case requestCover
        case requestNowPlaying
        case requestPosition
        case reportProgress
        case command

        case nowPlaying
    }

    static let kindKey = "k"
    static let versionKey = "v"
    static let dataKey = "d"
    static let errorKey = "e"

    static func envelope<T: Encodable>(_ kind: Kind, _ payload: T) -> [String: Any] {
        var message: [String: Any] = [kindKey: kind.rawValue, versionKey: schemaVersion]
        if let data = try? JSONEncoder().encode(payload) {
            message[dataKey] = data
        }
        return message
    }

    static func kind(of message: [String: Any]) -> Kind? {
        (message[kindKey] as? String).flatMap(Kind.init(rawValue:))
    }

    static func payload<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[dataKey] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func reply<T: Encodable>(_ payload: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(payload) else {
            return [errorKey: "encoding failed"]
        }
        return [dataKey: data]
    }

    static func replyError(_ message: String) -> [String: Any] {
        [errorKey: message]
    }
}

nonisolated struct WatchBookSummary: Codable, Equatable, Identifiable, Sendable {
    let stableId: String
    let title: String
    let author: String
    let duration: TimeInterval
    let position: TimeInterval
    let isFinished: Bool
    let isPodcastEpisode: Bool
    let podcastName: String?

    var id: String { stableId }
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

nonisolated struct WatchLibrarySnapshot: Codable, Equatable, Sendable {
    var continueItems: [WatchBookSummary]
    var recentItems: [WatchBookSummary]
    var podcastItems: [WatchBookSummary]
    var generatedAt: Date

    static let empty = WatchLibrarySnapshot(continueItems: [], recentItems: [], podcastItems: [], generatedAt: .distantPast)
}

nonisolated struct WatchSearchRequest: Codable, Sendable {
    let query: String
}

nonisolated struct WatchSearchResults: Codable, Sendable {
    let items: [WatchBookSummary]
}

nonisolated struct WatchChapterPayload: Codable, Equatable, Sendable {
    let index: Int
    let title: String
    let start: TimeInterval
    let end: TimeInterval
}

nonisolated struct WatchTrackPayload: Codable, Equatable, Sendable {
    let index: Int
    let url: String
    let duration: TimeInterval
    let startOffset: TimeInterval
    let fileExtension: String
}

nonisolated struct WatchPlaybackDescriptor: Codable, Equatable, Sendable {
    let stableId: String
    let title: String
    let author: String
    let duration: TimeInterval
    let startTime: TimeInterval
    let headers: [String: String]
    let tracks: [WatchTrackPayload]
    let chapters: [WatchChapterPayload]
}

nonisolated struct WatchDescriptorRequest: Codable, Sendable {
    let stableId: String
}

nonisolated struct WatchCoverRequest: Codable, Sendable {
    let stableId: String
    let maxPixels: Int
}

nonisolated struct WatchCoverReply: Codable, Sendable {
    let jpeg: Data?
}

nonisolated struct WatchPositionReply: Codable, Sendable {
    let position: TimeInterval
    let updatedAt: Date
}

nonisolated struct WatchProgressReport: Codable, Sendable {
    let stableId: String
    let position: TimeInterval
    let duration: TimeInterval
    let isFinished: Bool
    let timestamp: Date
}

nonisolated struct WatchNowPlayingPayload: Codable, Equatable, Sendable {
    var hasBook: Bool
    var stableId: String
    var title: String
    var author: String
    var chapterTitle: String
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval
    var speed: Double
    var skipForward: Int
    var skipBackward: Int
    var sleepRemaining: TimeInterval?
    var sentAt: Date

    static let empty = WatchNowPlayingPayload(
        hasBook: false,
        stableId: "",
        title: "",
        author: "",
        chapterTitle: "",
        isPlaying: false,
        position: 0,
        duration: 0,
        speed: 1.0,
        skipForward: 30,
        skipBackward: 15,
        sleepRemaining: nil,
        sentAt: .distantPast
    )
}

nonisolated struct WatchCommandPayload: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case play
        case toggle
        case pause
        case skipForward
        case skipBackward
        case speed
        case sleep
    }

    let action: Action
    var value: String = ""
    var seconds: Double = 0
}
