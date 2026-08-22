import Combine
import Foundation

enum SourceType: String, Codable, Sendable, CaseIterable {
    case webDAV = "webdav"
    case files = "files"
    case local = "local"
    case audiobookshelf = "audiobookshelf"
    case plex = "plex"
    case googleDrive = "google-drive"
    case iCloudDrive = "icloud-drive"
    case dropbox = "dropbox"
    case jellyfin = "jellyfin"

    var displayName: String {
        switch self {
        case .webDAV: return "WebDAV Server"
        case .files: return "Files App"
        case .local: return "Local Storage"
        case .audiobookshelf: return "Audiobookshelf"
        case .plex: return "Plex"
        case .googleDrive: return "Google Drive"
        case .iCloudDrive: return "iCloud Drive"
        case .dropbox: return "Dropbox"
        case .jellyfin: return "Jellyfin"
        }
    }

    var iconName: String {
        switch self {
        case .webDAV: return "cloud"
        case .files: return "folder"
        case .local: return "iphone"
        case .audiobookshelf: return "books.vertical"
        case .plex: return "play.rectangle"
        case .googleDrive: return "internaldrive"
        case .iCloudDrive: return "icloud"
        case .dropbox: return "externaldrive"
        case .jellyfin: return "play.tv"
        }
    }
}

struct SourceInfo: Codable, Equatable, Sendable {
    let type: SourceType
    let serverId: String?
    let serverName: String?
    let remotePath: String
    let importedAt: Date
    let lastSyncCheck: Date?

    init(
        type: SourceType,
        serverId: String? = nil,
        serverName: String? = nil,
        remotePath: String,
        importedAt: Date = Date(),
        lastSyncCheck: Date? = nil
    ) {
        self.type = type
        self.serverId = serverId
        self.serverName = serverName
        self.remotePath = remotePath
        self.importedAt = importedAt
        self.lastSyncCheck = lastSyncCheck
    }

    static func fromFiles(path: String) -> SourceInfo {
        return SourceInfo(type: .files, remotePath: path)
    }

    static func fromWebDAV(serverId: String, serverName: String, path: String) -> SourceInfo {
        return SourceInfo(type: .webDAV, serverId: serverId, serverName: serverName, remotePath: path)
    }

    static func local(path: String) -> SourceInfo {
        return SourceInfo(type: .local, remotePath: path)
    }
}

struct WebDAVServerConfig: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var baseURL: URL
    var username: String?
    var password: String?
    var authType: WebDAVAuthType
    var rootPath: String
    var indexedPaths: [String]
    var isEnabled: Bool
    var lastConnected: Date?
    var autoSync: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: URL,
        username: String? = nil,
        password: String? = nil,
        authType: WebDAVAuthType = .none,
        rootPath: String = "/",
        indexedPaths: [String] = [],
        isEnabled: Bool = true,
        lastConnected: Date? = nil,
        autoSync: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.authType = authType
        self.rootPath = rootPath
        self.indexedPaths = indexedPaths
        self.isEnabled = isEnabled
        self.lastConnected = lastConnected
        self.autoSync = autoSync
    }

    enum WebDAVAuthType: String, Codable, Sendable {
        case none
        case basic
        case digest
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, username, password, authType, rootPath, indexedPaths, isEnabled, lastConnected, autoSync
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        authType = try container.decodeIfPresent(WebDAVAuthType.self, forKey: .authType) ?? .none
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? "/"
        indexedPaths = try container.decodeIfPresent([String].self, forKey: .indexedPaths) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        autoSync = try container.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encode(authType, forKey: .authType)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(indexedPaths, forKey: .indexedPaths)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try container.encode(autoSync, forKey: .autoSync)
    }

    func url(for path: String) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }

        let basePath = baseURL.path
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { normalized = "/" }
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }

        if basePath != "/", normalized.hasPrefix(basePath) {
            normalized = String(normalized.dropFirst(basePath.count))
            if normalized.isEmpty { normalized = "/" }
            if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        }

        if rootPath != "/", normalized.hasPrefix(rootPath) {
            normalized = String(normalized.dropFirst(rootPath.count))
            if normalized.isEmpty { normalized = "/" }
            if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        }

        let cleanPath = normalized.hasPrefix("/") ? String(normalized.dropFirst()) : normalized
        return baseURL.appendingPathComponent(rootPath).appendingPathComponent(cleanPath)
    }
}

struct ImportProgress: Identifiable, Sendable {
    let id: String
    let bookTitle: String
    let sourcePath: String
    var status: ImportStatus
    var bytesDownloaded: Int64
    var totalBytes: Int64
    var error: String?
    var startedAt: Date
    var completedAt: Date?

    init(
        id: String = UUID().uuidString,
        bookTitle: String,
        sourcePath: String,
        status: ImportStatus = .pending,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        error: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.bookTitle = bookTitle
        self.sourcePath = sourcePath
        self.status = status
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    var isActive: Bool {
        switch status {
        case .pending, .downloading, .processing:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

enum ImportStatus: String, Codable, Sendable {
    case pending
    case downloading
    case processing
    case completed
    case failed
    case cancelled
}

struct RemoteFileEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedDate: Date?
    let mimeType: String?
    let contentURL: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedDate: Date? = nil,
        mimeType: String? = nil,
        contentURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.mimeType = mimeType
        self.contentURL = contentURL
    }

    var isAudioFile: Bool {
        guard !isDirectory else { return false }

        let nameExt = (name as NSString).pathExtension.lowercased()
        if let format = AudiobookFormat.from(fileExtension: nameExt) {
            if format == .mp4 {
                if let mime = mimeType?.lowercased() {
                    return mime.hasPrefix("audio/") || mime == "application/octet-stream"
                }
            }
            return true
        }

        let pathExt = (path as NSString).pathExtension.lowercased()
        if let format = AudiobookFormat.from(fileExtension: pathExt) {
            if format == .mp4 {
                if let mime = mimeType?.lowercased() {
                    return mime.hasPrefix("audio/") || mime == "application/octet-stream"
                }
            }
            return true
        }

        if let mime = mimeType?.lowercased(), mime.hasPrefix("video/") {
            return false
        }

        return false
    }

    var isMetadataFile: Bool {
        guard !isDirectory else { return false }
        let filename = name.lowercased()
        return filename == "metadata.json" || filename.hasSuffix(".sidecar.json") || filename == "info.json"
    }

    var isZipArchive: Bool {
        guard !isDirectory else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "zip" { return true }
        let pathExt = (path as NSString).pathExtension.lowercased()
        return pathExt == "zip"
    }

    var isEbookFile: Bool {
        guard !isDirectory else { return false }

        let nameExt = (name as NSString).pathExtension.lowercased()
        if EbookFormat.from(fileExtension: nameExt) != nil {
            return true
        }

        let pathExt = (path as NSString).pathExtension.lowercased()
        return EbookFormat.from(fileExtension: pathExt) != nil
    }

    var isCoverImage: Bool {
        guard !isDirectory else { return false }
        let filename = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "webp"]
        return imageExtensions.contains(ext) && (filename.contains("cover") || filename.contains("folder") || filename.contains("artwork"))
    }
}

struct ImportBatch: Identifiable, Sendable {
    let id: String
    let sourceType: SourceType
    let serverName: String?
    var items: [ImportProgress]
    let createdAt: Date
    var completedAt: Date?

    init(
        id: String = UUID().uuidString,
        sourceType: SourceType,
        serverName: String? = nil,
        items: [ImportProgress] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceType = sourceType
        self.serverName = serverName
        self.items = items
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    var totalItems: Int { items.count }
    var completedItems: Int { items.filter { $0.status == .completed }.count }
    var failedItems: Int { items.filter { $0.status == .failed }.count }
    var activeItems: Int { items.filter { $0.isActive }.count }

    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        let totalProgress = items.reduce(0.0) { $0 + $1.progress }
        return totalProgress / Double(items.count)
    }

    var isComplete: Bool {
        return activeItems == 0
    }
}
