import Foundation
import Logging
import Combine

extension BookloreProvider {
    func addAuthHeaders(_ request: inout URLRequest) {
        transport.addAuthHeaders(to: &request, connection: connection)
    }

    func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        includeAuth: Bool = true
    ) throws -> URLRequest {
        try transport.makeRequest(
            connection: connection,
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            contentType: contentType,
            includeAuth: includeAuth
        )
    }

    func send(_ request: URLRequest, allowCloudflareRefresh: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        adoptCookiesIfPresent(from: httpResponse)

        if let location = CloudflareAccessHeaders.accessRedirectLocation(in: httpResponse) {
            if allowCloudflareRefresh, await refreshCloudflareCookieIfPossible() {
                var retry = request
                if let cookie = connection.customHeaders?[CloudflareAccessHeaders.cookieHeader] {
                    retry.setValue(cookie, forHTTPHeaderField: CloudflareAccessHeaders.cookieHeader)
                }
                return try await send(retry, allowCloudflareRefresh: false)
            }
            let endpoint = request.url?.path ?? "request"
            throw ProviderError.serverError(
                CloudflareAccessHeaders.accessRejectionMessage(location: location, endpoint: endpoint)
            )
        }

        return (data, httpResponse)
    }

    private var usesBrowserCloudflareCookie: Bool {
        connection.customHeaders?["Cookie"]?.contains("CF_Authorization=") == true
    }

    private func refreshCloudflareCookieIfPossible() async -> Bool {
        #if os(tvOS)
        return false
        #else
        guard usesBrowserCloudflareCookie,
            let serverURL = URL(string: normalize(connection.url))
        else { return false }
        guard let newCookieHeader = await cloudflareRefresh.refreshedCookieHeader(for: serverURL),
            connection.customHeaders?["Cookie"] != newCookieHeader
        else {
            return false
        }
        var headers = connection.customHeaders ?? [:]
        headers["Cookie"] = newCookieHeader
        connection.customHeaders = headers
        notifyTokenUpdated()
        AppLogger.network.info("[Booklore] Refreshed Cloudflare Access cookie silently")
        return true
        #endif
    }

    func ensureCloudflareSessionValid() async throws {
        guard usesBrowserCloudflareCookie else { return }
        _ = try await validateConnection()
    }

    private func adoptCookiesIfPresent(from response: HTTPURLResponse) {
        let cookieHeaderName = CloudflareAccessHeaders.cookieHeader
        guard let cookieHeader = HTTPResponseInspector.mergedCookieHeader(
            existing: connection.customHeaders?[cookieHeaderName],
            response: response
        ),
            connection.customHeaders?[cookieHeaderName] != cookieHeader
        else { return }

        var updatedHeaders = connection.customHeaders ?? [:]
        updatedHeaders[cookieHeaderName] = cookieHeader
        connection.customHeaders = updatedHeaders
        notifyTokenUpdated()
        AppLogger.network.info("Updated Booklore Cookie header from server response")
    }

    func performAuthorizedRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let token = connection.token,
            let jwt = BookloreJWT(token),
            jwt.isExpiring(buffer: 60),
            shouldAttemptTokenRefresh()
        {
            do {
                if let refreshed = try await refreshCoalesced() {
                    connection.token = refreshed
                    notifyTokenUpdated()
                    AppLogger.network.info("Proactive token refresh before request")
                }
            } catch let ProviderError.rateLimited(message) {
                throw ProviderError.rateLimited(message)
            } catch {
                AppLogger.network.warning("Proactive token refresh failed: \(error.localizedDescription)")
            }
        }

        var authedRequest = request
        addAuthHeaders(&authedRequest)
        let (data, response) = try await send(authedRequest)
        if response.statusCode != 401 {
            return (data, response)
        }

        var currentRequest = request
        addAuthHeaders(&currentRequest)
        if currentRequest.value(forHTTPHeaderField: "Authorization") != authedRequest.value(forHTTPHeaderField: "Authorization") {
            return try await send(currentRequest)
        }

        if shouldAttemptTokenRefresh() {
            if let refreshed = try await refreshCoalesced() {
                connection.token = refreshed
                AppLogger.network.info("Token silently refreshed after 401")
                notifyTokenUpdated()
                var retry = request
                addAuthHeaders(&retry)
                return try await send(retry)
            }
        }

        guard let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        else {
            return (data, response)
        }

        AppLogger.network.info("Received 401, refreshing JWT via full re-login")
        try await loginCoalesced(username: username, password: password)

        var retry = request
        addAuthHeaders(&retry)
        return try await send(retry)
    }

    func performAuthorizedDownload(
        _ request: URLRequest,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, HTTPURLResponse) {
        if let token = connection.token,
            let jwt = BookloreJWT(token),
            jwt.isExpiring(buffer: 60),
            shouldAttemptTokenRefresh()
        {
            do {
                if let refreshed = try await refreshCoalesced() {
                    connection.token = refreshed
                    notifyTokenUpdated()
                    AppLogger.network.info("Proactive token refresh before ebook download")
                }
            } catch let ProviderError.rateLimited(message) {
                throw ProviderError.rateLimited(message)
            } catch {
                AppLogger.network.warning("Proactive streaming token refresh failed: \(error.localizedDescription)")
            }
        }

        func execute(_ req: URLRequest, onProgress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPURLResponse) {

            let progressCallback: @Sendable (Double) -> Void = onProgress ?? { _ in }
            let delegate = URLSessionDownloadProgressDelegate(
                progressHandler: progressCallback,
                credential: transport.credential,
                certificateTransport: certificateTransport
            )
            let bgConfig = URLSessionConfiguration.background(withIdentifier: "com.enve.ebookdownload.\(UUID().uuidString)")
            if isolatesCredentials {
                bgConfig.httpCookieStorage = nil
                bgConfig.httpShouldSetCookies = false
                bgConfig.urlCredentialStorage = nil
                bgConfig.urlCache = nil
            }
            bgConfig.waitsForConnectivity = true
            bgConfig.allowsExpensiveNetworkAccess = true
            bgConfig.allowsConstrainedNetworkAccess = true
            bgConfig.timeoutIntervalForRequest = 300
            bgConfig.timeoutIntervalForResource = 3600

            bgConfig.httpAdditionalHeaders = transport.sessionHeaders
            let downloadSession = URLSession(configuration: bgConfig, delegate: delegate, delegateQueue: nil)
            defer { downloadSession.finishTasksAndInvalidate() }

            let (localURL, http) = try await delegate.awaitResult {
                downloadSession.downloadTask(with: req)
            }
            return (localURL, http)
        }

        var authedRequest = request
        addAuthHeaders(&authedRequest)
        let first = try await execute(authedRequest, onProgress: onProgress)
        if first.1.statusCode != 401 {
            return first
        }

        var currentRequest = request
        addAuthHeaders(&currentRequest)
        if currentRequest.value(forHTTPHeaderField: "Authorization") != authedRequest.value(forHTTPHeaderField: "Authorization") {
            return try await execute(currentRequest, onProgress: onProgress)
        }

        if shouldAttemptTokenRefresh() {
            if let refreshed = try await refreshCoalesced() {
                connection.token = refreshed
                notifyTokenUpdated()
                AppLogger.network.info("Token silently refreshed after 401 during ebook download")
                var retry = request
                addAuthHeaders(&retry)
                return try await execute(retry, onProgress: onProgress)
            }
        }

        guard let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        else {
            return first
        }

        AppLogger.network.info("Received 401 during ebook download, refreshing JWT via full re-login")
        try await loginCoalesced(username: username, password: password)

        var retry = request
        addAuthHeaders(&retry)
        return try await execute(retry, onProgress: onProgress)
    }

    func shouldAttemptTokenRefresh() -> Bool {
        guard let rt = refreshToken, !rt.isEmpty else { return false }
        return BookloreJWT(rt)?.isActive() ?? true
    }

    func refreshStreamingTokenIfNeeded(force: Bool = false) async -> Bool {
        if !force,
            let token = connection.token,
            let jwt = BookloreJWT(token),
            !jwt.isExpiring(buffer: 60)
        {
            return true
        }
        guard shouldAttemptTokenRefresh() else { return false }
        do {

            guard let refreshed = try await refreshCoalesced() else {
                AppLogger.network.warning("Streaming token refresh returned no token")
                return false
            }
            connection.token = refreshed
            notifyTokenUpdated()
            AppLogger.network.info("Refreshed JWT for streaming download (force=\(force))")
            return true
        } catch {
            AppLogger.network.warning("Streaming token refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func attemptTokenRefresh() async throws -> String? {
        guard shouldAttemptTokenRefresh(), let rt = refreshToken, !rt.isEmpty else { return nil }

        struct RefreshRequest: Encodable { let refreshToken: String }
        let body = try JSONEncoder().encode(RefreshRequest(refreshToken: rt))
        let request = try makeRequest(
            path: "/api/v1/auth/refresh",
            method: "POST",
            body: body,
            contentType: "application/json",
            includeAuth: false
        )

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 429 {
                throw ProviderError.rateLimited(
                    serverErrorMessage(from: data) ?? "Too many authentication attempts. Please try again in 15 minutes."
                )
            }
            if response.statusCode != 401 && response.statusCode != 403 {
                throw ProviderError.serverError(serverErrorMessage(from: data) ?? "Token refresh failed (HTTP \(response.statusCode))")
            }
            AppLogger.network.error("Token refresh rejected (HTTP \(response.statusCode)), will re-login")
            refreshToken = nil
            keychain.delete(refreshTokenKeychainKey)
            return nil
        }

        let login = try JSONDecoder().decode(BookloreLoginResponse.self, from: data)
        saveRefreshToken(login.refreshToken)
        return login.accessToken
    }

    func refreshCoalesced() async throws -> String? {
        lockLoginTask()
        if let existing = activeRefreshTask {
            unlockLoginTask()
            return try await existing.value
        }
        let task: Task<String?, Error> = Task { [weak self] in
            guard let self else { return nil }
            return try await self.attemptTokenRefresh()
        }
        activeRefreshTask = task
        unlockLoginTask()
        defer {
            lockLoginTask()
            activeRefreshTask = nil
            unlockLoginTask()
        }
        return try await task.value
    }

    func notifyTokenUpdated() {
        let conn = connection
        let callback = onTokenUpdated
        DispatchQueue.main.async { callback?(conn) }
    }

    func attemptTierUpgrade() async {
        guard useLegacyRestAPI || useKomgaFallback else { return }

        guard let req = try? makeRequest(path: "/api/v1/app/users/me") else { return }
        guard let (_, response) = try? await send(req), response.statusCode == 200 else { return }
        useLegacyRestAPI = false
        useKomgaFallback = false
        tierPreference.clear()
        AppLogger.network.info("[Booklore] Upgraded back to app-tier API")
    }

    func demoteKomgaToLegacyREST() {
        useKomgaFallback = false
        useLegacyRestAPI = true
        tierPreference.store(.legacy)
    }

    func loginCoalesced(username: String, password: String) async throws {
        if let blockedUntil = credentialLoginBlockedUntil, blockedUntil > Date() {
            throw ProviderError.rateLimited("Automatic sign-in is paused after a failed attempt. Please try again in 15 minutes.")
        }
        lockLoginTask()
        if let existing = activeLoginTask {
            unlockLoginTask()
            try await existing.value
            return
        }
        let task: Task<Void, Error> = Task { [weak self] in
            guard let self else { return }
            _ = try await self.loginWithCredentials(username: username, password: password)
        }
        activeLoginTask = task
        unlockLoginTask()
        defer {
            lockLoginTask()
            activeLoginTask = nil
            unlockLoginTask()
        }
        do {
            try await task.value
            credentialLoginBlockedUntil = nil
        } catch {
            if case ProviderError.unauthorized = error {
                credentialLoginBlockedUntil = Date().addingTimeInterval(15 * 60)
            } else if case ProviderError.rateLimited = error {
                credentialLoginBlockedUntil = Date().addingTimeInterval(15 * 60)
            }
            throw error
        }
    }

    func validateConnection() async throws -> Bool {
        try EnveProvenance.checkServerAddress(connection.url)
        if let token = connection.token, !token.isEmpty {
            do {
                try await validateJWTSession()
                return true
            } catch ProviderError.unauthorized {
                AppLogger.network.error("Existing token validation failed: unauthorized")
            } catch {
                throw error
            }
        }

        if shouldAttemptTokenRefresh(), let refreshed = try await refreshCoalesced() {
            connection.token = refreshed
            notifyTokenUpdated()
            AppLogger.network.info("Token refreshed during validateConnection")
            try await validateJWTSession()
            return true
        }

        guard let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        else {
            throw ProviderError.unauthorized
        }

        try await loginCoalesced(username: username, password: password)
        try await validateJWTSession()
        return true
    }

    private func loginWithCredentials(username: String, password: String) async throws -> BookloreLoginResponse {
        let payload = BookloreLoginRequest(username: username, password: password)
        let body = try JSONEncoder().encode(payload)
        let request = try makeRequest(
            path: "/api/v1/auth/login",
            method: "POST",
            body: body,
            contentType: "application/json",
            includeAuth: false
        )

        if let headers = connection.customHeaders, !headers.isEmpty {
            AppLogger.network.info("Sending custom headers with login: \(headers.keys.sorted().joined(separator: ", "))")
        }
        AppLogger.network.info("Logging in via /api/v1/auth/login")
        let (data, response) = try await send(request)
        AppLogger.network.info("/api/v1/auth/login -> HTTP \(response.statusCode)")

        try guardJSON(data, response: response, endpoint: "/api/v1/auth/login")

        guard response.statusCode == 200 else {
            AppLogger.network.info("Login rejected with HTTP \(response.statusCode)")
            if response.statusCode == 429 {
                throw ProviderError.rateLimited(
                    serverErrorMessage(from: data) ?? "Too many failed login attempts. Please try again in 15 minutes."
                )
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError(serverErrorMessage(from: data) ?? "Login failed (HTTP \(response.statusCode))")
        }

        let login = try JSONDecoder().decode(BookloreLoginResponse.self, from: data)
        connection.token = login.accessToken
        saveRefreshToken(login.refreshToken)
        AppLogger.network.info("JWT login succeeded (refreshToken: \(login.refreshToken != nil ? "present" : "absent"))")
        notifyTokenUpdated()
        return login
    }

    private func validateJWTSession() async throws {
        let request = try makeRequest(path: "/api/v1/users/me")
        AppLogger.network.info("Validating JWT via /api/v1/users/me")
        let (data, response) = try await performAuthorizedRequest(request)
        AppLogger.network.info("/api/v1/users/me -> HTTP \(response.statusCode)")

        try guardJSON(data, response: response, endpoint: "/api/v1/users/me")

        guard response.statusCode == 200 else {
            AppLogger.network.error("JWT validation failed with HTTP \(response.statusCode)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError("Validation failed (HTTP \(response.statusCode))")
        }
    }
}
