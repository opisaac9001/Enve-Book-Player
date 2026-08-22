import Combine
import Foundation
import UniformTypeIdentifiers

struct RemoteItem: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let mimeType: String?
    let modifiedDate: Date?
    let pathHint: String?
    let parentId: String?

    var isAudioFile: Bool {
        guard !isFolder else { return false }

        if let mimeType = mimeType {
            return mimeType.hasPrefix("audio/")
        }

        let audioExtensions = ["mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav"]
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

    var isLikelyAudiobookFolder: Bool {
        guard isFolder else { return false }

        let name = self.name.lowercased()
        return name.contains("audiobook") || name.contains("audio book") || !name.starts(with: ".")
    }
}

struct ResolvedFile: Sendable {
    let localURL: URL?
    let streamURL: URL?
    let expiresAt: Date?
    let requiresAuthHeader: Bool
    let authHeaderValue: String?
    let contentLength: Int64?

    var isLocal: Bool { localURL != nil }
    var isStreamable: Bool { streamURL != nil }
}

enum AuthenticationState: Sendable, Equatable {
    case notAuthenticated
    case authenticating
    case authenticated
    case authenticationFailed(String)
    case tokenExpired

    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

struct SourceCapabilities: Sendable, OptionSet {
    let rawValue: Int

    static let streaming = SourceCapabilities(rawValue: 1 << 0)
    static let folderBrowsing = SourceCapabilities(rawValue: 1 << 1)
    static let search = SourceCapabilities(rawValue: 1 << 2)
    static let metadata = SourceCapabilities(rawValue: 1 << 3)
    static let resumePoints = SourceCapabilities(rawValue: 1 << 4)
    static let chapters = SourceCapabilities(rawValue: 1 << 5)
    static let multiFile = SourceCapabilities(rawValue: 1 << 6)
    static let backgroundRefresh = SourceCapabilities(rawValue: 1 << 7)

    static let basic: SourceCapabilities = [.folderBrowsing]
    static let full: SourceCapabilities = [.streaming, .folderBrowsing, .search, .metadata, .resumePoints, .chapters]
}

protocol BookSourceProvider: AnyObject, Sendable {
    var id: String { get }

    var displayName: String { get }

    var iconName: String { get }

    var capabilities: SourceCapabilities { get }

    var authenticationState: AuthenticationState { get }

    func authenticate() async throws

    func refreshAuthentication() async throws

    func signOut() async throws

    func listRoot() async throws -> [RemoteItem]

    func listFolder(_ itemId: String) async throws -> [RemoteItem]

    func search(_ query: String) async throws -> [RemoteItem]

    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile

    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata?
}

struct SourceBookMetadata: Sendable, Equatable {
    let title: String?
    let author: String?
    let narrator: String?
    let description: String?
    let coverURL: URL?
    let duration: TimeInterval?
    let chapters: [ChapterMetadata]?
    let series: String?
    let seriesNumber: Int?
    let publishedYear: Int?
    let genres: [String]?
    let publisher: String?
    let isbn: String?
    let asin: String?
}

struct ChapterMetadata: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}
