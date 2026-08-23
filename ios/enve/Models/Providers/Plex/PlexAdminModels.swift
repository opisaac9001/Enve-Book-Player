import Foundation

public struct PlexActiveSession: Identifiable, Codable {
    public let sessionKey: String?
    public let title: String?
    public let type: String?
    public let ratingKey: String?
    public let userTitle: String?
    public let thumb: String?
    public let parentThumb: String?
    public let grandparentTitle: String?
    public let grandparentRatingKey: String?
    public let parentTitle: String?
    public let viewOffset: Int?
    public let duration: Int?
    public let player: PlexPlayer?
    public let user: PlexSessionUser?
    public let transcodeSession: PlexTranscodeSession?

    private enum CodingKeys: String, CodingKey {
        case sessionKey
        case title
        case type
        case ratingKey
        case userTitle
        case thumb
        case parentThumb
        case grandparentTitle
        case grandparentRatingKey
        case parentTitle
        case viewOffset
        case duration
        case player = "Player"
        case user = "User"
        case transcodeSession = "TranscodeSession"
    }

    public var id: String {
        sessionKey ?? ratingKey ?? UUID().uuidString
    }

    public var progressPercent: Double {
        guard let viewOffset = viewOffset, let duration = duration, duration > 0 else { return 0 }
        return Double(viewOffset) / Double(duration) * 100
    }

    public var isTranscoding: Bool {
        return transcodeSession != nil
    }

    public var displayTitle: String {
        if let grandparentTitle = grandparentTitle, !grandparentTitle.isEmpty {
            return "\(grandparentTitle) - \(title ?? "Unknown")"
        }
        return title ?? "Unknown Title"
    }
}

public struct PlexPlayer: Codable {
    public let machineIdentifier: String?
    public let platform: String?
    public let product: String?
    public let title: String?
    public let state: String?
    public let local: Bool?
    public let address: String?

    public var isLocal: Bool { local ?? false }
    public var isPlaying: Bool { state == "playing" }

    private enum CodingKeys: String, CodingKey {
        case machineIdentifier
        case platform
        case product
        case title
        case state
        case local
        case address
        case device
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineIdentifier = try container.decodeIfPresent(String.self, forKey: .machineIdentifier)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        product = try container.decodeIfPresent(String.self, forKey: .product)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        local = try container.decodeIfPresent(Bool.self, forKey: .local)
        address = try container.decodeIfPresent(String.self, forKey: .address)

        if let titleValue = try container.decodeIfPresent(String.self, forKey: .title) {
            title = titleValue
        } else if let deviceValue = try container.decodeIfPresent(String.self, forKey: .device) {
            title = deviceValue
        } else {
            title = try container.decodeIfPresent(String.self, forKey: .name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(machineIdentifier, forKey: .machineIdentifier)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(product, forKey: .product)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(address, forKey: .address)
    }
}

public struct PlexSessionUser: Codable {
    public let id: String?
    public let thumb: String?
    public let title: String?

    public var displayName: String { title ?? "Unknown User" }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID
        case userId
        case thumb
        case title
        case username
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)

        if let idValue = try container.decodeIfPresent(String.self, forKey: .id) {
            id = idValue
        } else if let idValue = try container.decodeIfPresent(String.self, forKey: .userID) {
            id = idValue
        } else {
            id = try container.decodeIfPresent(String.self, forKey: .userId)
        }

        if let titleValue = try container.decodeIfPresent(String.self, forKey: .title) {
            title = titleValue
        } else if let usernameValue = try container.decodeIfPresent(String.self, forKey: .username) {
            title = usernameValue
        } else {
            title = try container.decodeIfPresent(String.self, forKey: .name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(thumb, forKey: .thumb)
        try container.encodeIfPresent(title, forKey: .title)
    }
}

public struct PlexTranscodeSession: Codable {
    public let key: String?
    public let throttled: Bool?
    public let complete: Bool?
    public let progress: Double?
    public let speed: Double?
    public let duration: Int?
    public let remaining: Int?
    public let context: String?
    public let sourceVideoCodec: String?
    public let sourceAudioCodec: String?
    public let videoDecision: String?
    public let audioDecision: String?
    public let subtitleDecision: String?
    public let container: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let audioChannels: Int?
    public let width: Int?
    public let height: Int?

    public var isDirectPlay: Bool {
        return videoDecision == "copy" && audioDecision == "copy"
    }

    public var transcodeDescription: String {
        if isDirectPlay {
            return "Direct Play"
        }
        var parts: [String] = []
        if videoDecision == "transcode" {
            parts.append("Video: \(sourceVideoCodec ?? "?") → \(videoCodec ?? "?")")
        }
        if audioDecision == "transcode" {
            parts.append("Audio: \(sourceAudioCodec ?? "?") → \(audioCodec ?? "?")")
        }
        return parts.isEmpty ? "Transcode" : parts.joined(separator: ", ")
    }
}

public struct PlexServerInfo: Codable {
    public let machineIdentifier: String?
    public let version: String?
    public let platform: String?
    public let platformVersion: String?
    public let updatedAt: Int?
    public let transcoderActiveVideoSessions: Int?

    public var displayVersion: String {
        return version ?? "Unknown"
    }
}

public struct PlexLibrarySection: Identifiable, Codable {
    public let key: String
    public let type: String?
    public let title: String?
    public let agent: String?
    public let scanner: String?
    public let language: String?
    public let uuid: String?
    public let refreshing: Bool?
    public let scannedAt: Int?

    public var id: String { key }

    public var displayName: String { title ?? "Library \(key)" }

    public var isRefreshing: Bool { refreshing ?? false }

    public var lastScannedDate: Date? {
        guard let scannedAt = scannedAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(scannedAt))
    }
}

public struct PlexManagedUser: Identifiable, Codable {
    public let id: String
    public let username: String?
    public let email: String?
    public let thumb: String?
    public let hasPassword: Bool?
    public let restricted: Bool?
    public let home: Bool?
    public let title: String?

    public var displayName: String {
        username ?? title ?? email ?? "Unknown"
    }

    public var isHomeUser: Bool { home ?? false }
    public var isRestricted: Bool { restricted ?? false }
}

public struct PlexSectionsResponse: Codable {
    public let MediaContainer: PlexSectionsContainer?
}

public struct PlexSectionsContainer: Codable {
    public let Directory: [PlexLibrarySection]?
}
