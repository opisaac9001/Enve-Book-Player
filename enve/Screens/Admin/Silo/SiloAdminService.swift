import Foundation

@MainActor
final class SiloAdminService {
    private let connectionId: UUID
    private let fallbackConnection: ServerConnection
    private let session: URLSession
    private let decoder: JSONDecoder

    init(connection: ServerConnection) {
        self.connectionId = connection.id
        self.fallbackConnection = connection

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        if let customHeaders = connection.customHeaders {
            config.httpAdditionalHeaders = customHeaders
        }
        if connection.mtlsEnabled {
            self.session = MTLSManager.shared.makeSession(for: connection.id, configuration: config)
        } else {
            self.session = InsecureURLSession.shared
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        self.decoder = decoder
    }

    private var connection: ServerConnection {
        AppState.shared.providerConnections.connections.first { $0.id == connectionId } ?? fallbackConnection
    }

    func fetchAdminUsers() async throws -> [SiloAdminUser] {
        try await get("/admin/users")
    }

    func fetchMe() async throws -> SiloMeUser {
        try await get("/auth/me")
    }

    func fetchStats() async throws -> SiloAdminStats {
        try await get("/admin/stats")
    }

    func fetchLibraries() async throws -> [SiloAdminLibrary] {
        try await get("/libraries")
    }

    func fetchPlaybackHistory(limit: Int = 25) async throws -> [SiloPlaybackEntry] {
        try await get("/admin/playback-history", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func fetchRecentScans(limit: Int = 20) async throws -> [SiloScan] {
        let response: SiloScansResponse = try await get(
            "/admin/autoscan/scans",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return response.scans
    }

    func catalogTotal(libraryId: Int, type: String) async throws -> Int {
        let response: SiloCatalogCount = try await get(
            "/catalog",
            query: [
                URLQueryItem(name: "library_id", value: String(libraryId)),
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "include_total", value: "true"),
            ]
        )
        return response.total ?? 0
    }

    func scanLibrary(id: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["library_id": id])
        try await sendVoid("/scan", method: "POST", body: body)
    }

    private var baseURLString: String {
        var value = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private var profileID: String? {
        UserDefaults.standard.string(forKey: "silo_profile_id_\(connectionId.uuidString)")
    }

    private func makeRequest(_ path: String, method: String, query: [URLQueryItem], body: Data?) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURLString)/api/v1\(path)") else {
            throw SiloAdminError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SiloAdminError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Enve Book Player/1.0", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let connection = self.connection
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders { request.setValue(value, forHTTPHeaderField: key) }
        }
        if let token = connection.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let profileID, !profileID.isEmpty {
            request.setValue(profileID, forHTTPHeaderField: "X-Profile-Id")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await sendData(path, method: "GET", query: query, body: nil)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SiloAdminError.decoding
        }
    }

    @discardableResult
    private func sendData(_ path: String, method: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let request = try makeRequest(path, method: method, query: query, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SiloAdminError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw SiloAdminError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw SiloAdminError.server(http.statusCode) }
        return data
    }

    private func sendVoid(_ path: String, method: String, body: Data?) async throws {
        _ = try await sendData(path, method: method, query: [], body: body)
    }

    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
    }
}

enum SiloAdminError: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)
    case decoding
}

struct SiloMeUser: Decodable {
    let id: Int?
    let username: String?
    let email: String?
    let role: String?
    let permissions: [String]?
    let enabled: Bool?

    var displayName: String { username ?? email ?? "Account" }
    var isAdmin: Bool {
        let role = role?.lowercased()
        return role == "admin" || role == "owner" || role == "root"
    }
}

struct SiloAdminUser: Decodable, Identifiable {
    let id: Int
    let username: String?
    let email: String?
    let role: String?
    let permissions: [String]?
    let enabled: Bool?
    let libraryIDs: [Int]?
    let maxPlaybackQuality: String?
    let maxStreams: Int?
    let maxTranscodes: Int?
    let maxProfiles: Int?
    let downloadAllowed: Bool?
    let downloadTranscodeAllowed: Bool?
    let createdAt: Date?
    let updatedAt: Date?
    let lastActiveAt: Date?

    var displayName: String { username ?? email ?? "User #\(id)" }
    var isAdmin: Bool {
        let role = role?.lowercased()
        return role == "admin" || role == "owner" || role == "root"
    }

    enum CodingKeys: String, CodingKey {
        case id, username, email, role, permissions, enabled
        case libraryIDs = "library_ids"
        case maxPlaybackQuality = "max_playback_quality"
        case maxStreams = "max_streams"
        case maxTranscodes = "max_transcodes"
        case maxProfiles = "max_profiles"
        case downloadAllowed = "download_allowed"
        case downloadTranscodeAllowed = "download_transcode_allowed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastActiveAt = "last_active_at"
    }
}

struct SiloAdminLibrary: Decodable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let paths: [String]?
    let enabled: Bool?
    let metadataLanguage: String?
    let sortOrder: Int?
    let posterURL: String?
    let lastScannedAt: Date?

    var isReadingLibrary: Bool {
        let type = type.lowercased()
        return type.contains("audio") || type.contains("book") || type.contains("manga") || type.contains("comic")
    }

    var countsAudiobooks: Bool { type.lowercased().contains("audio") }
    var countsEbooks: Bool {
        let type = type.lowercased()
        return type.contains("book") || type.contains("ebook") || type.contains("manga") || type.contains("comic")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, paths, enabled
        case metadataLanguage = "metadata_language"
        case sortOrder = "sort_order"
        case posterURL = "poster_url"
        case lastScannedAt = "last_scanned_at"
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

struct SiloPlaybackEntry: Decodable {
    let sessionID: String?
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

struct SiloScansResponse: Decodable {
    let scans: [SiloScan]
    let total: Int?
}

struct SiloScan: Decodable {
    let id: Int?
    let libraryID: Int?
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
    let total: Int?
    let totalExact: Bool?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case total
        case totalExact = "total_exact"
        case hasMore = "has_more"
    }
}
