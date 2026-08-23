import Foundation

public struct ABSLoginRequest: Codable {
    public let username: String
    public let password: String
}

public struct ABSLoginResponse: Codable {
    public let user: ABSUser
    public let token: String?

    public enum CodingKeys: String, CodingKey {
        case user
        case token
    }
}

public struct ABSUser: Codable, Identifiable {
    public let id: String
    public let username: String
    public let type: String
    public let token: String?
    public let accessToken: String?
    public let refreshToken: String?
    public let isActive: Bool?
    public let isLocked: Bool?
    public let permissions: ABSPermissions?
    public let librariesAccessible: [String]?
    public let mediaProgress: [ABSMediaProgress]?
    public let bookmarks: [ABSBookmark]?

    public enum CodingKeys: String, CodingKey {
        case id, username, type, token, accessToken, refreshToken
        case isActive, isLocked
        case permissions
        case librariesAccessible
        case mediaProgress
        case bookmarks
    }
}

public struct ABSPermissions: Codable {
    public let download: Bool?
    public let update: Bool?
    public let delete: Bool?
    public let upload: Bool?
    public let accessAllLibraries: Bool?
    public let accessAllTags: Bool?
    public let accessExplicitContent: Bool?
}

public struct ABSLibrary: Codable, Identifiable {
    public let id: String
    public let name: String
    public let folders: [ABSFolder]?
    public let displayOrder: Int?
    public let icon: String?
    public let mediaType: String?
    public let provider: String?
    public let settings: ABSLibrarySettings?
    public let createdAt: Double?
    public let lastUpdate: Double?

    public var isAudiobookLibrary: Bool {
        return mediaType == "book"
    }
}

public struct ABSFolder: Codable {
    public let id: String
    public let fullPath: String
    public let libraryId: String?

    public enum CodingKeys: String, CodingKey {
        case id, fullPath, libraryId
    }
}

public struct ABSLibrarySettings: Codable {
    public let coverAspectRatio: Int?
    public let disableWatcher: Bool?
    public let skipMatchingMediaWithAsin: Bool?
    public let skipMatchingMediaWithIsbn: Bool?
    public let autoScanCronExpression: String?
}

public struct ABSLibraryItem: Codable, Identifiable {
    public let id: String
    public let ino: String?
    public let libraryId: String
    public let folderId: String?
    public let path: String?
    public let relPath: String?
    public let isFile: Bool?
    public let mtimeMs: Double?
    public let ctimeMs: Double?
    public let birthtimeMs: Double?
    public let addedAt: Double?
    public let updatedAt: Double?
    public let lastScan: Double?
    public let scanVersion: String?
    public let isMissing: Bool?
    public let isInvalid: Bool?
    public let mediaType: String?
    public let media: ABSBookMedia?
    public let libraryFiles: [ABSLibraryFile]?
    public let numFiles: Int?
    public let size: Int?

    var addedAtDate: Date? {
        guard let addedAt = addedAt else { return nil }
        return Date(timeIntervalSince1970: addedAt / 1000)
    }

    var updatedAtDate: Date? {
        guard let updatedAt = updatedAt else { return nil }
        return Date(timeIntervalSince1970: updatedAt / 1000)
    }

    var resolvedTitle: String {
        let seriesName = media?.metadata?.series?.first.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        if let rp = relPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rp.isEmpty {
            let component = (rp as NSString).lastPathComponent
            let withoutExt = (component as NSString).deletingPathExtension
            if !withoutExt.isEmpty {
                return withoutExt
            }
        }

        if let p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            let component = (p as NSString).lastPathComponent
            let withoutExt = (component as NSString).deletingPathExtension
            if !withoutExt.isEmpty {
                return withoutExt
            }
        }

        if isFile == true {
            if let rp = relPath, !rp.isEmpty {
                let component = (rp as NSString).lastPathComponent
                let withoutExt = (component as NSString).deletingPathExtension
                if !withoutExt.isEmpty { return withoutExt }
            }
            if let p = path, !p.isEmpty {
                let component = (p as NSString).lastPathComponent
                let withoutExt = (component as NSString).deletingPathExtension
                if !withoutExt.isEmpty { return withoutExt }
            }
        }

        if let filename = libraryFiles?.first?.metadata?.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
            !filename.isEmpty
        {
            let withoutExt = (filename as NSString).deletingPathExtension
            if !withoutExt.isEmpty { return withoutExt }
        }

        if let fileRelPath = libraryFiles?.first?.metadata?.relPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !fileRelPath.isEmpty
        {
            let fileComponent = (fileRelPath as NSString).lastPathComponent
            let withoutExt = (fileComponent as NSString).deletingPathExtension
            if !withoutExt.isEmpty { return withoutExt }
        }

        if let audioFiles = media?.audioFiles, !audioFiles.isEmpty {
            if let albumTag = audioFiles.first?.metaTags?.tagAlbum?.trimmingCharacters(in: .whitespacesAndNewlines),
                !albumTag.isEmpty, albumTag.caseInsensitiveCompare(seriesName) != .orderedSame
            {
                return albumTag
            }

            if let titleTag = audioFiles.first?.metaTags?.tagTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                !titleTag.isEmpty, titleTag.caseInsensitiveCompare(seriesName) != .orderedSame
            {
                return titleTag
            }

            if let filename = audioFiles.first?.metadata?.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
                !filename.isEmpty
            {
                let withoutExt = (filename as NSString).deletingPathExtension
                if !withoutExt.isEmpty {
                    return withoutExt
                }
            }
        }

        let mdTitle = media?.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = mdTitle, !title.isEmpty {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedSeries = seriesName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let titleLooksLikeSeries: Bool =
                !normalizedSeries.isEmpty
                && (normalizedTitle == normalizedSeries || normalizedTitle.hasPrefix(normalizedSeries)
                    || normalizedTitle.contains(normalizedSeries))

            if !titleLooksLikeSeries {
                return title
            }
        }

        if let filename = libraryFiles?.first?.metadata?.filename, !filename.isEmpty {
            let withoutExt = (filename as NSString).deletingPathExtension
            if !withoutExt.isEmpty { return withoutExt }
        }

        return "Unknown"
    }
}

public struct ABSBookMedia: Codable {
    public let libraryItemId: String?
    public let metadata: ABSBookMetadata?
    public let coverPath: String?
    public let tags: [String]?
    public let audioFiles: [ABSAudioFile]?
    public let chapters: [ABSChapter]?
    public let duration: Double?
    public let size: Int?
    public let tracks: [ABSAudioTrack]?
    public let ebookFile: ABSEbookFile?
}

public struct ABSBookMetadata: Codable {
    public let title: String?
    public let subtitle: String?
    public let authors: [ABSAuthor]?
    public let narrators: [String]?
    public let series: [ABSSeries]?
    public let genres: [String]?
    public let publishedYear: String?
    public let publishedDate: String?
    public let publisher: String?
    public let description: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let explicit: Bool?
    public let abridged: Bool?

    var authorName: String? {
        guard let authors = authors, !authors.isEmpty else { return nil }
        let joined = authors.map { $0.name }.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    var narratorName: String? {
        guard let narrators = narrators, !narrators.isEmpty else { return nil }
        let joined = narrators.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    var seriesName: String? {
        guard let firstSeries = series?.first else { return nil }
        return firstSeries.name
    }

    var seriesSequence: String? {
        guard let sequence = series?.first?.sequence?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sequence.isEmpty
        else { return nil }
        return sequence
    }

    var seriesNumber: Int? {
        seriesSequence.flatMap(Int.init)
    }
}

public struct ABSAuthor: Codable, Identifiable {
    public let id: String
    public let name: String
    public let asin: String?
    public let description: String?
    public let imagePath: String?
    public let addedAt: Double?
    public let updatedAt: Double?
    public let numBooks: Int?

    public enum CodingKeys: String, CodingKey {
        case id, name, asin, description, imagePath, addedAt, updatedAt, numBooks
    }
}

public struct ABSSeries: Codable, Identifiable {
    public let id: String
    public let name: String
    public let sequence: String?
    public let description: String?
    public let addedAt: Double?
    public let updatedAt: Double?
    public let numBooks: Int?

    public enum CodingKeys: String, CodingKey {
        case id, name, sequence, description, addedAt, updatedAt, numBooks
    }
}

public struct ABSAudioFile: Codable {
    public let index: Int?
    public let ino: String?
    public let metadata: ABSFileMetadata?
    public let addedAt: Double?
    public let updatedAt: Double?
    public let trackNumFromMeta: Int?
    public let discNumFromMeta: Int?
    public let trackNumFromFilename: Int?
    public let discNumFromFilename: Int?
    public let manuallyVerified: Bool?
    public let invalid: Bool?
    public let exclude: Bool?
    public let error: String?
    public let format: String?
    public let duration: Double?
    public let bitRate: Int?
    public let language: String?
    public let codec: String?
    public let timeBase: String?
    public let channels: Int?
    public let channelLayout: String?
    public let chapters: [ABSChapter]?
    public let embeddedCoverArt: String?
    public let metaTags: ABSMetaTags?
    public let mimeType: String?
}

public struct ABSFileMetadata: Codable {
    public let filename: String?
    public let ext: String?
    public let path: String?
    public let relPath: String?
    public let size: Int?
    public let mtimeMs: Double?
    public let ctimeMs: Double?
    public let birthtimeMs: Double?
}

public struct ABSAudioTrack: Codable {
    public let index: Int?
    public let startOffset: Double?
    public let duration: Double?
    public let title: String?
    public let contentUrl: String?
    public let mimeType: String?
    public let metadata: ABSFileMetadata?
    public let isLocal: Bool?
    public let localFileSize: Int?
    public let audioProbeResult: ABSAudioProbeResult?
}

public struct ABSAudioProbeResult: Codable {
    public let codec: String?
    public let codecLong: String?
    public let bitRate: Int?
    public let duration: Double?
    public let channels: Int?
    public let channelLayout: String?
    public let sampleRate: Int?
}

public struct ABSMetaTags: Codable {
    public let tagAlbum: String?
    public let tagArtist: String?
    public let tagGenre: String?
    public let tagTitle: String?
    public let tagTrack: String?
    public let tagDisc: String?
    public let tagComment: String?
    public let tagDate: String?
    public let tagComposer: String?
    public let tagDescription: String?
    public let tagEncoder: String?
    public let tagLanguage: String?
    public let tagSubtitle: String?
}

public struct ABSChapter: Codable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String

    public var duration: Double {
        return end - start
    }
}

public struct ABSLibraryFile: Codable {
    public let ino: String?
    public let metadata: ABSFileMetadata?
    public let addedAt: Double?
    public let updatedAt: Double?
    public let fileType: String?
}

public struct ABSEbookFile: Codable {
    public let ino: String?
    public let metadata: ABSFileMetadata?
    public let ebookFormat: String?
    public let addedAt: Double?
    public let updatedAt: Double?
}

public struct ABSCollection: Codable, Identifiable {
    public let id: String
    public let libraryId: String
    public let userId: String?
    public let name: String
    public let description: String?
    public let books: [ABSLibraryItem]?
    public let lastUpdate: Double?
    public let createdAt: Double?

    public var bookCount: Int {
        return books?.count ?? 0
    }

    public var createdAtDate: Date? {
        guard let createdAt = createdAt else { return nil }
        return Date(timeIntervalSince1970: createdAt / 1000)
    }

    public var customCoverPath: String? {
        get {
            UserDefaults.standard.string(forKey: "custom_cover_abs_\(id)")
        }
    }

    public func setCustomCoverPath(_ path: String?) {
        if let path = path {
            UserDefaults.standard.set(path, forKey: "custom_cover_abs_\(id)")
        } else {
            UserDefaults.standard.removeObject(forKey: "custom_cover_abs_\(id)")
        }
    }
}

public struct ABSCollectionRequest: Codable {
    public let libraryId: String
    public let name: String
    public let description: String?
    public let books: [String]?

    public init(libraryId: String, name: String, description: String? = nil, books: [String]? = nil) {
        self.libraryId = libraryId
        self.name = name
        self.description = description
        self.books = books
    }
}

public struct ABSMediaProgress: Codable {
    public let id: String?
    public let libraryItemId: String?
    public let episodeId: String?
    public let duration: Double?
    public let progress: Double?
    public let currentTime: Double?
    public let isFinished: Bool?
    public let hideFromContinueListening: Bool?
    public let ebookProgress: Double?
    public let lastUpdate: Double?
    public let startedAt: Double?
    public let finishedAt: Double?

    public var lastUpdateDate: Date? {
        guard let lastUpdate = lastUpdate else { return nil }
        return Date(timeIntervalSince1970: lastUpdate / 1000)
    }

    public var progressPercentage: Double {
        return (progress ?? 0) * 100
    }
}

public struct ABSPlaySessionRequest: Codable {
    public let deviceInfo: ABSDeviceInfo?
    public let forceDirectPlay: Bool?
    public let forceTranscode: Bool?
    public let supportedMimeTypes: [String]?
    public let mediaPlayer: String?
}

public struct ABSDeviceInfo: Codable {
    public let clientVersion: String?
    public let manufacturer: String?
    public let model: String?

    public let sdkVersion: String?
    public let clientName: String?
    public let deviceId: String?
    public let deviceName: String?

    public init(
        clientVersion: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        sdkVersion: String? = nil,
        clientName: String? = nil,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        self.clientVersion = clientVersion
        self.manufacturer = manufacturer
        self.model = model
        self.sdkVersion = sdkVersion
        self.clientName = clientName
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        if let intValue = try? c.decode(Int.self, forKey: .sdkVersion) {
            sdkVersion = String(intValue)
        } else {
            sdkVersion = try c.decodeIfPresent(String.self, forKey: .sdkVersion)
        }
    }
}

public struct ABSPlaySession: Codable {
    public let id: String?
    public let userId: String?
    public let libraryId: String?
    public let libraryItemId: String?
    public let episodeId: String?
    public let mediaType: String?
    public let mediaMetadata: ABSBookMetadata?
    public let chapters: [ABSChapter]?
    public let displayTitle: String?
    public let displayAuthor: String?
    public let coverPath: String?
    public let duration: Double?
    public let playMethod: Int?
    public let mediaPlayer: String?
    public let deviceInfo: ABSDeviceInfo?
    public let serverVersion: String?
    public let date: String?
    public let dayOfWeek: String?
    public let timeListening: Double?
    public let startTime: Double?
    public let currentTime: Double?
    public let startedAt: Double?
    public let updatedAt: Double?
    public let audioTracks: [ABSAudioTrack]?
    public let videoTrack: String?
    public let libraryItem: ABSLibraryItem?
}

public struct ABSProgressUpdateRequest: Codable {
    public let currentTime: Double
    public let duration: Double?
    public let progress: Double?
    public let isFinished: Bool?

    public init(currentTime: Double, duration: Double? = nil, progress: Double? = nil, isFinished: Bool? = nil) {
        self.currentTime = currentTime
        self.duration = duration
        self.progress = progress
        self.isFinished = isFinished
    }
}

public struct ABSFilesystemItem: Codable, Identifiable {
    public let path: String?
    public let name: String?
    public let dirpath: String?
    public let fullPath: String?
    public let level: Int?
    public let dirs: [ABSFilesystemItem]?

    public var id: String {
        fullPath ?? path ?? name ?? UUID().uuidString
    }

    public var displayName: String {
        name ?? fullPath?.split(separator: "/").last.map(String.init) ?? path ?? "Unknown"
    }

    public var bestPath: String? {
        fullPath ?? path
    }
}

public struct ABSBookmark: Codable, Identifiable {
    public let id: String?
    public let libraryItemId: String
    public let title: String
    public let time: Double
    public let createdAt: Double?

    public var createdAtDate: Date? {
        guard let createdAt = createdAt else { return nil }
        return Date(timeIntervalSince1970: createdAt / 1000)
    }
}

public struct ABSBookmarkRequest: Codable {
    public let time: Double
    public let title: String

    public init(time: Double, title: String) {
        self.time = time
        self.title = title
    }
}

public struct ABSSearchResults: Codable {
    public let book: [ABSSearchBookResult]?
    public let podcast: [ABSSearchPodcastResult]?
    public let narrators: [ABSSearchNarratorResult]?
    public let authors: [ABSSearchAuthorResult]?
    public let series: [ABSSearchSeriesResult]?
    public let tags: [ABSSearchTagResult]?
}

public struct ABSSearchBookResult: Codable {
    public let libraryItem: ABSLibraryItem
    public let matchKey: String?
    public let matchText: String?
}

public struct ABSSearchPodcastResult: Codable {
    public let libraryItem: ABSLibraryItem
    public let matchKey: String?
    public let matchText: String?
}

public struct ABSSearchNarratorResult: Codable {
    public let name: String
    public let books: [ABSLibraryItem]?
}

public struct ABSSearchAuthorResult: Codable {
    public let author: ABSAuthor
    public let books: [ABSLibraryItem]?
}

public struct ABSSearchSeriesResult: Codable {
    public let series: ABSSeries
    public let books: [ABSLibraryItem]?
}

public struct ABSSearchTagResult: Codable {
    public let name: String
    public let books: [ABSLibraryItem]?
}

public struct ABSMetadataUpdateRequest: Codable {
    public let metadata: ABSMetadataPayload
}

public struct ABSMetadataPayload: Codable {
    public let title: String?
    public let subtitle: String?
    public let authors: [ABSAuthorPayload]?
    public let narrators: [String]?
    public let series: [ABSSeriesPayload]?
    public let genres: [String]?
    public let publishedYear: String?
    public let publishedDate: String?
    public let publisher: String?
    public let description: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let explicit: Bool?
    public let abridged: Bool?
}

public struct ABSAuthorPayload: Codable {
    public let id: String?
    public let name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ABSSeriesPayload: Codable {
    public let id: String?
    public let name: String
    public let sequence: String?

    public init(id: String? = nil, name: String, sequence: String? = nil) {
        self.id = id
        self.name = name
        self.sequence = sequence
    }
}

public struct ABSServerInfo: Codable {
    public let serverVersion: String?
    public let authMethods: [String]?
    public let authFormData: ABSAuthFormData?
    public let isInit: Bool?
}

public struct ABSAuthFormData: Codable {
    public let authOpenIDIsConfigured: Bool?
    public let authOpenIDButtonText: String?
    public let authOpenIDAutoLaunch: Bool?
}

public struct ABSBatchUpdateRequest: Codable {
    public let libraryItemIds: [String]
    public let updates: ABSMetadataPayload
}

public struct ABSLibrariesResponse: Codable {
    public let libraries: [ABSLibrary]
}

public struct ABSLibraryItemsResponse: Codable {
    public let results: [ABSLibraryItem]
    public let total: Int?
    public let limit: Int?
    public let page: Int?
    public let sortBy: String?
    public let sortDesc: Bool?
    public let filterBy: String?
    public let minified: Bool?
    public let collapseseries: Bool?
    public let include: String?
}

public struct ABSCollectionsResponse: Codable {
    public let collections: [ABSCollection]?
}

public struct ABSOnlineUser: Codable, Identifiable {
    public var id: String { odId ?? odUserId ?? UUID().uuidString }
    public let odId: String?
    public let odUserId: String?
    public let odUsername: String?
    public let odSessions: [ABSPlaySession]?

    private enum CodingKeys: String, CodingKey {
        case odId = "id"
        case odUserId = "userId"
        case odUsername = "username"
        case odSessions = "sessions"
    }

    public var username: String? { odUsername }
    public var sessions: [ABSPlaySession]? { odSessions }
}

public struct ABSUserUpdateRequest: Codable {
    public let username: String?
    public let type: String?
    public let permissions: ABSPermissions?
    public let librariesAccessible: [String]?
}

public struct ABSUserCreateRequest: Codable {
    public let username: String
    public let password: String
    public let type: String
    public let permissions: ABSPermissions?
}

public struct ABSStats: Codable {
    public let totalTime: Double?
    public let items: [String: ABSItemStats]?
    public let days: [String: Double]?
    public let dayOfWeek: [String: Double]?
    public let today: Double?
    public let recentSessions: [ABSPlaySession]?

    public var totalHours: Double {
        return (totalTime ?? 0) / 3600
    }

    public var dailyStatsArray: [ABSDailyStatEntry] {
        guard let days = days else { return [] }
        return days.map { ABSDailyStatEntry(date: $0.key, seconds: $0.value) }
            .sorted { $0.date < $1.date }
    }
}

public struct ABSDailyStatEntry: Identifiable {
    public let id = UUID()
    public let date: String
    public let seconds: Double

    public var dateObject: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    public var hours: Double {
        return seconds / 3600
    }

    public var minutes: Double {
        return seconds / 60
    }
}

public struct ABSItemStats: Codable {
    public let id: String?
    public let mediaMetadata: ABSBookMetadata?
    public let timeListening: Double?
    public let lastUpdate: Double?
}

public struct ABSBackup: Codable, Identifiable {
    public var id: String { filename ?? UUID().uuidString }
    public let path: String?
    public let filename: String?
    public let size: Int?
    public let createdAt: Double?

    public var createdAtDate: Date? {
        guard let createdAt = createdAt else { return nil }
        return Date(timeIntervalSince1970: createdAt / 1000)
    }
}

public struct ABSServerSettings: Codable {
    public var id: String?
    public var scannerFindCovers: Bool?
    public var scannerCoverProvider: String?
    public var scannerParseSubtitle: Bool?
    public var scannerPreferMatchedMetadata: Bool?
    public var scannerDisableWatcher: Bool?
    public var storeCoverWithItem: Bool?
    public var storeMetadataWithItem: Bool?
    public var metadataFileFormat: String?
    public var rateLimitLoginRequests: Int?
    public var rateLimitLoginWindow: Int?
    public var backupSchedule: String?
    public var backupsToKeep: Int?
    public var maxBackupSize: Int?
    public var loggerDailyLogsToKeep: Int?
    public var loggerScannerLogsToKeep: Int?
    public var sortingIgnorePrefix: Bool?
    public var sortingPrefixes: [String]?
    public var chromecastEnabled: Bool?
    public var dateFormat: String?
    public var timeFormat: String?
    public var language: String?
    public var logLevel: Int?
    public var version: String?
}

public struct ABSServerSettingsUpdate: Codable {
    public var scannerFindCovers: Bool?
    public var scannerCoverProvider: String?
    public var scannerParseSubtitle: Bool?
    public var scannerPreferMatchedMetadata: Bool?
    public var scannerDisableWatcher: Bool?
    public var storeCoverWithItem: Bool?
    public var storeMetadataWithItem: Bool?
    public var metadataFileFormat: String?
    public var backupSchedule: String?
    public var backupsToKeep: Int?
    public var maxBackupSize: Int?
    public var sortingIgnorePrefix: Bool?
    public var chromecastEnabled: Bool?
    public var logLevel: Int?

    public init() {}
}

public struct ABSLibraryRequest: Codable {
    public let name: String?
    public let mediaType: String?
    public let folders: [ABSLibraryFolderPayload]?
}

public struct ABSLibraryFolderPayload: Codable {
    public let fullPath: String
}
