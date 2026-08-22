import Foundation

public struct BackendConfig: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let type: BackendType
    public let url: String
    public let token: String?
    public let enabled: Bool
    public let username: String?
    public let password: String?
    public let userId: String?
    public let selectedLibraryIds: Set<String>?
    public var customHeaders: [String: String]? = nil
    public var authMode: ConnectionAuthMode = .auto
    public var mtlsEnabled: Bool = false

    public enum BackendType: String, Codable {
        case plex
        case audiobookshelf
        case jellyfin
        case emby
        case storyteller
    }

    public var isValid: Bool {
        guard !url.isEmpty else { return false }

        switch type {
        case .plex:
            return !(token?.isEmpty ?? true)
        case .audiobookshelf:
            return !(token?.isEmpty ?? true) || (!(username?.isEmpty ?? true) && !(password?.isEmpty ?? true))
        case .jellyfin, .emby:
            return !(token?.isEmpty ?? true)
        case .storyteller:
            return !(token?.isEmpty ?? true)
        }
    }

    var baseURL: URL? {
        return URL(string: url)
    }
}

extension BackendConfig {
    init?(from connection: ServerConnection) {
        let backendType: BackendType
        switch connection.type {
        case .plex: backendType = .plex
        case .audiobookshelf: backendType = .audiobookshelf
        case .jellyfin: backendType = .jellyfin
        case .emby: backendType = .emby
        case .storyteller: backendType = .storyteller
        case .webdav, .torbox, .premiumize, .realdebrid, .local, .booklore, .komga, .kavita, .opds, .bookOrbit, .silo:
            return nil
        }
        self.id = connection.id.uuidString
        self.name = connection.name
        self.type = backendType
        self.url = connection.url
        self.token = connection.token
        self.enabled = connection.isConnected
        self.username = connection.username
        self.password = nil
        self.userId = connection.userId
        self.selectedLibraryIds = connection.selectedLibraryIds
        self.customHeaders = connection.customHeaders
        self.authMode = connection.authMode
        self.mtlsEnabled = connection.mtlsEnabled
    }
}
