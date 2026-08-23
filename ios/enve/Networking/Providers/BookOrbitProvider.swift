import AVFoundation
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

final class BookOrbitProvider: IncrementalCatalogProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EbookDownloadProvider, PersonalRatingProvider, HistorySessionSyncProvider,
    @unchecked Sendable
{
    var connection: ServerConnection
    private var cachedContinueProgress: [UserMediaProgress] = []
    private var cachedContinueProgressAt: Date = .distantPast
    private var cachedAdminStatus: Bool?

    enum BookOrbitReadStatus: String {
        case unread
        case wantToRead = "want_to_read"
        case reading
        case onHold = "on_hold"
        case rereading
        case read
        case skimmed
        case abandoned
    }

    enum ActivitySnapshotError: Error {
        case unsupported
    }

    enum FeatureError: Error {
        case unavailable
    }

    struct ActivityRecord: Sendable {
        let bookId: String
        let status: BookOrbitReadStatus
        let progress: Double
        let epubCFI: String?
        let updatedAt: Date
        let rating: Double?
    }

    struct ReadingSessionRecord: Sendable {
        let id: Int
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Int
        let progressDelta: Double?
        let endProgress: Double?
    }

    struct ReaderBookmarkRecord: Sendable {
        let id: Int
        let cfi: String?
        let title: String
        let positionSeconds: Double?
        let createdAt: Date
    }

    struct ReaderAnnotationRecord: Sendable {
        let id: Int
        let cfi: String?
        let text: String
        let color: String
        let style: String
        let note: String?
        let chapterTitle: String?
        let createdAt: Date
    }

    struct CollectionPage: Sendable {
        let books: [Book]
        let total: Int
        let page: Int
        let size: Int

        var hasMore: Bool { (page + 1) * size < total }
    }

    struct CollectionEdit: Sendable {
        let name: String
        let description: String?
        let icon: String
        let syncToKobo: Bool
    }

    var capabilities: ProviderCapabilities {

        [
            .fullImport, .pagedImport,
            .audiobookProgressPull, .audiobookProgressPush,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .collections, .coverAuthHeader, .backgroundOperation,
        ]
    }

    var supportsPersonalRating: Bool { true }

    var onTokenUpdated: ((ServerConnection) -> Void)?

    private func notifyTokenUpdated() {
        let conn = connection
        let cb = onTokenUpdated
        DispatchQueue.main.async { cb?(conn) }
    }

    private func invalidateContinueCache() {
        cachedContinueProgress = []
        cachedContinueProgressAt = .distantPast
    }

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private var refreshTokenKey: String { "bookorbit_refresh_\(connection.id.uuidString)" }
    private var usernameKey: String { "bookorbit_username_\(connection.id.uuidString)" }
    private var passwordKey: String { "bookorbit_password_\(connection.id.uuidString)" }

    private func storedRefreshToken() -> String? { KeychainHelper.shared.get(refreshTokenKey) }
    private func storedUsername() -> String? { connection.username ?? KeychainHelper.shared.get(usernameKey) }
    private func storedPassword() -> String? { connection.password ?? KeychainHelper.shared.get(passwordKey) }

    private var apiBase: URL? {
        guard let base = URL(string: connection.url) else { return nil }
        return base.appendingPathComponent("api/v1")
    }

    private func serveURL(fileId: Int) -> URL? {
        apiBase?.appendingPathComponent("books/files/\(fileId)/serve")
    }

    private func coverURLString(bookId: Int) -> String? {
        apiBase?.appendingPathComponent("books/\(bookId)/cover").absoluteString
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let raw = try? container.decode(String.self),
                let parsed = parseDate(raw)
            {
                return parsed
            }
            if let epochMs = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: epochMs > 1_000_000_000_000 ? epochMs / 1000 : epochMs)
            }
            if let epochMs = try? container.decode(Int64.self) {
                let value = Double(epochMs)
                return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported BookOrbit date value"
            )
        }
        return d
    }()

    nonisolated private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }

    private func login() async throws {
        guard let apiBase,
            let username = storedUsername(), !username.isEmpty,
            let password = storedPassword(), !password.isEmpty
        else {
            throw ProviderError.unauthorized
        }

        var request = URLRequest(url: apiBase.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCustomHeaders(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Login failed (HTTP \(http.statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["accessToken"] as? String, !accessToken.isEmpty
        else {
            throw ProviderError.invalidResponse
        }

        captureRefreshCookie(from: http, requestURL: request.url)
        KeychainHelper.shared.set(username, key: usernameKey)
        KeychainHelper.shared.set(password, key: passwordKey)

        connection.token = accessToken
        connection.password = nil
        connection.isConnected = true
        connection.lastVerified = Date()
        notifyTokenUpdated()
        AppLogger.player.info("[BookOrbit] Login successful")
    }

    private func refreshAccessToken() async throws {
        guard let apiBase, let refresh = storedRefreshToken(), !refresh.isEmpty else {
            guard connection.authMode != .sso else { throw ProviderError.unauthorized }
            try await login()
            return
        }

        var request = URLRequest(url: apiBase.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("refresh_token=\(refresh)", forHTTPHeaderField: "Cookie")
        applyCustomHeaders(&request)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["accessToken"] as? String, !accessToken.isEmpty
        else {
            guard connection.authMode != .sso else {
                AppLogger.player.info("[BookOrbit] SSO refresh failed")
                throw ProviderError.unauthorized
            }
            AppLogger.player.info("[BookOrbit] Refresh failed, falling back to credential login")
            try await login()
            return
        }

        captureRefreshCookie(from: http, requestURL: request.url)
        connection.token = accessToken
        connection.isConnected = true
        connection.lastVerified = Date()
        notifyTokenUpdated()
    }

    private func ensureValidToken() async throws {
        if let token = connection.token, !token.isEmpty, !Self.jwtExpiring(token, within: 60) {
            return
        }
        if connection.token == nil || connection.token!.isEmpty {
            if storedRefreshToken() != nil {
                try await refreshAccessToken()
            } else {
                try await login()
            }
        } else {
            try await refreshAccessToken()
        }
    }

    private func captureRefreshCookie(from response: HTTPURLResponse, requestURL: URL?) {
        guard let requestURL,
            let fields = response.allHeaderFields as? [String: String]
        else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: requestURL)
        if let refresh = cookies.first(where: { $0.name == "refresh_token" }) {
            KeychainHelper.shared.set(refresh.value, key: refreshTokenKey)
        }
    }

    private func applyCustomHeaders(_ request: inout URLRequest) {
        if let custom = connection.customHeaders {
            for (k, v) in custom { request.setValue(v, forHTTPHeaderField: k) }
        }
    }

    private static func jwtExpiring(_ token: String, within seconds: TimeInterval) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = json["exp"] as? Double
        else {
            return false
        }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < seconds
    }

    private func perform(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        query: [URLQueryItem]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await ensureValidToken()
        var (data, response) = try await send(path, method: method, body: body, query: query)
        if response.statusCode == 401 {
            try await refreshAccessToken()
            (data, response) = try await send(path, method: method, body: body, query: query)
        }

        try guardJSON(data: data, response: response, endpoint: path)
        return (data, response)
    }

    func requestJSON<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        query: [URLQueryItem]? = nil
    ) async throws -> T {
        let (data, http) = try await perform(path, method: method, body: body, query: query)
        try Self.requireSuccess(http, data: data, path: path)
        return try Self.decoder.decode(T.self, from: data)
    }

    func requestOptionalJSON<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T? {
        let (data, http) = try await perform(path, query: query)
        try Self.requireSuccess(http, data: data, path: path)
        return try Self.decoder.decode(T?.self, from: data)
    }

    func requestVoid(
        _ path: String,
        method: String,
        body: Data? = nil,
        query: [URLQueryItem]? = nil
    ) async throws {
        let (data, http) = try await perform(path, method: method, body: body, query: query)
        try Self.requireSuccess(http, data: data, path: path)
    }

    func requestRaw(_ path: String, query: [URLQueryItem]? = nil) async throws -> (Data, HTTPURLResponse) {
        try await ensureValidToken()
        var (data, http) = try await send(path, method: "GET", body: nil, query: query)
        if http.statusCode == 401 {
            try await refreshAccessToken()
            (data, http) = try await send(path, method: "GET", body: nil, query: query)
        }
        try Self.requireSuccess(http, data: data, path: path)
        return (data, http)
    }

    private static func requireSuccess(_ http: HTTPURLResponse, data: Data, path: String) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        guard http.statusCode != 404 else { throw FeatureError.unavailable }
        throw ProviderError.serverError(serverMessage(data: data) ?? "BookOrbit returned HTTP \(http.statusCode) for /api/v1/\(path)")
    }

    private static func serverMessage(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        return (json["message"] as? [String])?.first
    }

    private func guardJSON(data: Data, response: HTTPURLResponse, endpoint: String) throws {
        if response.statusCode == 302 || response.statusCode == 303,
            let location = response.value(forHTTPHeaderField: "Location"),
            location.lowercased().contains("cloudflareaccess.com") || location.contains("/cdn-cgi/access/")
        {
            AppLogger.network.info("[BookOrbit] Cloudflare Access rejected /\(endpoint). Redirect to: \(location)")
            throw ProviderError.serverError(cloudflareAccessErrorMessage(from: location, endpoint: endpoint))
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let isHTML =
            contentType.contains("text/html") || (data.count > 5 && String(data: data.prefix(20), encoding: .utf8)?.contains("<") == true)
        if isHTML {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            AppLogger.network.info("[BookOrbit] /\(endpoint) returned HTML instead of JSON. Content-Type: \(contentType)")

            let previewLower = preview.lowercased()
            if previewLower.contains("cloudflare access") || previewLower.contains("cloudflareaccess") {
                throw ProviderError.serverError(
                    "Cloudflare Access is blocking the request to /\(endpoint). "
                        + "Your service token may be invalid, expired, or not associated with the correct Access policy. "
                        + "Try 'Login with Browser' instead, or verify your service token in the Cloudflare Zero Trust dashboard."
                )
            }

            throw ProviderError.serverError(
                "BookOrbit server returned an HTML page instead of JSON for /\(endpoint) (HTTP \(response.statusCode)). "
                    + "Check that your server URL points at a BookOrbit instance. The app appends `/api/v1` automatically, "
                    + "so the URL should NOT already include it."
            )
        }
    }

    private func cloudflareAccessErrorMessage(from location: String, endpoint: String) -> String {
        guard let details = decodeCloudflareAccessRedirectDetails(from: location) else {
            return "Cloudflare Access rejected the request to /\(endpoint). "
                + "Your service token may be invalid, expired, or not associated with the correct Access policy. "
                + "Try 'Login with Browser' instead, or verify your service token in the Cloudflare Zero Trust dashboard."
        }
        var message = "Cloudflare Access rejected the request to /\(endpoint)."
        if details.serviceTokenStatus == false {
            message +=
                " Cloudflare reported service_token_status=false, meaning the service token was not accepted for this Access application."
        }
        if let authStatus = details.authStatus, !authStatus.isEmpty, authStatus != "NONE" {
            message += " auth_status=\(authStatus)."
        }
        if let redirectURL = details.redirectURL, !redirectURL.isEmpty {
            message += " redirect_url=\(redirectURL)."
        }
        message += " Check the Zero Trust Access policy for this app and ensure it includes a Service Auth rule for your service token."
        return message
    }

    private func decodeCloudflareAccessRedirectDetails(from location: String) -> CloudflareAccessRedirectDetails? {
        guard let components = URLComponents(string: location),
            let metaToken = components.queryItems?.first(where: { $0.name == "meta" })?.value
        else {
            return nil
        }
        let segments = metaToken.split(separator: ".")
        guard segments.count >= 2,
            let payload = base64URLDecode(String(segments[1])),
            let details = try? JSONDecoder().decode(CloudflareAccessRedirectDetails.self, from: payload)
        else {
            return nil
        }
        return details
    }

    private func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding != 0 { base64 += String(repeating: "=", count: 4 - padding) }
        return Data(base64Encoded: base64)
    }

    private struct CloudflareAccessRedirectDetails: Decodable {
        let redirectURL: String?
        let authStatus: String?
        let serviceTokenStatus: Bool?
        private enum CodingKeys: String, CodingKey {
            case redirectURL = "redirect_url"
            case authStatus = "auth_status"
            case serviceTokenStatus = "service_token_status"
        }
    }

    private func send(_ path: String, method: String, body: Data?, query: [URLQueryItem]?) async throws -> (Data, HTTPURLResponse) {
        guard let apiBase else { throw ProviderError.invalidURL }
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw ProviderError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyCustomHeaders(&request)
        if let token = connection.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }

    func validateConnection() async throws -> Bool {
        try await ensureValidToken()
        let (_, http) = try await perform("auth/me")
        let ok = http.statusCode == 200
        if ok {
            connection.isConnected = true
            connection.lastVerified = Date()
        }
        return ok
    }

    private struct LibraryDTO: Decodable { let id: Int; let name: String }

    private struct FileDTO: Decodable, Sendable {
        let id: Int
        let format: String?
        let role: String?
        let durationSeconds: Double?
        let filename: String?
    }

    private struct BooksPageDTO: Decodable { let items: [BookCardDTO]; let total: Int; let page: Int; let size: Int }

    private struct BookCardDTO: Decodable, Sendable {
        let id: Int
        let title: String?
        let subtitle: String?
        let authors: [String]?
        let narrators: [String]?
        let seriesName: String?
        let seriesIndex: Double?
        let publishedYear: Int?
        let language: String?
        let genres: [String]?
        let rating: Double?
        let publisher: String?
        let isbn13: String?
        let hasCover: Bool?
        let addedAt: Date?
        let files: [FileDTO]?
        let readingProgress: Double?
        let readStatus: ReadStatusDTO?
    }

    private struct ChapterDTO: Decodable { let title: String; let startMs: Double }
    private struct NarratorDTO: Decodable { let name: String }
    private struct AuthorDTO: Decodable { let name: String }
    private struct AudioMetadataDTO: Decodable {
        let narrators: [NarratorDTO]?
        let durationSeconds: Double?
        let chapters: [ChapterDTO]?
    }

    private struct BookDetailDTO: Decodable {
        let id: Int
        let libraryId: Int?
        let title: String?
        let subtitle: String?
        let description: String?
        let isbn13: String?
        let publisher: String?
        let publishedYear: Int?
        let language: String?
        let seriesName: String?
        let seriesIndex: Double?
        let authors: [AuthorDTO]?
        let genres: [String]?
        let rating: Double?
        let addedAt: Date?
        let hasCover: Bool?
        let coverSource: String?
        let files: [FileDTO]?
        let audioMetadata: AudioMetadataDTO?
        let readStatus: ReadStatusDTO?
    }

    private struct AudioProgressDTO: Decodable, Sendable {
        let percentage: Double?
        let currentFileId: Int?
        let positionSeconds: Double?
        let updatedAt: Date?
    }

    private struct FileProgressDTO: Decodable, Sendable {
        let cfi: String?
        let percentage: Double?
        let positionSeconds: Double?
        let updatedAt: Date?
    }

    private struct CurrentlyReadingWidgetDTO: Decodable { let books: [CurrentlyReadingBookDTO] }

    private struct MeDTO: Decodable { let isSuperuser: Bool }

    private struct CollectionDTO: Decodable {
        let id: Int
        let name: String
        let icon: String?
        let description: String?
        let syncToKobo: Bool
        let displayOrder: Int
        let bookCount: Int
        let memberCount: Int?
    }

    private struct CurrentlyReadingBookDTO: Decodable {
        let bookId: Int
        let progress: Double?
        let fileFormat: String?
        let fileId: Int?
    }

    private struct ReadStatusDTO: Decodable, Sendable {
        let status: String?
        let updatedAt: Date?
    }

    private struct ReadingSessionDTO: Decodable {
        let id: Int
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Int
        let progressDelta: Double?
        let endProgress: Double?
    }

    private struct ReadingSessionsPageDTO: Decodable {
        let items: [ReadingSessionDTO]
        let total: Int
        let page: Int
        let pageSize: Int
    }

    private struct ReaderBookmarkDTO: Decodable {
        let id: Int
        let cfi: String?
        let title: String
        let positionSeconds: Double?
        let createdAt: Date
    }

    private struct ReaderAnnotationDTO: Decodable {
        let id: Int
        let cfi: String?
        let text: String
        let color: String
        let style: String
        let note: String?
        let chapterTitle: String?
        let createdAt: Date
    }

    private struct ActivityCandidate: Sendable {
        let card: BookCardDTO
        let status: BookOrbitReadStatus
        let statusUpdatedAt: Date
    }

    func fetchLibraries() async throws -> [Library] {
        let (data, http) = try await perform("libraries")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError(
                "BookOrbit returned HTTP \(http.statusCode) for /api/v1/libraries. Check your server URL, credentials, and any reverse proxy or Access policy in front of BookOrbit."
            )
        }
        do {
            let libs = try Self.decoder.decode([LibraryDTO].self, from: data)
            return libs.map { Library(id: String($0.id), name: $0.name, type: "book", providerId: connection.id) }
        } catch {
            AppLogger.network.error("[BookOrbit] Could not decode /api/v1/libraries response: \(error.localizedDescription)")
            throw ProviderError.serverError(
                "BookOrbit /api/v1/libraries returned 200 but the response could not be decoded as the expected JSON. The server may be running an unsupported version."
            )
        }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        var all: [Book] = []
        let source = try await makeCatalogBatchSource(
            libraryId: libraryId,
            resumeAfter: nil,
            expectedSnapshotIdentifier: nil
        )
        while let batch = try await source.next() { all.append(contentsOf: batch.books) }
        AppLogger.player.info("[BookOrbit] Fetched \(all.count) books from library \(libraryId)")
        return all
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let firstPage = try await fetchCatalogPage(libraryId: libraryId, page: 0)
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: 200,
            pageConcurrency: 6,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.fetchCatalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func fetchCatalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        guard let libraryId = Int(libraryId) else { throw ProviderError.invalidURL }
        guard page <= 250 else {
            throw ProviderError.serverError("BookOrbit's catalog API cannot read beyond page 250")
        }
        let pageSize = 200
        let body = try JSONSerialization.data(withJSONObject: [
            "pagination": ["page": page, "size": pageSize]
        ])
        let (data, http) = try await perform("libraries/\(libraryId)/books", method: "POST", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for library \(libraryId), page \(page)")
        }
        let result = try Self.decoder.decode(BooksPageDTO.self, from: data)
        return LibraryCatalogPage(
            books: result.items.map { card($0, libraryId: String(libraryId)) },
            totalCount: result.total,
            isLast: result.items.count < pageSize || (page + 1) * pageSize >= result.total
        )
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        guard let libIdInt = Int(libraryId) else { throw ProviderError.invalidURL }
        let cappedLimit = max(1, min(limit, 200))

        let probeBody = try JSONSerialization.data(withJSONObject: [
            "pagination": ["page": 0, "size": 1]
        ])
        let (probeData, probeHTTP) = try await perform("libraries/\(libIdInt)/books", method: "POST", body: probeBody)
        guard (200...299).contains(probeHTTP.statusCode) else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(probeHTTP.statusCode) for /api/v1/libraries/\(libIdInt)/books")
        }
        let probe = try Self.decoder.decode(BooksPageDTO.self, from: probeData)
        guard probe.total > 0 else { return [] }
        let lastPage = max(0, (probe.total - 1) / cappedLimit)
        let body = try JSONSerialization.data(withJSONObject: [
            "pagination": ["page": lastPage, "size": cappedLimit]
        ])
        let (data, http) = try await perform("libraries/\(libIdInt)/books", method: "POST", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for /api/v1/libraries/\(libIdInt)/books")
        }
        let pageDTO = try Self.decoder.decode(BooksPageDTO.self, from: data)

        return pageDTO.items.reversed().map { card($0, libraryId: libraryId) }
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        let (data, http) = try await perform("collections")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for collections")
        }
        let editable = (try? await currentUserIsAdmin()) == true
        return try Self.decoder.decode([CollectionDTO].self, from: data)
            .sorted { lhs, rhs in
                lhs.displayOrder == rhs.displayOrder
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.displayOrder < rhs.displayOrder
            }
            .map { collection($0, editable: editable) }
    }

    func fetchCollectionBooks(
        collectionId: String,
        page: Int,
        size: Int = 60,
        query: String? = nil
    ) async throws -> CollectionPage {
        guard let id = Int(collectionId) else { throw ProviderError.invalidURL }
        var queryItems = [
            URLQueryItem(name: "page", value: String(max(0, page))),
            URLQueryItem(name: "size", value: String(min(max(1, size), 100))),
        ]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        let (data, http) = try await perform("collections/\(id)/books", query: queryItems)
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for collection books")
        }
        let result = try Self.decoder.decode(BooksPageDTO.self, from: data)
        return CollectionPage(
            books: result.items.map { card($0, libraryId: "") },
            total: result.total,
            page: result.page,
            size: result.size
        )
    }

    func collectionsContaining(bookId: String) async throws -> [(collection: Collection, containsBook: Bool)] {
        guard Int(bookId) != nil else { return [] }
        let (data, http) = try await perform("collections", query: [URLQueryItem(name: "bookIds", value: bookId)])
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for collection membership")
        }
        let editable = try await currentUserIsAdmin()
        return try Self.decoder.decode([CollectionDTO].self, from: data).map {
            (collection($0, editable: editable), $0.memberCount == 1)
        }
    }

    func currentUserIsAdmin(force: Bool = false) async throws -> Bool {
        if !force, let cachedAdminStatus { return cachedAdminStatus }
        let (data, http) = try await perform("auth/me")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for account details")
        }
        let isAdmin = try Self.decoder.decode(MeDTO.self, from: data).isSuperuser
        cachedAdminStatus = isAdmin
        return isAdmin
    }

    func createCollection(_ edit: CollectionEdit) async throws -> Collection {
        try await requireAdmin()
        let body = try collectionBody(edit)
        let (data, http) = try await perform("collections", method: "POST", body: body)
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) while creating the collection")
        }
        return collection(try Self.decoder.decode(CollectionDTO.self, from: data), editable: true)
    }

    func updateCollection(id: String, edit: CollectionEdit) async throws -> Collection {
        try await requireAdmin()
        guard let remoteId = Int(id) else { throw ProviderError.invalidURL }
        let (data, http) = try await perform("collections/\(remoteId)", method: "PATCH", body: try collectionBody(edit))
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) while updating the collection")
        }
        return collection(try Self.decoder.decode(CollectionDTO.self, from: data), editable: true)
    }

    func deleteCollection(id: String) async throws {
        try await requireAdmin()
        guard let remoteId = Int(id) else { throw ProviderError.invalidURL }
        let (_, http) = try await perform("collections/\(remoteId)", method: "DELETE")
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) while deleting the collection")
        }
    }

    func addBooks(_ bookIds: [String], toCollection id: String) async throws {
        try await mutateCollectionBooks(bookIds, collectionId: id, method: "POST")
    }

    func removeBooks(_ bookIds: [String], fromCollection id: String) async throws {
        try await mutateCollectionBooks(bookIds, collectionId: id, method: "DELETE")
    }

    func reorderCollections(_ ids: [String]) async throws {
        try await requireAdmin()
        let order = ids.enumerated().compactMap { index, id -> [String: Int]? in
            guard let remoteId = Int(id) else { return nil }
            return ["id": remoteId, "displayOrder": index]
        }
        let body = try JSONSerialization.data(withJSONObject: ["order": order])
        let (_, http) = try await perform("collections/reorder", method: "POST", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) while reordering collections")
        }
    }

    private func collection(_ dto: CollectionDTO, editable: Bool) -> Collection {
        Collection(
            id: "bookorbit-\(connection.id.uuidString)-\(dto.id)",
            name: dto.name,
            description: dto.description,
            books: [],
            bookCount: dto.bookCount,
            iconName: "folder.fill",
            color: "orange",
            providerId: connection.id,
            remoteId: String(dto.id),
            serverIcon: dto.icon,
            syncToKobo: dto.syncToKobo,
            displayOrder: dto.displayOrder,
            isServerEditable: editable
        )
    }

    private func collectionBody(_ edit: CollectionEdit) throws -> Data {
        var body: [String: Any] = [
            "name": edit.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "icon": edit.icon,
            "syncToKobo": edit.syncToKobo,
        ]
        if let description = edit.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            body["description"] = description
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func mutateCollectionBooks(_ bookIds: [String], collectionId: String, method: String) async throws {
        try await requireAdmin()
        guard let remoteId = Int(collectionId) else { throw ProviderError.invalidURL }
        let ids = bookIds.compactMap(Int.init)
        guard !ids.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: ["bookIds": Array(Set(ids))])
        let (_, http) = try await perform("collections/\(remoteId)/books", method: method, body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) while changing collection membership")
        }
    }

    private func requireAdmin() async throws {
        guard try await currentUserIsAdmin(force: true) else {
            throw ProviderError.serverError("BookOrbit collection changes require an administrator account")
        }
    }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        let now = Date()
        if now.timeIntervalSince(cachedContinueProgressAt) < 20 {
            return cachedContinueProgress
        }

        let (data, http) = try await perform("dashboard/widgets/currently-reading")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("BookOrbit returned HTTP \(http.statusCode) for /api/v1/dashboard/widgets/currently-reading")
        }

        let widget = try Self.decoder.decode(CurrentlyReadingWidgetDTO.self, from: data)
        var entries: [UserMediaProgress] = []
        entries.reserveCapacity(widget.books.count)
        for (index, item) in widget.books.enumerated() {
            let uniqueId = "\(connection.id)_\(item.bookId)"
            let knownBook = AppState.shared.bookInMemory(uniqueId: uniqueId)
            let isAudiobook = isAudio(item.fileFormat) || knownBook?.mediaType == .audiobook
            let exact = await fetchCurrentProgress(for: item, isAudiobook: isAudiobook)
            let progress = min(max((exact?.percentage ?? item.progress ?? 0) / 100.0, 0), 1)
            guard progress > 0.001, progress < 0.999 else { continue }

            let duration = max(knownBook?.duration ?? 0, 0)
            let currentTime: TimeInterval = isAudiobook ? (duration > 0 ? duration * progress : 1) : 0
            let rankedFallback = now.addingTimeInterval(-TimeInterval(index))

            entries.append(
                UserMediaProgress(
                    id: "bookorbit-\(item.bookId)",
                    libraryItemId: String(item.bookId),
                    providerId: connection.id,
                    episodeId: nil,
                    currentTime: currentTime,
                    progress: progress,
                    isFinished: false,
                    duration: duration,
                    lastUpdate: exact?.updatedAt ?? knownBook?.lastUpdate ?? rankedFallback,
                    ebookProgress: isAudiobook ? nil : progress
                )
            )
        }

        cachedContinueProgress = entries
        cachedContinueProgressAt = now
        return entries
    }

    private func fetchCurrentProgress(
        for item: CurrentlyReadingBookDTO,
        isAudiobook: Bool
    ) async -> (percentage: Double?, updatedAt: Date?)? {
        if isAudiobook {
            guard let (data, http) = try? await perform("books/\(item.bookId)/audio-progress"),
                http.statusCode == 200,
                let progress = try? Self.decoder.decode(AudioProgressDTO.self, from: data)
            else {
                return nil
            }
            return (progress.percentage, progress.updatedAt)
        }

        guard let fileId = item.fileId,
            let (data, http) = try? await perform("books/files/\(fileId)/progress"),
            http.statusCode == 200,
            let progress = try? Self.decoder.decode(FileProgressDTO.self, from: data)
        else {
            return nil
        }
        return (progress.percentage, progress.updatedAt)
    }

    func fetchActivitySnapshot() async throws -> [ActivityRecord] {
        let libraries = try await fetchLibraries()
        let libraryIds: [String]
        if let selected = connection.selectedLibraryIds, !selected.isEmpty {
            libraryIds = libraries.map(\.id).filter { selected.contains($0) }
            guard !libraryIds.isEmpty else {
                throw ProviderError.serverError("BookOrbit selected libraries are unavailable")
            }
        } else {
            libraryIds = libraries.map(\.id)
        }

        var candidates: [ActivityCandidate] = []
        var seenBookIds = Set<Int>()
        let pageSize = 200
        let serverPageCeiling = 250

        for libraryId in libraryIds {
            guard let numericLibraryId = Int(libraryId) else {
                throw ProviderError.invalidURL
            }
            var page = 0
            var expectedTotal: Int?
            var libraryBookIds = Set<Int>()

            while true {
                let body = try JSONSerialization.data(withJSONObject: [
                    "filter": [
                        "type": "group",
                        "join": "AND",
                        "rules": [
                            [
                                "type": "rule",
                                "field": "readStatus",
                                "operator": "isNotEmpty",
                            ]
                        ],
                    ],
                    "pagination": ["page": page, "size": pageSize],
                ])
                let (data, http) = try await perform(
                    "libraries/\(numericLibraryId)/books",
                    method: "POST",
                    body: body
                )
                if http.statusCode == 400 {
                    throw ActivitySnapshotError.unsupported
                }
                guard (200...299).contains(http.statusCode) else {
                    throw ProviderError.serverError(
                        "BookOrbit returned HTTP \(http.statusCode) while fetching activity"
                    )
                }

                let response = try Self.decoder.decode(BooksPageDTO.self, from: data)
                if let expectedTotal, expectedTotal != response.total {
                    throw ProviderError.serverError("BookOrbit activity changed during refresh")
                }
                expectedTotal = response.total

                let missingStatusCount = response.items.filter { $0.readStatus?.status == nil }.count
                if missingStatusCount == response.items.count, !response.items.isEmpty, page == 0 {
                    throw ActivitySnapshotError.unsupported
                }
                guard missingStatusCount == 0 else {
                    throw ProviderError.serverError("BookOrbit returned an incomplete activity snapshot")
                }

                for card in response.items {
                    guard libraryBookIds.insert(card.id).inserted,
                        let rawStatus = card.readStatus?.status,
                        let status = BookOrbitReadStatus(rawValue: rawStatus)
                    else {
                        throw ProviderError.serverError("BookOrbit returned inconsistent activity rows")
                    }
                    guard seenBookIds.insert(card.id).inserted else { continue }
                    candidates.append(
                        ActivityCandidate(
                            card: card,
                            status: status,
                            statusUpdatedAt: card.readStatus?.updatedAt ?? .distantPast
                        )
                    )
                }

                if libraryBookIds.count == response.total { break }
                guard !response.items.isEmpty, page < serverPageCeiling else {
                    throw ProviderError.serverError("BookOrbit activity snapshot exceeded the server page limit")
                }
                page += 1
            }
        }

        return try await mapConcurrently(candidates) { candidate in
            let exact = try await self.fetchActivityProgress(for: candidate)
            let fallback = Book.normalizedFractionProgress(candidate.card.readingProgress) ?? 0
            let progress = exact?.progress ?? fallback
            return ActivityRecord(
                bookId: String(candidate.card.id),
                status: candidate.status,
                progress: progress,
                epubCFI: exact?.cfi,
                updatedAt: max(candidate.statusUpdatedAt, exact?.updatedAt ?? .distantPast),
                rating: candidate.card.rating
            )
        }
    }

    private func fetchActivityProgress(
        for candidate: ActivityCandidate
    ) async throws -> (progress: Double, cfi: String?, updatedAt: Date?)? {
        switch candidate.status {
        case .reading, .rereading, .onHold, .abandoned:
            break
        case .unread, .wantToRead, .read, .skimmed:
            return nil
        }

        let files = candidate.card.files ?? []
        if files.contains(where: { isAudio($0.format) }) {
            let (data, http) = try await perform("books/\(candidate.card.id)/audio-progress")
            guard http.statusCode == 200 else {
                throw ProviderError.serverError(
                    "BookOrbit returned HTTP \(http.statusCode) for audiobook activity"
                )
            }
            let progress = try Self.decoder.decode(AudioProgressDTO?.self, from: data)
            guard let progress else { return nil }
            return (
                Book.normalizedFractionProgress(progress.percentage) ?? 0,
                nil,
                progress.updatedAt
            )
        }

        guard let file = files.first(where: { $0.role?.lowercased() == "primary" }) ?? files.first else {
            return nil
        }
        let (data, http) = try await perform("books/files/\(file.id)/progress")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError(
                "BookOrbit returned HTTP \(http.statusCode) for ebook activity"
            )
        }
        let progress = try Self.decoder.decode(FileProgressDTO.self, from: data)
        return (
            Book.normalizedFractionProgress(progress.percentage) ?? 0,
            progress.cfi,
            progress.updatedAt
        )
    }

    private func mapConcurrently<Input: Sendable, Output: Sendable>(
        _ values: [Input],
        limit: Int = 6,
        transform: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !values.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            while nextIndex < min(limit, values.count) {
                let index = nextIndex
                group.addTask { (index, try await transform(values[index])) }
                nextIndex += 1
            }

            var results: [(Int, Output)] = []
            results.reserveCapacity(values.count)
            while let result = try await group.next() {
                results.append(result)
                if nextIndex < values.count {
                    let index = nextIndex
                    group.addTask { (index, try await transform(values[index])) }
                    nextIndex += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let idInt = Int(bookId) else { throw ProviderError.invalidURL }
        let (data, http) = try await perform("books/\(idInt)")
        guard http.statusCode == 200 else { throw ProviderError.invalidResponse }
        let detail = try Self.decoder.decode(BookDetailDTO.self, from: data)
        return detailBook(detail, fallbackLibraryId: libraryId)
    }

    private func isAudio(_ format: String?) -> Bool {
        guard let f = format?.lowercased() else { return false }
        return ["m4b", "mp3", "m4a", "opus", "ogg", "flac"].contains(f)
    }

    private func card(_ dto: BookCardDTO, libraryId: String) -> Book {
        let files = dto.files ?? []
        let audioFiles = files.filter { isAudio($0.format) }
        let isAudiobook = !audioFiles.isEmpty
        let primaryFile =
            isAudiobook
            ? (audioFiles.first(where: { $0.role?.lowercased() == "content" }) ?? audioFiles.first)
            : (files.first(where: { $0.role?.lowercased() == "primary" }) ?? files.first)
        let coverURL = (dto.hasCover == true) ? coverURLString(bookId: dto.id).flatMap { URL(string: $0) } : nil

        let tracks: [AudioTrack]? = isAudiobook ? buildTracks(from: audioFiles, durations: false) : nil

        var book = Book(
            id: String(dto.id),
            title: dto.title ?? "Untitled",
            author: dto.authors?.joined(separator: ", "),
            narrator: dto.narrators?.joined(separator: ", "),
            seriesInfo: dto.seriesName.map { SeriesInfo(name: $0, sequence: dto.seriesIndex.map(Self.sequenceString)) },
            duration: nil,
            coverURL: coverURL,
            partKey: String(dto.id),
            audioFileIno: primaryFile.map { String($0.id) },
            audioFileInos: audioFiles.isEmpty ? nil : audioFiles.map { String($0.id) },
            audioTracks: tracks,
            dateAdded: dto.addedAt,
            description: nil,
            genres: dto.genres,
            publisher: dto.publisher,
            libraryId: libraryId,
            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .bookOrbit,
            publishedYear: dto.publishedYear,
            personalRating: dto.rating,
            language: dto.language
        )
        book.mediaType = isAudiobook ? .audiobook : .ebook
        if let rawStatus = dto.readStatus?.status,
            let status = BookOrbitReadStatus(rawValue: rawStatus)
        {
            let progress = Book.normalizedFractionProgress(dto.readingProgress) ?? 0
            book.serverReadStatus = status.rawValue.uppercased()
            book.isFinished = status == .read || status == .skimmed
            book.hideFromContinue = ![.unread, .reading, .rereading].contains(status)
            if !isAudiobook {
                book.ebookProgress = book.isFinished ? 1 : progress
            }
            if let updatedAt = dto.readStatus?.updatedAt {
                book.lastUpdate = updatedAt
            }
        }
        return book
    }

    private func detailBook(_ dto: BookDetailDTO, fallbackLibraryId: String) -> Book {
        let files = dto.files ?? []
        let audioFiles = files.filter { isAudio($0.format) }
        let isAudiobook = !audioFiles.isEmpty
        let primaryFile =
            isAudiobook
            ? (audioFiles.first(where: { $0.role?.lowercased() == "content" }) ?? audioFiles.first)
            : (files.first(where: { $0.role?.lowercased() == "primary" }) ?? files.first)
        let coverURL = (dto.hasCover == true || dto.coverSource != nil) ? coverURLString(bookId: dto.id).flatMap { URL(string: $0) } : nil

        let tracks = isAudiobook ? buildTracks(from: audioFiles, durations: true) : nil
        let totalDuration =
            dto.audioMetadata?.durationSeconds
            ?? (audioFiles.compactMap { $0.durationSeconds }.reduce(0, +))
        let chapters = makeChapters(dto.audioMetadata?.chapters, totalDuration: totalDuration)
        let narrator = dto.audioMetadata?.narrators?.map { $0.name }.joined(separator: ", ")

        var book = Book(
            id: String(dto.id),
            title: dto.title ?? "Untitled",
            author: dto.authors?.map { $0.name }.joined(separator: ", "),
            narrator: narrator,
            seriesInfo: dto.seriesName.map { SeriesInfo(name: $0, sequence: dto.seriesIndex.map(Self.sequenceString)) },
            duration: isAudiobook ? totalDuration : nil,
            coverURL: coverURL,
            partKey: String(dto.id),
            audioFileIno: primaryFile.map { String($0.id) },
            audioFileInos: audioFiles.isEmpty ? nil : audioFiles.map { String($0.id) },
            audioTracks: tracks,
            dateAdded: dto.addedAt,
            description: dto.description,
            genres: dto.genres,
            chapters: chapters,
            publisher: dto.publisher,
            libraryId: dto.libraryId.map(String.init) ?? fallbackLibraryId,
            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .bookOrbit,
            publishedYear: dto.publishedYear,
            personalRating: dto.rating,
            language: dto.language
        )
        book.mediaType = isAudiobook ? .audiobook : .ebook
        if let rawStatus = dto.readStatus?.status,
            let status = BookOrbitReadStatus(rawValue: rawStatus)
        {
            book.serverReadStatus = status.rawValue.uppercased()
            book.isFinished = status == .read || status == .skimmed
            book.hideFromContinue = ![.unread, .reading, .rereading].contains(status)
            if let updatedAt = dto.readStatus?.updatedAt {
                book.lastUpdate = updatedAt
            }
        }
        return book
    }

    private func buildTracks(from files: [FileDTO], durations: Bool) -> [AudioTrack] {
        var tracks: [AudioTrack] = []
        var offset: TimeInterval = 0
        let headers = getStreamingHeaders()
        for (index, file) in files.enumerated() {
            let dur = durations ? (file.durationSeconds ?? 0) : 0
            tracks.append(
                AudioTrack(
                    index: index,
                    title: file.filename,
                    filePath: String(file.id),
                    contentUrl: serveURL(fileId: file.id)?.absoluteString,
                    duration: dur,
                    startOffset: offset,
                    format: file.format,
                    headers: headers
                )
            )
            offset += dur
        }
        return tracks
    }

    private func makeChapters(_ chapters: [ChapterDTO]?, totalDuration: TimeInterval) -> [Chapter]? {
        guard let chapters, !chapters.isEmpty else { return nil }
        let sorted = chapters.sorted { $0.startMs < $1.startMs }
        return sorted.enumerated().map { index, ch in
            let start = ch.startMs / 1000.0
            let end = index + 1 < sorted.count ? sorted[index + 1].startMs / 1000.0 : max(start, totalDuration)
            return Chapter(id: String(index), start: start, end: end, title: ch.title, index: index)
        }
    }

    private static func sequenceString(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    func getAudioURL(for book: Book) -> URL? {
        if let contentUrl = book.audioTracks?.first?.contentUrl, let url = URL(string: contentUrl) {
            return url
        }
        if let ino = book.audioFileIno, let fileId = Int(ino) {
            return serveURL(fileId: fileId)
        }
        return nil
    }

    func getStreamingHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let custom = connection.customHeaders { for (k, v) in custom { headers[k] = v } }
        if let token = connection.token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        try await ensureValidToken()
        let detailed = (try? await fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)) ?? book
        let tracks = detailed.audioTracks ?? []
        guard !tracks.isEmpty else { throw ProviderError.invalidResponse }

        let headers = getStreamingHeaders()
        var infos: [AudioTrackInfo] = []
        var offset: Double = 0
        for (index, track) in tracks.enumerated() {
            guard let contentUrl = track.contentUrl else { continue }
            var duration = track.duration
            if duration <= 0, let url = URL(string: contentUrl) {
                duration = await resolveDuration(url: url, headers: headers)
            }
            infos.append(
                AudioTrackInfo(
                    index: index,
                    startOffset: offset,
                    duration: duration,
                    contentUrl: contentUrl,
                    mimeType: Self.mimeType(forFormat: track.format),
                    title: track.title
                )
            )
            offset += duration
        }

        let chapters =
            detailed.chapters
            ?? infos.map {
                Chapter(
                    id: String($0.index),
                    start: $0.startOffset,
                    end: $0.startOffset + $0.duration,
                    title: $0.title ?? "Track \($0.index + 1)",
                    index: $0.index
                )
            }
        return PlaybackSessionInfo(sessionId: "bookorbit:\(book.id)", audioTracks: infos, chapters: chapters)
    }

    private func resolveDuration(url: URL, headers: [String: String]) async -> Double {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private static func mimeType(forFormat format: String?) -> String {
        switch format?.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4b", "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        default: return "audio/mpeg"
        }
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard let bookId = Int(book.id) else { return }

        let (fileId, localPosition) = currentFileAndOffset(book: book, globalPosition: currentTime)
        guard let fileId else {
            AppLogger.sync.debug(
                "[BookOrbit] No file to attribute progress bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); skipping"
            )
            return
        }

        let duration = book.duration ?? 0
        var percentage = duration > 0 ? (currentTime / duration) * 100 : (isFinished ? 100 : 0)
        if isFinished { percentage = 100 }
        percentage = min(max(percentage, 0), 100)

        let body = try JSONSerialization.data(withJSONObject: [
            "percentage": percentage,
            "currentFileId": fileId,
            "positionSeconds": max(0, localPosition),
        ])
        let (_, http) = try await perform("books/\(bookId)/audio-progress", method: "PATCH", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to sync audio progress (HTTP \(http.statusCode))")
        }
        invalidateContinueCache()
    }

    func uploadHistorySession(_ session: HistorySession, for book: Book) async throws {
        guard session.source == .local, session.durationSeconds >= 10 else { return }
        let detailed = (try? await fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)) ?? book
        guard let fileId = historySessionFileId(for: session, book: detailed) else {
            throw ProviderError.invalidResponse
        }

        let wallClockSeconds = max(0, Int(session.endTime.timeIntervalSince(session.startTime)))
        let durationSeconds = min(session.durationSeconds, wallClockSeconds)
        guard durationSeconds >= 10 else { return }

        var payload: [String: Any] = [
            "sessionId": String("enve-\(session.id)".prefix(64)),
            "startedAt": Self.sessionDateFormatter.string(from: session.startTime),
            "endedAt": Self.sessionDateFormatter.string(from: session.endTime),
            "durationSeconds": durationSeconds,
        ]
        if let progressDelta = session.progressDelta {
            payload["progressDelta"] = min(max(progressDelta * 100, -100), 100)
        }
        if let endProgress = session.endProgress {
            payload["endProgress"] = min(max(endProgress * 100, 0), 100)
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, http) = try await perform("books/files/\(fileId)/sessions", method: "POST", body: body)
        guard http.statusCode == 204 else {
            throw ProviderError.serverError("Failed to sync BookOrbit reading session (HTTP \(http.statusCode))")
        }
    }

    func fetchReadingSessions(for book: Book) async throws -> [ReadingSessionRecord] {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        var records: [ReadingSessionRecord] = []
        var page = 1

        while true {
            let (data, http) = try await perform(
                "books/\(bookId)/sessions",
                query: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "pageSize", value: "100"),
                    URLQueryItem(name: "sortBy", value: "startedAt"),
                    URLQueryItem(name: "sortDir", value: "desc"),
                ]
            )
            guard http.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch BookOrbit reading sessions (HTTP \(http.statusCode))")
            }
            let response = try Self.decoder.decode(ReadingSessionsPageDTO.self, from: data)
            records.append(
                contentsOf: response.items.map {
                    ReadingSessionRecord(
                        id: $0.id,
                        startedAt: $0.startedAt,
                        endedAt: $0.endedAt,
                        durationSeconds: $0.durationSeconds,
                        progressDelta: $0.progressDelta,
                        endProgress: $0.endProgress
                    )
                }
            )
            guard records.count < response.total, !response.items.isEmpty else { break }
            page += 1
        }
        return records
    }

    func fetchReaderBookmarks(for book: Book) async throws -> [ReaderBookmarkRecord] {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let (data, http) = try await perform("books/\(bookId)/bookmarks")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch BookOrbit bookmarks (HTTP \(http.statusCode))")
        }
        return try Self.decoder.decode([ReaderBookmarkDTO].self, from: data).map(Self.readerBookmarkRecord)
    }

    func createReaderBookmark(for book: Book, bookmark: Bookmark) async throws -> ReaderBookmarkRecord {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        var payload: [String: Any] = ["title": String(bookmark.title.prefix(500))]
        if bookmark.mediaType == .audiobook {
            payload["positionSeconds"] = max(0, bookmark.position)
        } else if let cfi = Self.extractCFI(from: bookmark.locator) {
            payload["cfi"] = cfi
        } else {
            throw ProviderError.noCFI
        }
        let (data, http) = try await perform(
            "books/\(bookId)/bookmarks",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: payload)
        )
        guard (200...201).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to create BookOrbit bookmark (HTTP \(http.statusCode))")
        }
        return Self.readerBookmarkRecord(try Self.decoder.decode(ReaderBookmarkDTO.self, from: data))
    }

    func replaceReaderBookmark(for book: Book, bookmark: Bookmark, remoteId: Int) async throws -> ReaderBookmarkRecord {
        try await deleteReaderBookmark(for: book, remoteId: remoteId)
        return try await createReaderBookmark(for: book, bookmark: bookmark)
    }

    func deleteReaderBookmark(for book: Book, remoteId: Int) async throws {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let (_, http) = try await perform("books/\(bookId)/bookmarks/\(remoteId)", method: "DELETE")
        guard http.statusCode == 204 || http.statusCode == 404 else {
            throw ProviderError.serverError("Failed to delete BookOrbit bookmark (HTTP \(http.statusCode))")
        }
    }

    func fetchReaderAnnotations(for book: Book) async throws -> [ReaderAnnotationRecord] {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let (data, http) = try await perform("books/\(bookId)/annotations")
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch BookOrbit annotations (HTTP \(http.statusCode))")
        }
        return try Self.decoder.decode([ReaderAnnotationDTO].self, from: data).map(Self.readerAnnotationRecord)
    }

    func createReaderAnnotation(for book: Book, annotation: ReaderAnnotation) async throws -> ReaderAnnotationRecord {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        guard let cfi = Self.extractCFI(from: annotation.locator) else { throw ProviderError.noCFI }
        var payload: [String: Any] = [
            "cfi": cfi,
            "text": annotation.text,
            "color": String(annotation.colorHex.prefix(20)),
            "style": annotation.style.rawValue,
        ]
        if let note = annotation.note { payload["note"] = note }
        if let chapterTitle = annotation.chapterTitle {
            payload["chapterTitle"] = String(chapterTitle.prefix(500))
        }
        let (data, http) = try await perform(
            "books/\(bookId)/annotations",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: payload)
        )
        guard (200...201).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to create BookOrbit annotation (HTTP \(http.statusCode))")
        }
        return Self.readerAnnotationRecord(try Self.decoder.decode(ReaderAnnotationDTO.self, from: data))
    }

    func updateReaderAnnotation(for book: Book, annotation: ReaderAnnotation, remoteId: Int) async throws -> ReaderAnnotationRecord {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let payload: [String: Any] = [
            "note": annotation.note ?? NSNull(),
            "color": String(annotation.colorHex.prefix(20)),
            "style": annotation.style.rawValue,
        ]
        let (data, http) = try await perform(
            "books/\(bookId)/annotations/\(remoteId)",
            method: "PATCH",
            body: try JSONSerialization.data(withJSONObject: payload)
        )
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("Failed to update BookOrbit annotation (HTTP \(http.statusCode))")
        }
        return Self.readerAnnotationRecord(try Self.decoder.decode(ReaderAnnotationDTO.self, from: data))
    }

    func deleteReaderAnnotation(for book: Book, remoteId: Int) async throws {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let (_, http) = try await perform("books/\(bookId)/annotations/\(remoteId)", method: "DELETE")
        guard http.statusCode == 204 || http.statusCode == 404 else {
            throw ProviderError.serverError("Failed to delete BookOrbit annotation (HTTP \(http.statusCode))")
        }
    }

    private func historySessionFileId(for session: HistorySession, book: Book) -> Int? {
        guard book.mediaType == .audiobook,
            let endProgress = session.endProgress,
            let duration = book.duration,
            duration > 0
        else {
            return book.audioFileIno.flatMap(Int.init)
        }
        return currentFileAndOffset(book: book, globalPosition: duration * endProgress).fileId
            ?? book.audioFileIno.flatMap(Int.init)
    }

    private static func readerBookmarkRecord(_ dto: ReaderBookmarkDTO) -> ReaderBookmarkRecord {
        ReaderBookmarkRecord(
            id: dto.id,
            cfi: dto.cfi,
            title: dto.title,
            positionSeconds: dto.positionSeconds,
            createdAt: dto.createdAt
        )
    }

    private static func readerAnnotationRecord(_ dto: ReaderAnnotationDTO) -> ReaderAnnotationRecord {
        ReaderAnnotationRecord(
            id: dto.id,
            cfi: dto.cfi,
            text: dto.text,
            color: dto.color,
            style: dto.style,
            note: dto.note,
            chapterTitle: dto.chapterTitle,
            createdAt: dto.createdAt
        )
    }

    private static func extractCFI(from locator: String?) -> String? {
        guard let locator, !locator.isEmpty else { return nil }
        if locator.hasPrefix("epubcfi(") { return locator }
        guard let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = json["locations"] as? [String: Any]
        else {
            return nil
        }
        if let fragments = locations["fragments"] as? [String],
            let cfi = fragments.first(where: { $0.hasPrefix("epubcfi(") })
        {
            return cfi
        }
        if let cfi = locations["cfi"] as? String, cfi.hasPrefix("epubcfi(") {
            return cfi
        }
        return nil
    }

    func updateReadStatus(for book: Book, status: BookOrbitReadStatus) async throws {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let body = try JSONSerialization.data(withJSONObject: ["status": status.rawValue])
        let (_, http) = try await perform("books/\(bookId)/status", method: "PATCH", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to update BookOrbit read status (HTTP \(http.statusCode))")
        }
        invalidateContinueCache()
    }

    func updatePersonalRating(for book: Book, rating: Int) async throws {
        guard let bookId = Int(book.id) else { throw ProviderError.invalidURL }
        let body = try JSONSerialization.data(withJSONObject: [
            "rating": min(max(rating, 1), 5)
        ])
        let (_, http) = try await perform("books/\(bookId)/metadata", method: "PATCH", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to update BookOrbit rating (HTTP \(http.statusCode))")
        }
    }

    func fetchReadStatus(for book: Book) async -> BookOrbitReadStatus? {
        guard let idInt = Int(book.id),
            let (data, http) = try? await perform("books/\(idInt)"),
            http.statusCode == 200,
            let detail = try? Self.decoder.decode(BookDetailDTO.self, from: data),
            let raw = detail.readStatus?.status
        else { return nil }
        return BookOrbitReadStatus(rawValue: raw)
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let bookId = Int(book.id) else { return nil }
        guard let (data, http) = try? await perform("books/\(bookId)/audio-progress"),
            http.statusCode == 200, !data.isEmpty,
            let dto = try? Self.decoder.decode(AudioProgressDTO.self, from: data),
            let fileId = dto.currentFileId
        else {
            return nil
        }

        let local = dto.positionSeconds ?? 0
        let tracks = await tracksForOffsetMapping(book: book)
        let track = tracks.first { Int($0.filePath ?? "") == fileId }
        let global = (track?.startOffset ?? 0) + local
        let percentage = (dto.percentage ?? 0) / 100.0
        return (
            positionSeconds: global, percentage: percentage, trackIndex: track?.index,
            updatedAt: dto.updatedAt, isAbandoned: percentage >= 0.99
        )
    }

    private func currentFileAndOffset(book: Book, globalPosition: TimeInterval) -> (fileId: Int?, offset: TimeInterval) {
        if let tracks = book.audioTracks, !tracks.isEmpty {
            let track = tracks.last { $0.startOffset <= globalPosition } ?? tracks.first
            let fileId = track.flatMap { Int($0.filePath ?? "") }
            let offset = globalPosition - (track?.startOffset ?? 0)
            return (fileId, offset)
        }
        if let ino = book.audioFileIno, let fileId = Int(ino) {
            return (fileId, globalPosition)
        }
        return (nil, globalPosition)
    }

    private func tracksForOffsetMapping(book: Book) async -> [AudioTrack] {
        if let tracks = book.audioTracks, !tracks.isEmpty { return tracks }
        let detailed = try? await fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
        return detailed?.audioTracks ?? []
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }
        try await ensureValidToken()
        guard let ino = book.audioFileIno, let fileId = Int(ino),
            let url = apiBase?.appendingPathComponent("books/files/\(fileId)/download"),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        applyCustomHeaders(&request)

        onProgress?(0)
        let tempURL: URL
        let http: HTTPURLResponse
        if let onProgress {

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            (tempURL, http) = try await delegate.awaitResult {
                session.downloadTask(with: request)
            }
        } else {
            let (downloadURL, response) = try await URLSession.shared.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: downloadURL)
                throw ProviderError.invalidResponse
            }
            tempURL = downloadURL
            http = httpResponse
        }
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProviderError.invalidResponse
        }
        onProgress?(1)

        var filename = "\(book.title.replacingOccurrences(of: "/", with: "-")).epub"
        if let header = http.allHeaderFields["Content-Disposition"] as? String,
            let range = header.range(of: "filename=\"") ?? header.range(of: "filename=")
        {
            let start = range.upperBound
            let end = header[start...].firstIndex(of: "\"") ?? header.endIndex
            filename = String(header[start..<end])
        }

        return try LocalEbookImporter.shared.cacheRemoteEbook(tempURL: tempURL, preferredFilename: filename, bookIdentifier: book.id)
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        guard let ino = book.audioFileIno, let fileId = Int(ino) else { throw ProviderError.unauthorized }
        var payload: [String: Any] = ["percentage": min(max(progress * 100, 0), 100)]
        if let cfi = EpubLocationBridge.epubCFI(from: epubLocator) { payload["cfi"] = cfi }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, http) = try await perform("books/files/\(fileId)/progress", method: "POST", body: body)
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to sync ebook progress (HTTP \(http.statusCode))")
        }
        invalidateContinueCache()
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let ino = book.audioFileIno, let fileId = Int(ino) else { return nil }
        guard let (data, http) = try? await perform("books/files/\(fileId)/progress"),
            http.statusCode == 200,
            let dto = try? Self.decoder.decode(FileProgressDTO.self, from: data)
        else {
            return nil
        }
        let progress = (dto.percentage ?? 0) / 100.0
        return (progress: progress, locator: dto.cfi, updatedAt: dto.updatedAt, isAbandoned: progress >= 0.99)
    }

    private static let sessionDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
