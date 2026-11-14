import Foundation

@MainActor
final class SiloAdminService {
    static let pageLimit = 1...200

    private let resolveProvider: () -> SiloProvider?

    init(connection: ServerConnection, profileSession: ProfileSession = .owner) {
        let connectionId = connection.id
        resolveProvider = { profileSession.appState.getProvider(connectionId) as? SiloProvider }
    }

    init(provider: SiloProvider) {
        resolveProvider = { provider }
    }

    func fetchAdminUsers() async throws -> [SiloAdminUser] {
        var users: [SiloAdminUser] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "limit", value: String(Self.pageLimit.upperBound))]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: SiloAdminUserPage = try await send("/admin/users", query: query)
            users += page.items
            cursor = try page.page?.continuation()
            if let cursor, !seen.insert(cursor).inserted { throw SiloAdminError.invalidPage }
        } while cursor != nil
        return users
    }

    func fetchMe() async throws -> SiloMeUser {
        try await send("/account/me")
    }

    func fetchStats() async throws -> SiloAdminStats {
        try await send("/admin/stats")
    }

    func fetchLibraries() async throws -> [SiloAdminLibrary] {
        let response: SiloAdminLibraryCollection = try await send("/libraries")
        return response.items
    }

    func fetchPlaybackHistory(limit: Int = 25) async throws -> [SiloPlaybackEntry] {
        let page: SiloPlaybackHistoryPage = try await send("/admin/playback-history", query: [Self.limitItem(limit)])
        return page.items
    }

    func fetchRecentScans(limit: Int = 20) async throws -> [SiloScan] {
        let page: SiloScansPage = try await send("/admin/autoscan/scans", query: [Self.limitItem(limit)])
        return page.items
    }

    func catalogTotal(libraryId: String, type: String) async throws -> Int {
        let response: SiloCatalogCount = try await send(
            "/catalog",
            query: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "limit", value: "1"),
            ]
        )
        return response.total
    }

    func scanLibrary(id: String) async throws {
        let _: SiloScanAccepted = try await send("/scan", method: "POST", body: ["library_id": id])
    }

    private static func limitItem(_ limit: Int) -> URLQueryItem {
        URLQueryItem(name: "limit", value: String(min(max(limit, pageLimit.lowerBound), pageLimit.upperBound)))
    }

    private func send<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: String]? = nil
    ) async throws -> T {
        guard let provider = resolveProvider() else { throw SiloAdminError.providerUnavailable }
        _ = try await provider.activityProfileID()
        var request = try provider.makeRequest(path: path, query: query, method: method)
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        do {
            return try await provider.send(request, as: T.self)
        } catch ProviderError.unauthorized {
            throw SiloAdminError.unauthorized
        }
    }
}

enum SiloAdminError: Error {
    case unauthorized
    case providerUnavailable
    case invalidPage
}

struct SiloAdminPageInfo: Decodable {
    let nextCursor: String?
    let hasMore: Bool

    func continuation() throws -> String? {
        guard hasMore else { return nil }
        guard let nextCursor, !nextCursor.isEmpty else { throw SiloAdminError.invalidPage }
        return nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

struct SiloMeUser: Decodable {
    let id: String
    let username: String
    let email: String
    let role: String

    var displayName: String { [username, email].first { !$0.isEmpty } ?? "Account" }
    var isAdmin: Bool { role == "admin" }
}

struct SiloAdminUserPage: Decodable {
    let items: [SiloAdminUser]
    let page: SiloAdminPageInfo?
}

struct SiloAdminUser: Decodable, Identifiable {
    let id: String
    let username: String
    let email: String
    let role: String
    let enabled: Bool
    let isOwner: Bool
    let effectivePolicy: Policy

    struct Policy: Decodable {
        let libraryIDs: [String]?
        let maxPlaybackQuality: String
        let maxStreams: Int
        let downloadAllowed: Bool

        enum CodingKeys: String, CodingKey {
            case libraryIDs = "library_ids"
            case maxPlaybackQuality = "max_playback_quality"
            case maxStreams = "max_streams"
            case downloadAllowed = "download_allowed"
        }
    }

    var displayName: String { [username, email].first { !$0.isEmpty } ?? "User \(id)" }
    var isAdmin: Bool { role == "admin" || isOwner }

    enum CodingKeys: String, CodingKey {
        case id, username, email, role, enabled
        case isOwner = "is_owner"
        case effectivePolicy = "effective_policy"
    }
}

struct SiloAdminLibraryCollection: Decodable {
    let items: [SiloAdminLibrary]
}

struct SiloAdminLibrary: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
    let enabled: Bool

    var isReadingLibrary: Bool {
        let type = type.lowercased()
        return type.contains("audio") || type.contains("book") || type.contains("manga") || type.contains("comic")
    }

    var countsAudiobooks: Bool { type.lowercased().contains("audio") }
    var countsEbooks: Bool {
        let type = type.lowercased()
        return type.contains("book") || type.contains("ebook") || type.contains("manga") || type.contains("comic")
    }
}

struct SiloAdminStats: Decodable {
    let totalItems: Int?
    let totalFiles: Int?
    let totalUsers: Int?
    let totalMovies: Int?
    let totalMovieFiles: Int?
    let totalShows: Int?
    let totalShowFiles: Int?
    let activeStreams: Int?
    let totalStorageBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case totalItems = "total_items"
        case totalFiles = "total_files"
        case totalUsers = "total_users"
        case totalMovies = "total_movies"
        case totalMovieFiles = "total_movie_files"
        case totalShows = "total_shows"
        case totalShowFiles = "total_show_files"
        case activeStreams = "active_streams"
        case totalStorageBytes = "total_storage_bytes"
    }
}

struct SiloPlaybackHistoryPage: Decodable {
    let items: [SiloPlaybackEntry]
    let page: SiloAdminPageInfo?
}

struct SiloPlaybackEntry: Decodable {
    let sessionID: String
    let username: String?
    let profileName: String?
    let mediaTitle: String?
    let mediaType: String?
    let playMethod: String?
    let startedAt: Date?
    let endedAt: Date?
    let watchedSeconds: Double?
    let durationSeconds: Double?
    let completed: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case username
        case profileName = "profile_name"
        case mediaTitle = "media_title"
        case mediaType = "media_type"
        case playMethod = "play_method"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case watchedSeconds = "watched_seconds"
        case durationSeconds = "duration_seconds"
        case completed
    }
}

struct SiloScansPage: Decodable {
    let items: [SiloScan]
    let page: SiloAdminPageInfo?
    let total: Int
}

struct SiloScan: Decodable {
    let id: String
    let libraryID: String?
    let mode: String?
    let path: String?
    let trigger: String?
    let status: String?
    let errorMessage: String?
    let requestedAt: Date?
    let startedAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, mode, path, trigger, status
        case libraryID = "library_id"
        case errorMessage = "error_message"
        case requestedAt = "requested_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct SiloCatalogCount: Decodable {
    let total: Int
    let totalExact: Bool

    enum CodingKeys: String, CodingKey {
        case total
        case totalExact = "total_exact"
    }
}

private struct SiloScanAccepted: Decodable {
    let status: String
}
