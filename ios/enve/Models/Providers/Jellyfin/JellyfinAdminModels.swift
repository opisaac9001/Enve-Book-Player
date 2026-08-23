import Foundation

public struct JellyfinSystemInfo: Codable {
    public let ServerName: String?
    public let Version: String?
    public let OperatingSystem: String?
    public let Id: String?
    public let LocalAddress: String?
    public let WanAddress: String?
    public let HasPendingRestart: Bool?
    public let HasUpdateAvailable: Bool?
    public let CanSelfRestart: Bool?
    public let CanLaunchWebBrowser: Bool?

    public var displayName: String { ServerName ?? "Jellyfin Server" }
    public var displayVersion: String { Version ?? "Unknown" }
    public var needsRestart: Bool { HasPendingRestart ?? false }
    public var hasUpdate: Bool { HasUpdateAvailable ?? false }
}

public struct JellyfinAdminUser: Identifiable, Codable {
    public let Id: String
    public let Name: String?
    public let ServerId: String?
    public let HasPassword: Bool?
    public let HasConfiguredPassword: Bool?
    public let HasConfiguredEasyPassword: Bool?
    public let LastLoginDate: String?
    public let LastActivityDate: String?
    public let Policy: JellyfinUserPolicy?

    public var id: String { Id }
    public var displayName: String { Name ?? "Unknown User" }
    public var isAdmin: Bool { Policy?.IsAdministrator ?? false }
    public var isDisabled: Bool { Policy?.IsDisabled ?? false }

    public var lastActivityDate: Date? {
        guard let dateStr = LastActivityDate else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
    }
}

public struct JellyfinUserPolicy: Codable {
    public let IsAdministrator: Bool?
    public let IsDisabled: Bool?
    public let IsHidden: Bool?
    public let EnableRemoteAccess: Bool?
    public let EnableMediaPlayback: Bool?
    public let EnableAudioPlaybackTranscoding: Bool?
    public let EnableVideoPlaybackTranscoding: Bool?
    public let EnableContentDeletion: Bool?
    public let EnableContentDownloading: Bool?
    public let EnableSyncTranscoding: Bool?
    public let EnableCollectionManagement: Bool?
    public let MaxStreamingBitrate: Int?
    public let RemoteClientBitrateLimit: Int?
    public let LoginAttemptsBeforeLockout: Int?
}

public struct JellyfinUserCreateRequest: Codable {
    public let Name: String
    public let Password: String?

    public init(name: String, password: String? = nil) {
        self.Name = name
        self.Password = password
    }
}

public struct JellyfinPolicyUpdateRequest: Codable {
    public let IsAdministrator: Bool?
    public let IsDisabled: Bool?
    public let EnableRemoteAccess: Bool?
    public let EnableMediaPlayback: Bool?
    public let EnableContentDeletion: Bool?
    public let EnableContentDownloading: Bool?

    public init(
        isAdministrator: Bool? = nil,
        isDisabled: Bool? = nil,
        enableRemoteAccess: Bool? = nil,
        enableMediaPlayback: Bool? = nil,
        enableContentDeletion: Bool? = nil,
        enableContentDownloading: Bool? = nil
    ) {
        self.IsAdministrator = isAdministrator
        self.IsDisabled = isDisabled
        self.EnableRemoteAccess = enableRemoteAccess
        self.EnableMediaPlayback = enableMediaPlayback
        self.EnableContentDeletion = enableContentDeletion
        self.EnableContentDownloading = enableContentDownloading
    }
}

public struct JellyfinPlugin: Identifiable, Codable {
    public let Name: String?
    public let Version: String?
    public let Id: String?
    public let Description: String?
    public let Status: String?
    public let HasImage: Bool?
    public let CanUninstall: Bool?

    public var id: String { Id ?? UUID().uuidString }
    public var displayName: String { Name ?? "Unknown Plugin" }
    public var displayVersion: String { Version ?? "Unknown" }
    public var isActive: Bool { Status == "Active" }
}

public struct JellyfinScheduledTask: Identifiable, Codable {
    public let Name: String?
    public let State: String?
    public let CurrentProgressPercentage: Double?
    public let Id: String?
    public let Description: String?
    public let Category: String?
    public let IsHidden: Bool?
    public let Key: String?
    public let LastExecutionResult: JellyfinTaskResult?

    public var id: String { Id ?? Key ?? UUID().uuidString }
    public var displayName: String { Name ?? "Unknown Task" }
    public var isRunning: Bool { State == "Running" }
    public var isIdle: Bool { State == "Idle" }
    public var progress: Double { CurrentProgressPercentage ?? 0 }
}

public struct JellyfinTaskResult: Codable {
    public let StartTimeUtc: String?
    public let EndTimeUtc: String?
    public let Status: String?
    public let Name: String?
    public let Key: String?
    public let ErrorMessage: String?
    public let LongErrorMessage: String?

    public var wasSuccessful: Bool { Status == "Completed" }
}

public struct JellyfinActiveSession: Identifiable, Codable {
    public let Id: String?
    public let UserId: String?
    public let UserName: String?
    public let Client: String?
    public let DeviceName: String?
    public let DeviceId: String?
    public let ApplicationVersion: String?
    public let IsActive: Bool?
    public let SupportsRemoteControl: Bool?
    public let NowPlayingItem: JellyfinNowPlayingItem?
    public let PlayState: JellyfinPlayState?
    public let LastActivityDate: String?
    public let RemoteEndPoint: String?

    public var id: String { Id ?? DeviceId ?? UUID().uuidString }
    public var displayName: String { UserName ?? "Unknown User" }
    public var deviceInfo: String { "\(Client ?? "Unknown") on \(DeviceName ?? "Unknown Device")" }
    public var isPlaying: Bool { NowPlayingItem != nil && !(PlayState?.IsPaused ?? true) }
}

public struct JellyfinNowPlayingItem: Codable {
    public let Name: String?
    public let Id: String?
    public let ItemType: String?
    public let SeriesName: String?
    public let AlbumArtist: String?
    public let Album: String?
    public let RunTimeTicks: Int64?

    private enum CodingKeys: String, CodingKey {
        case Name, Id
        case ItemType = "Type"
        case SeriesName, AlbumArtist, Album, RunTimeTicks
    }

    public var displayTitle: String {
        if let seriesName = SeriesName, !seriesName.isEmpty {
            return "\(seriesName) - \(Name ?? "Unknown")"
        }
        return Name ?? "Unknown"
    }

    public var durationSeconds: Double {
        guard let ticks = RunTimeTicks else { return 0 }
        return Double(ticks) / 10_000_000.0
    }
}

public struct JellyfinPlayState: Codable {
    public let PositionTicks: Int64?
    public let CanSeek: Bool?
    public let IsPaused: Bool?
    public let IsMuted: Bool?
    public let VolumeLevel: Int?
    public let AudioStreamIndex: Int?
    public let SubtitleStreamIndex: Int?
    public let PlayMethod: String?

    public var positionSeconds: Double {
        guard let ticks = PositionTicks else { return 0 }
        return Double(ticks) / 10_000_000.0
    }

    public var isDirectPlay: Bool { PlayMethod == "DirectPlay" }
    public var isTranscoding: Bool { PlayMethod == "Transcode" }
}
