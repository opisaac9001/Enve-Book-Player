import Combine
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

enum AudiobookshelfError: LocalizedError {
    case invalidURL
    case invalidToken
    case serverUnreachable
    case networkError(Error)
    case decodingError(Error)
    case authenticationFailed
    case authenticationFailedDetailed(String)
    case invalidBackend
    case unauthorized
    case notFound
    case serverError(Int)
    case uploadFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Audiobookshelf URL"
        case .invalidToken:
            return "Invalid Audiobookshelf authentication token"
        case .serverUnreachable:
            return "Cannot reach Audiobookshelf server"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .authenticationFailed:
            return "Audiobookshelf authentication failed"
        case .authenticationFailedDetailed(let details):
            return "Audiobookshelf authentication failed: \(details)"
        case .invalidBackend:
            return "Invalid backend configuration"
        case .unauthorized:
            return "Unauthorized - please check your credentials"
        case .notFound:
            return "Resource not found"
        case .serverError(let code):
            return "Server error (HTTP \(code))"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}

public final class AudiobookshelfService: @unchecked Sendable {
    public static let shared = AudiobookshelfService()

    private let session: URLSession
    private let verboseABSNetworkLogs = false

    private func debugABSLog(_ message: String) {
        #if DEBUG
        guard verboseABSNetworkLogs else { return }
        AppLogger.network.debug("\(message)")
        #endif
    }

    private func decodeABS<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            let detail: String
            switch error {
            case let .keyNotFound(key, ctx):
                detail = "missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            case let .typeMismatch(_, ctx):
                detail = "type mismatch at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            case let .valueNotFound(_, ctx):
                detail = "null value at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            case let .dataCorrupted(ctx):
                detail = "corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            @unknown default:
                detail = error.localizedDescription
            }
            AppLogger.player.error("[ABS] Decode \(context) failed: \(detail)")
            throw error
        }
    }
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private static let persistedDeviceId: String = {
        let key = "absDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }()

    private var deviceInfo: ABSDeviceInfo {
        var model = "Apple"
        var deviceName = "Apple Device"
        #if canImport(UIKit)
        model = UIDevice.current.model
        deviceName = UIDevice.current.name
        #endif
        return ABSDeviceInfo(
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            manufacturer: "Apple",
            model: model,
            sdkVersion: nil,
            clientName: "Enve",
            deviceId: Self.persistedDeviceId,
            deviceName: deviceName
        )
    }

    public init(session: URLSession? = nil) {
        if let providedSession = session {
            self.session = providedSession
        } else {
            self.session = InsecureURLSession.shared
        }
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private func createRequest(url: URL, method: String = "GET", backend: BackendConfig) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if method.uppercased() == "GET" {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }

        if let customHeaders = backend.customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let token = backend.token, !token.isEmpty {
            if token.hasPrefix("Bearer ") {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            } else if token.contains(".") {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }

        } else {
            AppLogger.player.warning(
                "No token found for endpointDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: url.path))"
            )
        }

        return request
    }

    private func buildURL(backend: BackendConfig, path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        guard let baseURL = backend.baseURL else {
            throw AudiobookshelfError.invalidBackend
        }

        debugABSLog(" [ABS] Building URL: base=\(baseURL.redacted), path=\(path)")

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        let basePath = baseURL.path == "/" ? "" : baseURL.path
        let trimmedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        components?.path = trimmedBasePath + normalizedPath
        components?.queryItems = queryItems?.isEmpty == true ? nil : queryItems

        guard let url = components?.url else {
            throw AudiobookshelfError.invalidURL
        }

        debugABSLog(" [ABS] Final URL: \(url.redacted)")

        return url
    }

    private func handleResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AudiobookshelfError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            AppLogger.player.debug(
                "HTTP status=\(httpResponse.statusCode) endpointDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: httpResponse.url?.path ?? "unknown"))"
            )
            AppLogger.player.info("Response body size: \(data.count) bytes")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw AudiobookshelfError.unauthorized
        case 404:
            throw AudiobookshelfError.notFound
        case 500...599:
            throw AudiobookshelfError.serverError(httpResponse.statusCode)
        default:
            throw AudiobookshelfError.serverUnreachable
        }
    }

    func login(username: String, password: String, serverURL: String) async throws -> ABSUser {
        guard let baseURL = URL(string: serverURL) else {
            throw AudiobookshelfError.invalidURL
        }

        let url = baseURL.appendingPathComponent("login")
        guard let finalURL = URL(string: url.absoluteString) else {
            throw AudiobookshelfError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")

        let loginRequest = ABSLoginRequest(username: username, password: password)
        request.httpBody = try encoder.encode(loginRequest)

        do {
            let (data, response) = try await session.data(for: request)
            try handleResponse(response, data: data)

            let loginResponse = try decoder.decode(ABSLoginResponse.self, from: data)

            var user = loginResponse.user
            if let rootToken = loginResponse.token, !rootToken.isEmpty {
                if user.token == nil || user.token?.isEmpty == true {
                    user = ABSUser(
                        id: user.id,
                        username: user.username,
                        type: user.type,
                        token: rootToken,
                        accessToken: user.accessToken ?? rootToken,
                        refreshToken: user.refreshToken,
                        isActive: user.isActive,
                        isLocked: user.isLocked,
                        permissions: user.permissions,
                        librariesAccessible: user.librariesAccessible,
                        mediaProgress: user.mediaProgress,
                        bookmarks: user.bookmarks
                    )
                }
            }

            return user
        } catch is DecodingError {
            throw AudiobookshelfError.authenticationFailed
        } catch let error as AudiobookshelfError {
            throw error
        } catch {
            throw AudiobookshelfError.networkError(error)
        }
    }

    func login(username: String, password: String, serverURL: String, customHeaders: [String: String]) async throws -> ABSUser {
        guard let baseURL = URL(string: serverURL) else {
            throw AudiobookshelfError.invalidURL
        }

        let url = baseURL.appendingPathComponent("login")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let loginRequest = ABSLoginRequest(username: username, password: password)
        request.httpBody = try encoder.encode(loginRequest)

        do {
            let (data, response) = try await session.data(for: request)
            try handleResponse(response, data: data)

            let loginResponse = try decoder.decode(ABSLoginResponse.self, from: data)
            var user = loginResponse.user
            if let rootToken = loginResponse.token, !rootToken.isEmpty {
                if user.token == nil || user.token?.isEmpty == true {
                    user = ABSUser(
                        id: user.id,
                        username: user.username,
                        type: user.type,
                        token: rootToken,
                        accessToken: user.accessToken ?? rootToken,
                        refreshToken: user.refreshToken,
                        isActive: user.isActive,
                        isLocked: user.isLocked,
                        permissions: user.permissions,
                        librariesAccessible: user.librariesAccessible,
                        mediaProgress: user.mediaProgress,
                        bookmarks: user.bookmarks
                    )
                }
            }
            return user
        } catch is DecodingError {
            throw AudiobookshelfError.authenticationFailed
        } catch let error as AudiobookshelfError {
            throw error
        } catch {
            throw AudiobookshelfError.networkError(error)
        }
    }

    struct OIDCPreflightResult {
        let authorizationURL: URL
        let cookies: [HTTPCookie]
    }

    func preflightOIDC(
        serverURL: String,
        challenge: String,
        redirectURI: String,
        state: String,
        customHeaders: [String: String] = [:]
    ) async throws -> OIDCPreflightResult {
        guard var components = URLComponents(string: "\(serverURL)/auth/openid") else {
            throw AudiobookshelfError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "callback", value: redirectURI),
            URLQueryItem(name: "client_id", value: "Enve-App"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw AudiobookshelfError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let config = URLSessionConfiguration.ephemeral
        let noRedirectSession = URLSession(
            configuration: config,
            delegate: OIDCNoRedirectDelegate.shared,
            delegateQueue: nil
        )

        let (data, response) = try await noRedirectSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AudiobookshelfError.invalidResponse
        }

        if http.statusCode == 302,
            let locationString = http.value(forHTTPHeaderField: "Location"),
            let redirectURL = URL(string: locationString)
        {
            let cookies = HTTPCookie.cookies(
                withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:],
                for: url
            )
            AppLogger.player.info("Pre-flight captured \(cookies.count) cookies, redirect -> \(redirectURL.host ?? "")")
            return OIDCPreflightResult(authorizationURL: redirectURL, cookies: cookies)
        }

        if http.statusCode == 400, let body = String(data: data, encoding: .utf8), !body.isEmpty {
            if body.trimmingCharacters(in: .whitespacesAndNewlines) == "Invalid redirect_uri" {
                throw AudiobookshelfError.authenticationFailedDetailed(
                    "Invalid redirect_uri. Add \(AppAuthRedirectURI.audiobookshelf) to your Audiobookshelf server's Allowed Mobile Redirect URIs (Settings > Authentication > OpenID Connect)."
                )
            }
            throw AudiobookshelfError.authenticationFailedDetailed(body)
        }

        throw AudiobookshelfError.authenticationFailedDetailed(
            "Unexpected pre-flight response: HTTP \(http.statusCode)"
        )
    }

    func loginWithOIDC(
        serverURL: String,
        code: String,
        verifier: String,
        state: String?,
        cookies: [HTTPCookie] = [],
        customHeaders: [String: String] = [:]
    ) async throws -> ABSUser {
        guard var components = URLComponents(string: "\(serverURL)/auth/openid/callback") else {
            throw AudiobookshelfError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        if let state, !state.isEmpty {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AudiobookshelfError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")

        if !cookies.isEmpty {
            let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        AppLogger.player.info("Exchanging code at: \(url.redacted)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudiobookshelfError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if let errorBody, !errorBody.isEmpty {
                if errorBody == "No session" {
                    detail = "HTTP \(http.statusCode): No session. The OIDC pre-flight cookies were not forwarded."
                } else {
                    detail = "HTTP \(http.statusCode): \(errorBody)"
                }
            } else {
                detail = "HTTP \(http.statusCode)"
            }
            throw AudiobookshelfError.authenticationFailedDetailed(detail)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userDict = json?["user"] as? [String: Any]
        let accessToken = userDict?["accessToken"] as? String
        let refreshToken = userDict?["refreshToken"] as? String
        let legacyToken = userDict?["token"] as? String
        let rootToken = json?["token"] as? String
        guard let resolvedToken = accessToken ?? legacyToken ?? rootToken, !resolvedToken.isEmpty else {
            let message =
                (json?["error"] as? String)
                ?? (json?["message"] as? String)
                ?? "Missing access token in callback response"
            throw AudiobookshelfError.authenticationFailedDetailed(message)
        }

        let userId = userDict?["id"] as? String ?? ""
        let foundUsername = userDict?["username"] as? String ?? ""
        let userType = userDict?["type"] as? String ?? "user"

        AppLogger.player.debug(
            "Token exchange successful - userId=\(DiagnosticLogSanitizer.identifier(for: foundUsername))"
        )

        return ABSUser(
            id: userId,
            username: foundUsername,
            type: userType,
            token: resolvedToken,
            accessToken: resolvedToken,
            refreshToken: refreshToken,
            isActive: true,
            isLocked: false,
            permissions: nil,
            librariesAccessible: nil,
            mediaProgress: nil,
            bookmarks: nil
        )
    }

    private final class OIDCNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        static let shared = OIDCNoRedirectDelegate()
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func getServerInfo(
        serverURL: String,
        preventAutoLogin: Bool = false,
        customHeaders: [String: String] = [:]
    ) async throws -> ABSServerInfo {
        guard let baseURL = URL(string: serverURL) else {
            throw AudiobookshelfError.invalidURL
        }

        guard var components = URLComponents(url: baseURL.appendingPathComponent("status"), resolvingAgainstBaseURL: false) else {
            throw AudiobookshelfError.invalidURL
        }

        if preventAutoLogin {
            components.queryItems = [URLQueryItem(name: "preventAutoLogin", value: "1")]
        }

        guard let finalURL = components.url else {
            throw AudiobookshelfError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSServerInfo.self, from: data)
    }

    func refreshToken(
        serverURL: String,
        refreshToken: String,
        customHeaders: [String: String] = [:]
    ) async throws -> (accessToken: String, refreshToken: String?) {
        guard let baseURL = URL(string: serverURL) else {
            throw AudiobookshelfError.invalidURL
        }

        let url = baseURL.appendingPathComponent("auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userDict = json?["user"] as? [String: Any]
        let accessToken = userDict?["accessToken"] as? String
        let nextRefreshToken = userDict?["refreshToken"] as? String
        let legacyToken = userDict?["token"] as? String
        let rootToken = json?["token"] as? String

        guard let resolvedToken = accessToken ?? legacyToken ?? rootToken, !resolvedToken.isEmpty else {
            throw AudiobookshelfError.authenticationFailedDetailed("Missing access token in refresh response")
        }

        return (resolvedToken, nextRefreshToken)
    }

    func validateToken(backend: BackendConfig) async throws -> Bool {
        let url = try buildURL(backend: backend, path: "/api/authorize")
        let request = createRequest(url: url, method: "POST", backend: backend)

        do {
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                return true
            } else if httpResponse.statusCode == 401 {
                AppLogger.player.error("Token validation returned 401 - token is expired or invalid")
                return false
            } else {
                return false
            }
        } catch {
            return false
        }
    }

    func getLibraries(backend: BackendConfig) async throws -> [ABSLibrary] {
        let url = try buildURL(backend: backend, path: "/api/libraries")
        let request = createRequest(url: url, backend: backend)

        do {
            let (data, response) = try await session.data(for: request)
            try handleResponse(response, data: data)

            let librariesResponse = try decoder.decode(ABSLibrariesResponse.self, from: data)
            return librariesResponse.libraries
        } catch let error as DecodingError {
            AppLogger.player.error("Decoding error: \(error)")
            throw AudiobookshelfError.decodingError(error)
        } catch let error as AudiobookshelfError {
            throw error
        } catch {
            throw AudiobookshelfError.networkError(error)
        }
    }

    func getLibrary(id: String, backend: BackendConfig) async throws -> ABSLibrary {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(id)")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSLibrary.self, from: data)
    }

    func getLibraryItems(
        libraryId: String,
        backend: BackendConfig,
        limit: Int = 100,
        page: Int = 0,
        sort: String? = nil,
        desc: Bool = false,
        filter: String? = nil,
        minified: Bool = true,
        expanded: Bool = false,
        collapseSeries: Bool = false,
        include: String? = nil
    ) async throws -> ABSLibraryItemsResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: String(minified ? 1 : 0)),
            URLQueryItem(name: "collapseseries", value: String(collapseSeries ? 1 : 0)),
        ]

        if expanded {
            queryItems.append(URLQueryItem(name: "expanded", value: "1"))
        }

        if let sort = sort {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
            queryItems.append(URLQueryItem(name: "desc", value: String(desc ? 1 : 0)))
        }

        if let filter = filter {
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }

        if let include = include {
            queryItems.append(URLQueryItem(name: "include", value: include))
        }

        let url = try buildURL(backend: backend, path: "/api/libraries/\(libraryId)/items", queryItems: queryItems)

        struct ItemsURLLogOnce { static var didLog = false }
        if !ItemsURLLogOnce.didLog {
            ItemsURLLogOnce.didLog = true
            AppLogger.player.info("ABS library items URL: \(url.redacted)")
        }

        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSLibraryItemsResponse.self, from: data)
    }

    func getAllBooks(libraryId: String, backend: BackendConfig) async throws -> [ABSLibraryItem] {
        var allItems: [ABSLibraryItem] = []
        var page = 0
        let limit = 100

        while true {
            let response = try await getLibraryItems(
                libraryId: libraryId,
                backend: backend,
                limit: limit,
                page: page,
                minified: false,
                expanded: true,
                include: "audioFiles"
            )

            allItems.append(contentsOf: response.results)

            if response.results.count < limit {
                break
            }

            page += 1
        }

        return allItems
    }

    func getLibraryItem(id: String, backend: BackendConfig, expanded: Bool = true, include: String? = nil) async throws -> ABSLibraryItem {
        var queryItems: [URLQueryItem] = []

        if expanded {
            queryItems.append(URLQueryItem(name: "expanded", value: "1"))
        }

        if let include = include {
            queryItems.append(URLQueryItem(name: "include", value: include))
        }

        let url = try buildURL(backend: backend, path: "/api/items/\(id)", queryItems: queryItems.isEmpty ? nil : queryItems)
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSLibraryItem.self, from: data)
    }

    private func resolvedPath(for item: ABSLibraryItem) -> String? {
        let candidates: [String?] = [
            item.path,
            item.relPath,
            item.media?.ebookFile?.metadata?.path,
            item.media?.ebookFile?.metadata?.relPath,
            item.libraryFiles?.first?.metadata?.path,
            item.libraryFiles?.first?.metadata?.relPath,
            item.media?.audioFiles?.first?.metadata?.path,
            item.media?.audioFiles?.first?.metadata?.relPath,
        ]

        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            return raw
        }

        return nil
    }

    func convertToBooks(item: ABSLibraryItem, backend: BackendConfig, libraryId: String? = nil) -> [Book] {
        let metadata = item.media?.metadata

        let resolvedLibraryId = libraryId ?? item.libraryId

        struct DebugCounter { static var count = 0 }
        if DebugCounter.count < 10 {
            DebugCounter.count += 1
            let authorsArray = metadata?.authors ?? []

            AppLogger.player.debug(
                "Book \(DebugCounter.count): id=\(DiagnosticLogSanitizer.identifier(for: item.id)), authors=\(authorsArray.count), hasComputedAuthor=\(metadata?.authorName != nil), hasSeries=\(metadata?.series?.isEmpty == false), hasRelativePath=\(item.relPath != nil)"
            )
        }

        var coverURL: String? = nil
        if let baseURL = backend.baseURL {
            coverURL = "\(baseURL.absoluteString)/api/items/\(item.id)/cover?token=\(backend.token ?? "")"
        }

        var publishedYear: Int? = nil
        if let yearStr = metadata?.publishedYear {
            publishedYear = Int(yearStr)
        }

        let audioFiles = item.media?.audioFiles ?? []
        let audioFileIno = audioFiles.first?.ino
        let audioFileInos = audioFiles.compactMap { $0.ino }
        let bookPath = resolvedPath(for: item)

        let chapters = chapters(from: item.media)

        var builtAudioTracks: [AudioTrack]? = nil
        if let absTracks = item.media?.tracks, absTracks.count > 1 {
            builtAudioTracks = absTracks.enumerated().map { index, t in
                AudioTrack(
                    index: t.index ?? index,
                    title: t.title ?? t.metadata?.filename,
                    filePath: t.metadata?.relPath,
                    contentUrl: t.contentUrl,
                    duration: t.duration ?? 0,
                    startOffset: t.startOffset ?? 0
                )
            }
        } else if audioFiles.count > 1 {
            var offset: Double = 0
            builtAudioTracks = audioFiles.enumerated().map { index, file in
                let dur = file.duration ?? 0
                let track = AudioTrack(
                    index: file.index ?? index,
                    title: file.metadata?.filename,
                    filePath: file.metadata?.relPath,
                    duration: dur,
                    startOffset: offset,
                    format: file.format,
                    bitrate: file.bitRate,
                    channels: file.channels
                )
                offset += dur
                return track
            }
        }

        let mediaKind = item.mediaType?.lowercased()
        if let mediaKind, !["book", "podcast"].contains(mediaKind) {
            return []
        }

        let hasEbookFile = item.media?.ebookFile != nil
        let hasAudio = !audioFiles.isEmpty || (item.media?.duration ?? 0) > 0
        let isPodcast = mediaKind == "podcast"

        var results: [Book] = []

        let primaryMediaType: AppMediaType
        if isPodcast {
            primaryMediaType = .podcast
        } else if hasEbookFile && !hasAudio {
            primaryMediaType = .ebook
        } else {
            primaryMediaType = .audiobook
        }

        var primaryBook = Book(
            id: item.id,
            ratingKey: item.id,
            title: item.resolvedTitle,
            author: metadata?.authorName,
            narrator: metadata?.narratorName,
            thumb: coverURL,
            partKey: item.id,
            duration: item.media?.duration,
            chapters: chapters,
            currentChapterIndex: nil,
            source: mapBackendTypeToSource(backend.type),
            backendId: backend.id,
            trackIndex: 0,
            filePath: bookPath,
            audioFileIno: hasEbookFile && !hasAudio ? (item.media?.ebookFile?.ino ?? audioFileIno) : audioFileIno,
            audioFileInos: audioFileInos.isEmpty ? nil : audioFileInos,
            audioTracks: builtAudioTracks,
            mediaType: primaryMediaType,
            description: metadata?.description,
            series: metadata?.seriesName,
            seriesNumber: metadata?.seriesNumber,
            publishedYear: publishedYear,
            genres: metadata?.genres,
            publisher: metadata?.publisher,
            isbn: metadata?.isbn,
            asin: metadata?.asin,
            addedAt: item.addedAtDate,
            libraryName: resolvedLibraryId,
            backendName: backend.name,
            progress: nil,
            lastPlayed: nil
        )
        primaryBook.seriesSequence = metadata?.seriesSequence
        results.append(primaryBook)

        if hasEbookFile && hasAudio && !isPodcast {
            var ebookEntry = Book(
                id: "\(item.id)_ebook",
                ratingKey: "\(item.id)_ebook",
                title: item.resolvedTitle,
                author: metadata?.authorName,
                narrator: metadata?.narratorName,
                thumb: coverURL,
                partKey: item.id,
                duration: nil,
                chapters: nil,
                currentChapterIndex: nil,
                source: mapBackendTypeToSource(backend.type),
                backendId: backend.id,
                trackIndex: 0,
                filePath: bookPath,
                audioFileIno: item.media?.ebookFile?.ino,
                audioFileInos: nil,
                audioTracks: nil,
                mediaType: .ebook,
                description: metadata?.description,
                series: metadata?.seriesName,
                seriesNumber: metadata?.seriesNumber,
                publishedYear: publishedYear,
                genres: metadata?.genres,
                publisher: metadata?.publisher,
                isbn: metadata?.isbn,
                asin: metadata?.asin,
                addedAt: item.addedAtDate,
                libraryName: resolvedLibraryId,
                backendName: backend.name,
                progress: nil,
                lastPlayed: nil
            )
            ebookEntry.seriesSequence = metadata?.seriesSequence
            ebookEntry.linkedAudiobookStableId = primaryBook.stableId
            results.append(ebookEntry)
        }

        return results
    }

    func getBooks(libraryId: String, backend: BackendConfig) async throws -> [Book] {
        let items = try await getAllBooks(libraryId: libraryId, backend: backend)
        return items.flatMap { convertToBooks(item: $0, backend: backend, libraryId: libraryId) }
    }

    func updateMetadata(libraryItemId: String, metadata: ABSMetadataPayload, backend: BackendConfig) async throws -> ABSLibraryItem {
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/media")
        var request = createRequest(url: url, method: "PATCH", backend: backend)

        let updateRequest = ABSMetadataUpdateRequest(metadata: metadata)
        request.httpBody = try encoder.encode(updateRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSLibraryItem.self, from: data)
    }

    func batchUpdateMetadata(libraryItemIds: [String], updates: ABSMetadataPayload, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/items/batch/update")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let batchRequest = ABSBatchUpdateRequest(libraryItemIds: libraryItemIds, updates: updates)
        request.httpBody = try encoder.encode(batchRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func updateCoverFromURL(libraryItemId: String, coverURL: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/cover")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let body = ["url": coverURL]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func uploadCover(libraryItemId: String, imageData: Data, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/cover")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        if let token = backend.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"cover\"; filename=\"cover.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func getCollections(libraryId: String, backend: BackendConfig) async throws -> [ABSCollection] {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(libraryId)/collections")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        let collectionsResponse = try decoder.decode(ABSCollectionsResponse.self, from: data)
        return collectionsResponse.collections ?? []
    }

    func createCollection(
        libraryId: String,
        name: String,
        description: String?,
        bookIds: [String],
        backend: BackendConfig
    ) async throws -> ABSCollection {
        let url = try buildURL(backend: backend, path: "/api/collections")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let collectionRequest = ABSCollectionRequest(
            libraryId: libraryId,
            name: name,
            description: description,
            books: bookIds
        )
        request.httpBody = try encoder.encode(collectionRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSCollection.self, from: data)
    }

    func updateCollection(
        collectionId: String,
        name: String?,
        description: String?,
        bookIds: [String]?,
        backend: BackendConfig
    ) async throws -> ABSCollection {
        let url = try buildURL(backend: backend, path: "/api/collections/\(collectionId)")
        var request = createRequest(url: url, method: "PATCH", backend: backend)

        var body: [String: Any] = [:]
        if let name = name { body["name"] = name }
        if let description = description { body["description"] = description }
        if let bookIds = bookIds { body["books"] = bookIds }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSCollection.self, from: data)
    }

    func deleteCollection(collectionId: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/collections/\(collectionId)")
        let request = createRequest(url: url, method: "DELETE", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func addBookToCollection(collectionId: String, bookId: String, backend: BackendConfig) async throws -> ABSCollection {
        let url = try buildURL(backend: backend, path: "/api/collections/\(collectionId)/book")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let body = ["id": bookId]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSCollection.self, from: data)
    }

    func removeBookFromCollection(collectionId: String, bookId: String, backend: BackendConfig) async throws -> ABSCollection {
        let url = try buildURL(backend: backend, path: "/api/collections/\(collectionId)/book/\(bookId)")
        let request = createRequest(url: url, method: "DELETE", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSCollection.self, from: data)
    }

    func startPlaySession(libraryItemId: String, backend: BackendConfig, forceDirectPlay: Bool = true) async throws -> ABSPlaySession {
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/play")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let playRequest = ABSPlaySessionRequest(
            deviceInfo: deviceInfo,
            forceDirectPlay: forceDirectPlay,
            forceTranscode: false,
            supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/flac", "audio/ogg"],
            mediaPlayer: "Enve"
        )
        request.httpBody = try encoder.encode(playRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decodeABS(ABSPlaySession.self, from: data, context: "play session")
    }

    func getStreamUrl(libraryItemId: String, trackIndex: Int = 0, backend: BackendConfig) async throws -> URL? {
        let playSession = try await startPlaySession(libraryItemId: libraryItemId, backend: backend)

        guard let tracks = playSession.audioTracks, tracks.indices.contains(trackIndex) else {
            return nil
        }

        let track = tracks[trackIndex]
        guard let contentUrl = track.contentUrl else { return nil }

        if contentUrl.hasPrefix("http") {
            return URL(string: contentUrl)
        } else {
            guard let baseURL = backend.baseURL else { return nil }
            let cleanBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanPath = contentUrl.hasPrefix("/") ? contentUrl : "/\(contentUrl)"
            return URL(string: "\(cleanBase)\(cleanPath)")
        }
    }

    func getStreamUrl(
        libraryItemId: String,
        trackIndex: Int = 0,
        backend: BackendConfig,
        forceDirectPlay: Bool,
        forceTranscode: Bool
    ) async throws -> URL? {
        let playSession = try await startPlaySession(
            libraryItemId: libraryItemId,
            backend: backend,
            forceDirectPlay: forceDirectPlay,
            forceTranscode: forceTranscode
        )

        guard let tracks = playSession.audioTracks, tracks.indices.contains(trackIndex) else {
            return nil
        }
        let track = tracks[trackIndex]
        guard let contentUrl = track.contentUrl else { return nil }

        if contentUrl.hasPrefix("http") {
            return URL(string: contentUrl)
        } else {
            guard let baseURL = backend.baseURL else { return nil }
            let cleanBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanPath = contentUrl.hasPrefix("/") ? contentUrl : "/\(contentUrl)"
            return URL(string: "\(cleanBase)\(cleanPath)")
        }
    }

    func startPlaySession(
        libraryItemId: String,
        backend: BackendConfig,
        forceDirectPlay: Bool,
        forceTranscode: Bool
    ) async throws -> ABSPlaySession {
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/play")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let playRequest = ABSPlaySessionRequest(
            deviceInfo: deviceInfo,
            forceDirectPlay: forceDirectPlay,
            forceTranscode: forceTranscode,
            supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/flac", "audio/ogg"],
            mediaPlayer: "Enve"
        )
        request.httpBody = try encoder.encode(playRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
        return try decoder.decode(ABSPlaySession.self, from: data)
    }

    func closePlaySession(
        sessionId: String,
        currentTime: Double,
        timeListened: Double = 0,
        duration: Double,
        backend: BackendConfig
    ) async throws {
        let url = try buildURL(backend: backend, path: "/api/session/\(sessionId)/close")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let body: [String: Any] = [
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func getProgress(libraryItemId: String, backend: BackendConfig) async throws -> ABSMediaProgress? {
        let url = try buildURL(backend: backend, path: "/api/me/progress/\(libraryItemId)")
        let request = createRequest(url: url, backend: backend)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            if httpResponse.statusCode == 404 {
                return nil
            }

            try handleResponse(response, data: data)
            return try decoder.decode(ABSMediaProgress.self, from: data)
        } catch {
            return nil
        }
    }

    func updateProgress(
        libraryItemId: String,
        currentTime: Double,
        duration: Double,
        isFinished: Bool = false,
        backend: BackendConfig
    ) async throws {
        let url = try buildURL(backend: backend, path: "/api/me/progress/\(libraryItemId)")
        var request = createRequest(url: url, method: "PATCH", backend: backend)

        let progress = duration > 0 ? currentTime / duration : 0
        let progressRequest = ABSProgressUpdateRequest(
            currentTime: currentTime,
            duration: duration,
            progress: progress,
            isFinished: isFinished
        )
        request.httpBody = try encoder.encode(progressRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func updateEbookProgress(libraryItemId: String, ebookProgress: Double, isFinished: Bool = false, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/me/progress/\(libraryItemId)")
        var request = createRequest(url: url, method: "PATCH", backend: backend)

        let body: [String: Any] = [
            "progress": ebookProgress,
            "ebookProgress": ebookProgress,
            "currentTime": 0,
            "duration": 0,
            "isFinished": isFinished,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func markAsFinished(libraryItemId: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/me/progress/\(libraryItemId)")
        var request = createRequest(url: url, method: "PATCH", backend: backend)

        let body = ["isFinished": true]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func getAllProgress(backend: BackendConfig) async throws -> [ABSMediaProgress] {
        let user = try await getMe(backend: backend)
        return user.mediaProgress ?? []
    }

    func getBookmarks(libraryItemId: String, backend: BackendConfig) async throws -> [ABSBookmark] {

        let user = try await getMe(backend: backend)
        return (user.bookmarks ?? []).filter { $0.libraryItemId == libraryItemId }
    }

    func createBookmark(libraryItemId: String, time: Double, title: String, backend: BackendConfig) async throws -> ABSBookmark {
        let url = try buildURL(backend: backend, path: "/api/me/item/\(libraryItemId)/bookmark")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let bookmarkRequest = ABSBookmarkRequest(time: time, title: title)
        request.httpBody = try encoder.encode(bookmarkRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSBookmark.self, from: data)
    }

    func updateBookmark(libraryItemId: String, time: Double, title: String, backend: BackendConfig) async throws -> ABSBookmark {
        let url = try buildURL(backend: backend, path: "/api/me/item/\(libraryItemId)/bookmark")
        var request = createRequest(url: url, method: "PATCH", backend: backend)
        request.httpBody = try encoder.encode(ABSBookmarkRequest(time: time, title: title))
        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
        return try decoder.decode(ABSBookmark.self, from: data)
    }

    func deleteBookmark(libraryItemId: String, time: Double, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/me/item/\(libraryItemId)/bookmark/\(time)")
        let request = createRequest(url: url, method: "DELETE", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func syncBookmarks(
        libraryItemId: String,
        localBookmarks: [Bookmark],
        storageBookId: String,
        mediaType: AppMediaType,
        backend: BackendConfig
    ) async -> [Bookmark] {
        let remote: [ABSBookmark]
        do {
            remote = try await getBookmarks(libraryItemId: libraryItemId, backend: backend)
        } catch {
            AppLogger.sync.warning(
                "ABS getBookmarks failed for itemId=\(DiagnosticLogSanitizer.identifier(for: libraryItemId)): \(error.localizedDescription)"
            )
            return localBookmarks
        }

        var merged = localBookmarks
        let remoteTimes = Set(remote.map { $0.time })

        for r in remote {
            if !merged.contains(where: { abs($0.position - r.time) < 0.1 }) {
                merged.append(
                    Bookmark(
                        bookId: storageBookId,
                        position: r.time,
                        title: r.title,
                        note: nil,
                        timestamp: r.createdAtDate ?? Date(),
                        locator: nil,
                        mediaType: mediaType,
                        chapterTitle: nil
                    )
                )
            }
        }

        for i in merged.indices {
            guard !remoteTimes.contains(where: { abs($0 - merged[i].position) < 0.1 }) else { continue }
            do {
                let synced = try await createBookmark(
                    libraryItemId: libraryItemId,
                    time: merged[i].position,
                    title: merged[i].title,
                    backend: backend
                )
                merged[i] = Bookmark(
                    id: merged[i].id,
                    bookId: merged[i].bookId,
                    position: synced.time,
                    title: synced.title,
                    note: merged[i].note,
                    timestamp: synced.createdAtDate ?? merged[i].timestamp,
                    locator: merged[i].locator,
                    mediaType: merged[i].mediaType,
                    chapterTitle: merged[i].chapterTitle
                )
            } catch {
                AppLogger.sync.warning(
                    "ABS createBookmark push failed for itemId=\(DiagnosticLogSanitizer.identifier(for: libraryItemId)) at \(merged[i].position): \(error.localizedDescription)"
                )
            }
        }

        return merged
    }

    func search(query: String, libraryId: String, backend: BackendConfig, limit: Int = 25) async throws -> ABSSearchResults {
        let queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        let url = try buildURL(backend: backend, path: "/api/libraries/\(libraryId)/search", queryItems: queryItems)
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSSearchResults.self, from: data)
    }

    func searchMetadata(
        title: String,
        author: String? = nil,
        backend: BackendConfig,
        provider: String = "audible",
        limit: Int = 20
    ) async throws -> [AudibleSearchResult] {
        var queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "title", value: title),
        ]

        if let author = author, !author.isEmpty {
            queryItems.append(URLQueryItem(name: "author", value: author))
        }

        let url = try buildURL(backend: backend, path: "/api/search/books", queryItems: queryItems)
        AppLogger.player.debug(
            "server-side query - titleId=\(DiagnosticLogSanitizer.identifier(for: title)), hasAuthor=\(author?.isEmpty == false)"
        )

        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        if let jsonString = String(data: data, encoding: .utf8) {
            _ = jsonString
        }

        struct ABSAudibleSearchResult: Codable {
            let asin: String
            let title: String
            let author: String?
            let narrator: String?
            let publisher: String?
            let publishedYear: String?
            let description: String?
            let cover: String?
            let genres: [String]?
            let duration: Int?
            let rating: String?
        }

        let results: [ABSAudibleSearchResult]
        if let directArray = try? decoder.decode([ABSAudibleSearchResult].self, from: data) {
            results = directArray
        } else {
            struct ABSMetadataSearchResponse: Codable {
                let results: [ABSAudibleSearchResult]?
            }
            let searchResponse = try decoder.decode(ABSMetadataSearchResponse.self, from: data)
            results = searchResponse.results ?? []
        }

        return results.map { result in
            let durationInSeconds = (result.duration ?? 0) * 60

            return AudibleSearchResult(
                asin: result.asin,
                title: result.title,
                authors: result.author.map { [$0] } ?? [],
                narrators: result.narrator.map { [$0] } ?? [],
                duration: durationInSeconds,
                releaseDate: result.publishedYear,
                coverUrl: result.cover,
                rating: nil,
                description: result.description
            )
        }
    }

    func getAuthors(libraryId: String, backend: BackendConfig) async throws -> [ABSAuthor] {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(libraryId)/authors")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct AuthorsResponse: Codable {
            let authors: [ABSAuthor]
        }

        let authorsResponse = try decoder.decode(AuthorsResponse.self, from: data)
        return authorsResponse.authors
    }

    func getSeries(libraryId: String, backend: BackendConfig) async throws -> [ABSSeries] {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(libraryId)/series")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct SeriesResponse: Codable {
            let results: [ABSSeries]
        }

        let seriesResponse = try decoder.decode(SeriesResponse.self, from: data)
        return seriesResponse.results
    }

    func scanLibrary(libraryId: String, backend: BackendConfig, force: Bool = false) async throws {
        var queryItems: [URLQueryItem] = []
        if force {
            queryItems.append(URLQueryItem(name: "force", value: "1"))
        }

        let url = try buildURL(
            backend: backend,
            path: "/api/libraries/\(libraryId)/scan",
            queryItems: queryItems.isEmpty ? nil : queryItems
        )
        let request = createRequest(url: url, method: "POST", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func matchLibraryItem(libraryItemId: String, provider: String = "audible", backend: BackendConfig) async throws {
        let queryItems = [URLQueryItem(name: "provider", value: provider)]
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/match", queryItems: queryItems)
        let request = createRequest(url: url, method: "POST", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func getCoverURL(libraryItemId: String, backend: BackendConfig) -> URL? {
        guard let baseURL = backend.baseURL else { return nil }

        var urlString = "\(baseURL.absoluteString)/api/items/\(libraryItemId)/cover"
        if let token = backend.token {
            urlString += "?token=\(token)"
        }

        return URL(string: urlString)
    }

    func getAuthorImageURL(authorId: String, backend: BackendConfig) -> URL? {
        guard let baseURL = backend.baseURL else { return nil }

        var urlString = "\(baseURL.absoluteString)/api/authors/\(authorId)/image"
        if let token = backend.token {
            urlString += "?token=\(token)"
        }

        return URL(string: urlString)
    }

    private func chapters(from media: ABSBookMedia?) -> [Chapter] {
        guard let media else { return [] }

        if let absChapters = media.chapters, !absChapters.isEmpty {
            return absChapters.enumerated().map { index, chapter in
                Chapter(id: String(chapter.id), start: chapter.start, end: chapter.end, title: chapter.title, index: index)
            }
        }

        if let audioFiles = media.audioFiles {
            let nested = nestedAudioFileChapters(from: audioFiles)
            if !nested.isEmpty { return nested }

            if audioFiles.count > 1 {
                return trackBasedChapters(from: audioFiles)
            }
        }

        return []
    }

    private func nestedAudioFileChapters(from audioFiles: [ABSAudioFile]) -> [Chapter] {
        var chapters: [Chapter] = []
        var fileOffset: TimeInterval = 0

        for (fileIndex, file) in audioFiles.enumerated() {
            for chapter in file.chapters ?? [] {
                let start = fileOffset + chapter.start
                let end = fileOffset + chapter.end
                guard end > start else { continue }
                chapters.append(
                    Chapter(
                        id: "file_\(fileIndex)_\(chapter.id)",
                        start: start,
                        end: end,
                        title: chapter.title,
                        index: chapters.count
                    )
                )
            }
            fileOffset += file.duration ?? 0
        }

        return chapters
    }

    private func trackBasedChapters(from audioFiles: [ABSAudioFile]) -> [Chapter] {
        var offset: TimeInterval = 0
        return audioFiles.enumerated().compactMap { index, file in
            let duration = file.duration ?? 0
            guard duration > 0 else { return nil }
            let title =
                file.metadata?.filename?
                .replacingOccurrences(of: ".\(file.metadata?.ext ?? "")", with: "")
                ?? "Track \(index + 1)"
            let chapter = Chapter(
                id: "track_\(file.index ?? index)",
                start: offset,
                end: offset + duration,
                title: title,
                index: index
            )
            offset += duration
            return chapter
        }
    }

    func getChapters(libraryItemId: String, backend: BackendConfig) async throws -> [Chapter] {
        let item = try await getLibraryItem(id: libraryItemId, backend: backend, expanded: true)
        return chapters(from: item.media)
    }

    func updateChapters(libraryItemId: String, chapters: [ABSChapter], backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/items/\(libraryItemId)/chapters")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let body = ["chapters": chapters]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func getMe(backend: BackendConfig) async throws -> ABSUser {
        let url = try buildURL(backend: backend, path: "/api/me")
        var request = createRequest(url: url, backend: backend)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSUser.self, from: data)
    }

    func getStats(backend: BackendConfig) async throws -> ABSStats {
        let url = try buildURL(backend: backend, path: "/api/me/listening-stats")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSStats.self, from: data)
    }

    func getFilesystemFolders(path: String = "/", backend: BackendConfig) async throws -> [ABSFilesystemItem] {
        let queryItems = [URLQueryItem(name: "path", value: path)]
        let url = try buildURL(backend: backend, path: "/api/filesystem", queryItems: queryItems)
        var request = createRequest(url: url, backend: backend)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct FilesystemResponseV1: Codable {
            let directories: [ABSFilesystemItem]
        }

        do {
            let filesystemResponse = try decoder.decode(FilesystemResponseV1.self, from: data)
            return filesystemResponse.directories
        } catch {
            do {
                let directories = try decoder.decode([ABSFilesystemItem].self, from: data)
                return directories
            } catch {
                AppLogger.player.error("Failed to decode filesystem response (\(data.count) bytes)")
                throw error
            }
        }
    }

    func getUsers(backend: BackendConfig) async throws -> [ABSUser] {
        let url = try buildURL(backend: backend, path: "/api/users")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct UsersResponse: Codable { let users: [ABSUser] }
        let usersResponse = try decoder.decode(UsersResponse.self, from: data)
        return usersResponse.users
    }

    func createUser(request: ABSUserCreateRequest, backend: BackendConfig) async throws -> ABSUser {
        let url = try buildURL(backend: backend, path: "/api/users")
        var urlRequest = createRequest(url: url, method: "POST", backend: backend)
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSUser.self, from: data)
    }

    func updateUser(id: String, request: ABSUserUpdateRequest, backend: BackendConfig) async throws -> ABSUser {
        let url = try buildURL(backend: backend, path: "/api/users/\(id)")
        var urlRequest = createRequest(url: url, method: "PATCH", backend: backend)
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSUser.self, from: data)
    }

    func deleteUser(id: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/users/\(id)")
        let urlRequest = createRequest(url: url, method: "DELETE", backend: backend)

        let (data, response) = try await session.data(for: urlRequest)
        try handleResponse(response, data: data)
    }

    func getOnlineUsers(backend: BackendConfig) async throws -> [ABSOnlineUser] {
        let url = try buildURL(backend: backend, path: "/api/users/online")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct OnlineResponse: Codable {
            let usersOnline: [ABSOnlineUser]?
            let openSessions: [ABSPlaySession]?
        }
        let onlineResponse = try decoder.decode(OnlineResponse.self, from: data)
        return onlineResponse.usersOnline ?? []
    }

    func getActiveSessions(backend: BackendConfig) async throws -> [ABSPlaySession] {
        let url = try buildURL(backend: backend, path: "/api/sessions")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct SessionsResponse: Codable {
            let sessions: [ABSPlaySession]?
            let total: Int?
        }
        let sessionsResponse = try decoder.decode(SessionsResponse.self, from: data)
        return sessionsResponse.sessions ?? []
    }

    func getBackups(backend: BackendConfig) async throws -> [ABSBackup] {
        let url = try buildURL(backend: backend, path: "/api/backups")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct BackupsResponse: Codable {
            let backups: [ABSBackup]?
        }
        let backupsResponse = try decoder.decode(BackupsResponse.self, from: data)
        return backupsResponse.backups ?? []
    }

    func createBackup(backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/backups")
        let request = createRequest(url: url, method: "POST", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func deleteBackup(filename: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/backups/\(filename)")
        let request = createRequest(url: url, method: "DELETE", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func createLibrary(request: ABSLibraryRequest, backend: BackendConfig) async throws -> ABSLibrary {
        let url = try buildURL(backend: backend, path: "/api/libraries")
        var urlRequest = createRequest(url: url, method: "POST", backend: backend)
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSLibrary.self, from: data)
    }

    func updateLibrary(id: String, request: ABSLibraryRequest, backend: BackendConfig) async throws -> ABSLibrary {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(id)")
        var urlRequest = createRequest(url: url, method: "PATCH", backend: backend)
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try handleResponse(response, data: data)

        return try decoder.decode(ABSLibrary.self, from: data)
    }

    func deleteLibrary(id: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(id)")
        let request = createRequest(url: url, method: "DELETE", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func scanLibrary(id: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(id)/scan")
        let request = createRequest(url: url, method: "POST", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func purgeLibraryCache(id: String, backend: BackendConfig) async throws {
        let url = try buildURL(backend: backend, path: "/api/libraries/\(id)/purge-cache")
        let request = createRequest(url: url, method: "POST", backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func getServerSettings(backend: BackendConfig) async throws -> ABSServerSettings {
        let url = try buildURL(backend: backend, path: "/api/settings")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        struct SettingsWrapper: Codable {
            let settings: ABSServerSettings?
            let serverSettings: ABSServerSettings?
        }
        if let wrapper = try? decoder.decode(SettingsWrapper.self, from: data) {
            if let settings = wrapper.settings ?? wrapper.serverSettings {
                return settings
            }
        }
        return try decoder.decode(ABSServerSettings.self, from: data)
    }

    func updateServerSettings(_ update: ABSServerSettingsUpdate, backend: BackendConfig) async throws -> ABSServerSettings {
        let url = try buildURL(backend: backend, path: "/api/settings")
        var urlRequest = createRequest(url: url, method: "PATCH", backend: backend)
        urlRequest.httpBody = try encoder.encode(update)

        let (data, response) = try await session.data(for: urlRequest)
        try handleResponse(response, data: data)

        struct UpdateResponse: Codable {
            let success: Bool?
            let serverSettings: ABSServerSettings?
        }
        if let updateResp = try? decoder.decode(UpdateResponse.self, from: data),
            let settings = updateResp.serverSettings
        {
            return settings
        }
        return try decoder.decode(ABSServerSettings.self, from: data)
    }

    func startPlaySession(
        libraryItemId: String,
        episodeId: String?,
        backend: BackendConfig,
        forceDirectPlay: Bool = true
    ) async throws -> ABSPlaySession {
        let path: String
        if let episodeId = episodeId {
            path = "/api/items/\(libraryItemId)/play/\(episodeId)"
        } else {
            path = "/api/items/\(libraryItemId)/play"
        }

        let url = try buildURL(backend: backend, path: path)
        var request = createRequest(url: url, method: "POST", backend: backend)

        let playRequest = ABSPlaySessionRequest(
            deviceInfo: deviceInfo,
            forceDirectPlay: forceDirectPlay,
            forceTranscode: false,
            supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/flac", "audio/ogg"],
            mediaPlayer: "Enve"
        )
        request.httpBody = try encoder.encode(playRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)

        return try decodeABS(ABSPlaySession.self, from: data, context: "play session")
    }

    func syncPlaySession(
        sessionId: String,
        currentTime: TimeInterval,
        timeListened: TimeInterval,
        duration: TimeInterval,
        backend: BackendConfig
    ) async throws {
        let url = try buildURL(backend: backend, path: "/api/session/\(sessionId)/sync")
        var request = createRequest(url: url, method: "POST", backend: backend)

        let syncRequest: [String: Any] = [
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: syncRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func updateProgress(
        libraryItemId: String,
        episodeId: String,
        currentTime: Double,
        duration: Double,
        isFinished: Bool = false,
        backend: BackendConfig
    ) async throws {
        let url = try buildURL(backend: backend, path: "/api/me/progress/\(libraryItemId)/\(episodeId)")
        var request = createRequest(url: url, method: "PATCH", backend: backend)

        let progress = duration > 0 ? currentTime / duration : 0
        let progressRequest = ABSProgressUpdateRequest(
            currentTime: currentTime,
            duration: duration,
            progress: progress,
            isFinished: isFinished
        )
        request.httpBody = try encoder.encode(progressRequest)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }

    func syncLocalSession(
        sessionId: String,
        libraryItemId: String,
        episodeId: String?,
        currentTime: TimeInterval,
        timeListened: TimeInterval,
        duration: TimeInterval,
        started: Date,
        updated: Date,
        backend: BackendConfig
    ) async throws {
        let url = try buildURL(backend: backend, path: "/api/session/local")
        var request = createRequest(url: url, method: "POST", backend: backend)

        var body: [String: Any] = [
            "id": sessionId,
            "libraryItemId": libraryItemId,
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
            "startedAt": Int(started.timeIntervalSince1970 * 1000),
            "updatedAt": Int(updated.timeIntervalSince1970 * 1000),
        ]

        if let episodeId = episodeId {
            body["episodeId"] = episodeId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try handleResponse(response, data: data)
    }
}

extension AudiobookshelfService {
    struct AudiobookshelfLibrary: Codable {
        let id: String
        let name: String
        let type: String
    }

    func getLibrariesLegacy(backend: BackendConfig) async throws -> [AudiobookshelfLibrary] {
        let libraries = try await getLibraries(backend: backend)
        return libraries.map { lib in
            AudiobookshelfLibrary(id: lib.id, name: lib.name, type: lib.mediaType ?? "book")
        }
    }

    private func mapBackendTypeToSource(_ type: BackendConfig.BackendType) -> Book.BookSource {
        switch type {
        case .audiobookshelf: return .audiobookshelf
        case .jellyfin: return .jellyfin
        case .emby: return .emby
        case .plex: return .plex
        case .storyteller: return .storyteller
        }
    }
}
