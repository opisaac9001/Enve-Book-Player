// AGENT-LOCKED
import AuthenticationServices
import CryptoKit
import SwiftUI

final class ValidatedConnectionLoginDelegate: UnifiedLoginDelegate {
    private let appState: AppState
    private let providerType: ProviderType
    private let defaultName: String

    init(appState: AppState, providerType: ProviderType, defaultName: String) {
        self.appState = appState
        self.providerType = providerType
        self.defaultName = defaultName
    }

    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let tempConnection = ServerConnection(
            name: defaultName,
            url: normalizedURL(serverURL),
            type: inferredProviderType(for: serverURL),
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            token: nil,
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .usernamePassword
        )

        return try await validatedConnection(from: tempConnection)
    }

    func authenticateWithToken(serverURL: String, token: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        let tempConnection = ServerConnection(
            name: defaultName,
            url: normalizedURL(serverURL),
            type: inferredProviderType(for: serverURL),
            token: token.isEmpty ? nil : token,
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .token
        )

        return try await validatedConnection(from: tempConnection)
    }

    private func validatedConnection(from tempConnection: ServerConnection) async throws -> ServerConnection {
        let (isValid, validatedConnection) = try await appState.validateConnection(tempConnection)
        guard isValid else {
            throw NSError(
                domain: "UnifiedLogin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Connection failed. Please check your credentials."]
            )
        }

        var finalConnection = validatedConnection
        finalConnection.isConnected = true
        finalConnection.lastVerified = Date()
        return finalConnection
    }

    func fetchLibraries(connection: ServerConnection) async throws -> [LibraryMetadata] {
        guard let provider = PluginRegistry.shared.makeLibraryProvider(for: connection) else {
            return []
        }
        return try await provider.fetchLibraries().map { library in
            let type = Self.libraryType(from: library.type)
            return LibraryMetadata(
                id: library.id,
                name: library.name,
                type: type,
                itemCount: 0,
                audioBookCount: type == .audiobooks ? 1 : 0,
                collectionType: library.type
            )
        }
    }

    private func inferredProviderType(for serverURL: String) -> ProviderType {
        if providerType == .webdav, serverURL.lowercased().contains("real-debrid") {
            return .realdebrid
        }
        return providerType
    }

    private func normalizedURL(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { return value }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    private static func libraryType(from rawValue: String) -> LibraryType {
        switch rawValue.lowercased() {
        case "audiobook", "audiobooks", "audio":
            return .audiobooks
        case "book", "books", "ebook", "ebooks", "manga", "comic", "comics":
            return .books
        case "movie", "movies":
            return .movies
        case "series", "tv", "tvshows", "shows":
            return .tvshows
        case "music":
            return .music
        case "mixed":
            return .mixed
        default:
            return .unknown
        }
    }
}

final class GrimmoryLoginDelegate: UnifiedLoginDelegate {
    private let appState: AppState
    @MainActor private var grimmoryAuthSession: ASWebAuthenticationSession?

    init(appState: AppState) {
        self.appState = appState
    }

    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        try validateGrimmoryHeaders(customHeaders)
        let tempConnection = ServerConnection(
            name: "Grimmory",
            url: normalizedURL(serverURL),
            type: .booklore,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            token: nil,
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .usernamePassword
        )
        return try await validatedConnection(from: tempConnection)
    }

    func authenticateWithToken(serverURL: String, token: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        try validateGrimmoryHeaders(customHeaders)
        guard let token = BookloreJWT.normalizedToken(token), BookloreJWT(token) != nil else {
            throw GrimmoryLoginError.invalidToken
        }
        let tempConnection = ServerConnection(
            name: "Grimmory",
            url: normalizedURL(serverURL),
            type: .booklore,
            token: token.isEmpty ? nil : token,
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .token
        )
        return try await validatedConnection(from: tempConnection)
    }

    func authenticateWithOIDC(
        serverURL: String,
        redirectURIOverride: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        try validateGrimmoryHeaders(customHeaders)
        let normalized = normalizedURL(serverURL)
        let settings = try await fetchGrimmoryPublicSettings(serverURL: normalized, customHeaders: customHeaders)
        guard settings.oidcEnabled, let provider = settings.oidcProviderDetails else {
            throw OAuthError.authorizationFailed("OIDC is not enabled on this Grimmory server.")
        }

        let codeVerifier = randomPKCEVerifier()
        let codeChallenge = pkceChallenge(from: codeVerifier)
        let nonce = randomPKCEVerifier(length: 32)
        let state = try await fetchGrimmoryOIDCState(serverURL: normalized, customHeaders: customHeaders)
        let redirectURI = redirectURIOverride ?? AppAuthRedirectURI.grimmory
        let callbackScheme = AppAuthRedirectURI.scheme(for: redirectURI)
        let authURL = try await buildGrimmoryOIDCAuthURL(
            provider: provider,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: state,
            nonce: nonce
        )

        let callbackURL = try await presentGrimmoryAuthentication(url: authURL, callbackScheme: callbackScheme)
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidResponse
        }
        if let authError = callbackComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            throw OAuthError.authorizationFailed(authError)
        }
        guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.invalidResponse
        }

        let response = try await exchangeGrimmoryOIDCCode(
            serverURL: normalized,
            code: code,
            codeVerifier: codeVerifier,
            nonce: nonce,
            state: state,
            redirectURI: redirectURI,
            customHeaders: customHeaders
        )

        let resolvedUsername = try await fetchGrimmoryUsername(
            serverURL: normalized,
            accessToken: response.accessToken,
            customHeaders: customHeaders
        )

        let storedRedirectURI: String? = (redirectURIOverride == AppAuthRedirectURI.grimmory) ? nil : redirectURIOverride
        let tempConnection = ServerConnection(
            name: "Grimmory",
            url: normalized,
            type: .booklore,
            username: resolvedUsername,
            token: response.accessToken,
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .sso,
            grimmoryOIDCRedirectURI: storedRedirectURI
        )
        let finalConnection = try await validatedConnection(from: tempConnection)

        if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
            KeychainHelper.shared.set(refreshToken, key: "booklore_refresh_\(finalConnection.id.uuidString)")
        }

        return finalConnection
    }

    private func validatedConnection(from tempConnection: ServerConnection) async throws -> ServerConnection {
        let (isValid, validatedConnection) = try await appState.validateConnection(tempConnection)
        guard isValid else {
            throw NSError(
                domain: "UnifiedLogin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Connection failed. Please check your credentials."]
            )
        }

        var finalConnection = validatedConnection
        finalConnection.isConnected = true
        finalConnection.lastVerified = Date()
        return finalConnection
    }

    private func validateGrimmoryHeaders(_ headers: [String: String]?) throws {
        if ServerConnection.headerValue(in: headers, for: "Authorization")?.isEmpty == false {
            throw GrimmoryLoginError.conflictingAuthorizationHeader
        }
    }

    private func normalizedURL(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { return value }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    @MainActor
    private func presentGrimmoryAuthentication(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    let authErr = error as? ASWebAuthenticationSessionError
                    if authErr?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.networkError(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.invalidResponse)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = OAuthManager.shared
            session.prefersEphemeralWebBrowserSession = false
            if session.start() {
                grimmoryAuthSession = session
            } else {
                continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start authentication session"))
            }
        }
    }

    private func fetchGrimmoryPublicSettings(serverURL: String, customHeaders: [String: String]?) async throws -> GrimmoryPublicSettings {
        guard let url = URL(string: "\(serverURL)/api/v1/public-settings") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyHeaders(customHeaders, to: &request)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.authorizationFailed("Failed to fetch Grimmory OIDC settings.")
        }

        return try JSONDecoder().decode(GrimmoryPublicSettings.self, from: data)
    }

    private func fetchGrimmoryOIDCState(serverURL: String, customHeaders: [String: String]?) async throws -> String {
        guard let url = URL(string: "\(serverURL)/api/v1/auth/oidc/state") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyHeaders(customHeaders, to: &request)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.authorizationFailed("Failed to start Grimmory OIDC login.")
        }

        return try JSONDecoder().decode(GrimmoryOIDCStateResponse.self, from: data).state
    }

    private func buildGrimmoryOIDCAuthURL(
        provider: GrimmoryOIDCProviderDetails,
        redirectURI: String,
        codeChallenge: String,
        state: String,
        nonce: String
    ) async throws -> URL {
        let issuer = provider.issuerUri.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
        guard !issuer.isEmpty else {
            throw OAuthError.invalidConfiguration
        }

        let discoveryURL = URL(string: "\(issuer)/.well-known/openid-configuration")!
        let (discoveryData, _) = try await InsecureURLSession.shared.data(for: URLRequest(url: discoveryURL))
        let discovery = try JSONDecoder().decode(GrimmoryOIDCDiscoveryDocument.self, from: discoveryData)

        guard var components = URLComponents(string: discovery.authorizationEndpoint) else {
            throw OAuthError.invalidConfiguration
        }

        let scopes = provider.scopes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedScopes = scopes?.isEmpty == false ? scopes : "openid profile email groups"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: provider.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]

        guard let authURL = components.url else {
            throw OAuthError.invalidConfiguration
        }
        return authURL
    }

    private func exchangeGrimmoryOIDCCode(
        serverURL: String,
        code: String,
        codeVerifier: String,
        nonce: String,
        state: String,
        redirectURI: String,
        customHeaders: [String: String]?
    ) async throws -> GrimmoryOIDCTokenResponse {
        guard let url = URL(string: "\(serverURL)/api/v1/auth/oidc/callback") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(customHeaders, to: &request)

        let body: [String: String] = [
            "code": code,
            "codeVerifier": codeVerifier,
            "redirectUri": redirectURI,
            "nonce": nonce,
            "state": state,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Authentication failed"
            throw OAuthError.authorizationFailed(message)
        }

        return try JSONDecoder().decode(GrimmoryOIDCTokenResponse.self, from: data)
    }

    private func fetchGrimmoryUsername(serverURL: String, accessToken: String, customHeaders: [String: String]?) async throws -> String? {
        guard let url = URL(string: "\(serverURL)/api/v1/users/me") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(customHeaders, to: &request)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        let profile = try JSONDecoder().decode(GrimmoryUserProfile.self, from: data)
        return profile.username
    }

    private func applyHeaders(_ headers: [String: String]?, to request: inout URLRequest) {
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func randomPKCEVerifier(length: Int = 64) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private func pkceChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct GrimmoryPublicSettings: Decodable {
        let oidcEnabled: Bool
        let oidcProviderDetails: GrimmoryOIDCProviderDetails?
    }

    private struct GrimmoryOIDCProviderDetails: Decodable {
        let providerName: String?
        let clientId: String
        let issuerUri: String
        let scopes: String?
    }

    private struct GrimmoryOIDCDiscoveryDocument: Decodable {
        let authorizationEndpoint: String

        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint"
        }
    }

    private struct GrimmoryOIDCStateResponse: Decodable {
        let state: String
    }

    private struct GrimmoryOIDCTokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
    }

    private struct GrimmoryUserProfile: Decodable {
        let username: String?
    }
}

private enum GrimmoryLoginError: LocalizedError {
    case invalidToken
    case conflictingAuthorizationHeader

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Grimmory requires a three-part JWT. Paste the token with or without the Bearer prefix."
        case .conflictingAuthorizationHeader:
            return
                "Remove the custom Authorization header. Use the Cloudflare service-token fields or browser sign-in for proxy authentication."
        }
    }
}

final class BookOrbitLoginDelegate: UnifiedLoginDelegate {
    private let appState: AppState
    @MainActor private var bookOrbitAuthSession: ASWebAuthenticationSession?

    init(appState: AppState) {
        self.appState = appState
    }

    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let tempConnection = ServerConnection(
            name: "BookOrbit",
            url: normalizedURL(serverURL),
            type: .bookOrbit,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            token: nil,
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .usernamePassword
        )
        return try await validatedConnection(from: tempConnection)
    }

    func authenticateWithOIDC(
        serverURL: String,
        redirectURIOverride: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        _ = redirectURIOverride
        let normalized = normalizedURL(serverURL)
        let provider = try await fetchPublicOIDCProvider(serverURL: normalized, customHeaders: customHeaders)
        let stateResponse = try await fetchOIDCState(serverURL: normalized, providerSlug: provider.slug, customHeaders: customHeaders)
        let codeVerifier = randomPKCEVerifier()
        let codeChallenge = pkceChallenge(from: codeVerifier)
        let nonce = randomPKCEVerifier(length: 32)
        let redirectURI = oidcRedirectURI(for: normalized)
        let authURL = try buildOIDCAuthURL(
            authorizationEndpoint: stateResponse.authorizationEndpoint,
            provider: provider,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: stateResponse.state,
            nonce: nonce
        )

        let callbackURL = try await presentAuthentication(url: authURL, callbackScheme: URL(string: redirectURI)?.scheme ?? "https")
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidResponse
        }
        if let authError = callbackComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            throw OAuthError.authorizationFailed(authError)
        }
        guard callbackURL.absoluteString.hasPrefix(redirectURI),
            let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw OAuthError.invalidResponse
        }

        let exchanged = try await exchangeOIDCCode(
            serverURL: normalized,
            code: code,
            codeVerifier: codeVerifier,
            nonce: nonce,
            state: stateResponse.state,
            redirectURI: redirectURI,
            customHeaders: customHeaders
        )

        let tempConnection = ServerConnection(
            name: "BookOrbit",
            url: normalized,
            type: .bookOrbit,
            username: exchanged.user.username,
            token: exchanged.accessToken,
            userId: String(exchanged.user.id),
            isConnected: false,
            customHeaders: customHeaders,
            authMode: .sso
        )
        let finalConnection = try await validatedConnection(from: tempConnection)

        if let refreshToken = exchanged.refreshToken, !refreshToken.isEmpty {
            KeychainHelper.shared.set(refreshToken, key: "bookorbit_refresh_\(finalConnection.id.uuidString)")
        }

        return finalConnection
    }

    private func validatedConnection(from tempConnection: ServerConnection) async throws -> ServerConnection {
        let (isValid, validatedConnection) = try await appState.validateConnection(tempConnection)
        guard isValid else {
            throw NSError(
                domain: "UnifiedLogin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Connection failed. Please check your credentials."]
            )
        }

        var finalConnection = validatedConnection
        finalConnection.isConnected = true
        finalConnection.lastVerified = Date()
        return finalConnection
    }

    private func normalizedURL(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { return value }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    private func oidcRedirectURI(for serverURL: String) -> String {
        serverURL + AppAuthRedirectURI.bookOrbitCallbackPath
    }

    private func fetchPublicOIDCProvider(serverURL: String, customHeaders: [String: String]?) async throws -> BookOrbitOIDCProvider {
        guard let url = URL(string: "\(serverURL)/api/v1/app-settings/oidc/providers/public") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(customHeaders, to: &request)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.authorizationFailed("Failed to fetch BookOrbit SSO providers.")
        }

        let providers = try JSONDecoder().decode([BookOrbitOIDCProvider].self, from: data)
        guard let provider = providers.first(where: { $0.enabled }) ?? providers.first else {
            throw OAuthError.authorizationFailed("No enabled BookOrbit SSO providers were found.")
        }
        return provider
    }

    private func fetchOIDCState(
        serverURL: String,
        providerSlug: String,
        customHeaders: [String: String]?
    ) async throws -> BookOrbitOIDCStateResponse {
        guard let slug = providerSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "\(serverURL)/api/v1/auth/oidc/\(slug)/state")
        else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(customHeaders, to: &request)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.authorizationFailed("Failed to start BookOrbit SSO login.")
        }

        return try JSONDecoder().decode(BookOrbitOIDCStateResponse.self, from: data)
    }

    private func buildOIDCAuthURL(
        authorizationEndpoint: String,
        provider: BookOrbitOIDCProvider,
        redirectURI: String,
        codeChallenge: String,
        state: String,
        nonce: String
    ) throws -> URL {
        guard var components = URLComponents(string: authorizationEndpoint) else {
            throw OAuthError.invalidConfiguration
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: provider.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: provider.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]

        guard let authURL = components.url else {
            throw OAuthError.invalidConfiguration
        }
        return authURL
    }

    @MainActor
    private func presentAuthentication(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    let authErr = error as? ASWebAuthenticationSessionError
                    if authErr?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.networkError(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.invalidResponse)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = OAuthManager.shared
            session.prefersEphemeralWebBrowserSession = false
            if session.start() {
                bookOrbitAuthSession = session
            } else {
                continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start authentication session"))
            }
        }
    }

    private func exchangeOIDCCode(
        serverURL: String,
        code: String,
        codeVerifier: String,
        nonce: String,
        state: String,
        redirectURI: String,
        customHeaders: [String: String]?
    ) async throws -> BookOrbitOIDCTokenResponse {
        guard let url = URL(string: "\(serverURL)/api/v1/auth/oidc/callback") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(customHeaders, to: &request)

        let body: [String: String] = [
            "code": code,
            "codeVerifier": codeVerifier,
            "redirectUri": redirectURI,
            "nonce": nonce,
            "state": state,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Authentication failed"
            throw OAuthError.authorizationFailed(message)
        }

        var tokenResponse = try JSONDecoder().decode(BookOrbitOIDCTokenResponse.self, from: data)
        tokenResponse.refreshToken = refreshToken(from: http, requestURL: request.url)
        return tokenResponse
    }

    private func refreshToken(from response: HTTPURLResponse, requestURL: URL?) -> String? {
        guard let requestURL,
            let fields = response.allHeaderFields as? [String: String]
        else { return nil }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: requestURL)
        return cookies.first(where: { $0.name == "refresh_token" })?.value
    }

    private func applyHeaders(_ headers: [String: String]?, to request: inout URLRequest) {
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func randomPKCEVerifier(length: Int = 64) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private func pkceChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct BookOrbitOIDCProvider: Decodable {
        let slug: String
        let displayName: String?
        let enabled: Bool
        let clientId: String
        let scopes: String
    }

    private struct BookOrbitOIDCStateResponse: Decodable {
        let state: String
        let authorizationEndpoint: String
    }

    private struct BookOrbitOIDCTokenResponse: Decodable {
        let mode: String
        let accessToken: String
        let user: BookOrbitUser
        var refreshToken: String?
    }

    private struct BookOrbitUser: Decodable {
        let id: Int
        let username: String
    }
}

final class EmbyLoginDelegate: UnifiedLoginDelegate {
    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let normalizedURL = EmbyProvider.normalizeServerURL(serverURL)

        let token = try await EmbyProvider.shared.authenticate(
            serverURL: normalizedURL,
            username: username,
            password: password
        )

        let backend = BackendConfig(
            id: UUID().uuidString,
            name: "Emby",
            type: .emby,
            url: normalizedURL,
            token: token,
            enabled: true,
            username: username,
            password: password,
            userId: nil,
            selectedLibraryIds: nil
        )

        let embyService = EmbyService.shared
        _ = try await embyService.validateToken(backend: backend)
        let currentUser = try await embyService.getCurrentUser(backend: backend)

        return ServerConnection(
            name: "Emby",
            url: normalizedURL,
            type: .emby,
            username: username,
            password: password,
            token: token,
            userId: currentUser.Id,
            isConnected: true,
            lastVerified: Date(),
            authMode: .usernamePassword
        )
    }

    func fetchLibraries(connection: ServerConnection) async throws -> [LibraryMetadata] {
        let backend = BackendConfig(
            id: connection.id.uuidString,
            name: connection.name,
            type: .emby,
            url: connection.url,
            token: connection.token,
            enabled: true,
            username: connection.username,
            password: nil,
            userId: connection.userId,
            selectedLibraryIds: nil
        )
        let userId = connection.userId ?? ""
        let libraries = try await EmbyService.shared.getLibraries(backend: backend, userId: userId)
        let audioLibraries = libraries.filter { $0.type == .audiobooks || $0.type == .books }
        return audioLibraries.isEmpty ? libraries : audioLibraries
    }
}

final class JellyfinLoginDelegate: UnifiedLoginDelegate {
    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let normalizedURL = normalizeURL(serverURL)
        let result = try await authenticateJellyfin(
            serverURL: normalizedURL,
            username: username,
            password: password,
            customHeaders: customHeaders ?? [:]
        )

        return ServerConnection(
            name: "Jellyfin",
            url: normalizedURL,
            type: .jellyfin,
            username: username,
            token: result.token,
            userId: result.userId,
            isConnected: true,
            lastVerified: Date(),
            customHeaders: customHeaders,
            authMode: .usernamePassword
        )
    }

    func startQuickConnect(serverURL: String, customHeaders: [String: String]?) async throws -> (code: String, secret: String) {
        let normalizedURL = normalizeURL(serverURL)
        let headers = customHeaders ?? [:]

        let enabled = try await JellyfinQuickConnectService.shared.isQuickConnectEnabled(
            serverURL: normalizedURL,
            customHeaders: headers
        )
        guard enabled else {
            throw NSError(
                domain: "Jellyfin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Quick Connect is not enabled on this server."]
            )
        }

        let result = try await JellyfinQuickConnectService.shared.initiateQuickConnect(
            serverURL: normalizedURL,
            customHeaders: headers
        )
        return (code: result.Code, secret: result.Secret)
    }

    func pollQuickConnect(secret: String, serverURL: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        let normalizedURL = normalizeURL(serverURL)
        let headers = customHeaders ?? [:]

        let approvedSecret = try await JellyfinQuickConnectService.shared.pollForAuthentication(
            secret: secret,
            serverURL: normalizedURL,
            customHeaders: headers,
            cancellationCheck: { Task.isCancelled }
        )

        let authResult = try await JellyfinQuickConnectService.shared.authenticateWithQuickConnect(
            secret: approvedSecret,
            serverURL: normalizedURL,
            customHeaders: headers
        )

        return ServerConnection(
            name: "Jellyfin",
            url: normalizedURL,
            type: .jellyfin,
            username: authResult.userName,
            token: authResult.token,
            userId: authResult.userId,
            isConnected: true,
            lastVerified: Date(),
            customHeaders: headers.isEmpty ? nil : headers,
            authMode: .sso
        )
    }

    func fetchLibraries(connection: ServerConnection) async throws -> [LibraryMetadata] {
        let url = connection.url
        let token = connection.token ?? ""
        let userId = connection.userId ?? ""
        let headers = connection.customHeaders ?? [:]

        guard let requestURL = URL(string: "\(url)/Users/\(userId)/Views") else {
            throw NSError(domain: "Jellyfin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 30
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let deviceId = deviceIdentifier
        let deviceName = deviceDisplayName
        let authHeader =
            "MediaBrowser Client=\"Enve\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(token)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "Jellyfin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch libraries"])
        }

        struct ViewsResponse: Decodable { let Items: [ViewItem] }
        struct ViewItem: Decodable { let Id: String; let Name: String; let CollectionType: String? }

        let views = try JSONDecoder().decode(ViewsResponse.self, from: data)
        return views.Items.map { item in
            let type: LibraryType
            switch item.CollectionType?.lowercased() {
            case "books", "audiobooks": type = .audiobooks
            case "movies": type = .movies
            case "tvshows": type = .tvshows
            case "music": type = .music
            default: type = .mixed
            }
            return LibraryMetadata(
                id: item.Id,
                name: item.Name,
                type: type,
                itemCount: 0,
                audioBookCount: 0,
                collectionType: item.CollectionType
            )
        }
    }

    private func normalizeURL(_ input: String) -> String {
        var url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
            if url.contains(":8920") {
                url = "https://" + url
            } else if url.contains(":8096") {
                url = "http://" + url
            } else {
                let isLocal =
                    url.hasPrefix("192.") || url.hasPrefix("10.") || url.hasPrefix("172.") || url.hasPrefix("localhost")
                    || url.hasPrefix("127.")
                url = (isLocal ? "http://" : "https://") + url
            }
        }
        return url
    }

    private func authenticateJellyfin(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws -> (token: String, userId: String) {
        guard let authURL = URL(string: "\(serverURL)/Users/AuthenticateByName") else {
            throw NSError(domain: "Jellyfin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }

        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        for (key, value) in customHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let authHeader = "MediaBrowser Client=\"Enve\", Device=\"\(deviceDisplayName)\", DeviceId=\"\(deviceIdentifier)\", Version=\"1.0\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")

        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Jellyfin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw NSError(domain: "Jellyfin", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid username or password"])
            }
            throw NSError(
                domain: "Jellyfin",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server returned error \(httpResponse.statusCode)"]
            )
        }

        struct AuthResponse: Decodable {
            let AccessToken: String; let User: UserR; struct UserR: Decodable { let Id: String; let Name: String? }
        }
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        return (token: auth.AccessToken, userId: auth.User.Id)
    }

    private var deviceIdentifier: String {
        #if canImport(UIKit)
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        UUID().uuidString
        #endif
    }

    private var deviceDisplayName: String {
        #if canImport(UIKit)
        UIDevice.current.name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #else
        "Enve Client"
        #endif
    }
}

final class AudiobookshelfLoginDelegate: UnifiedLoginDelegate {
    @MainActor private var absAuthSession: ASWebAuthenticationSession?

    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let user = try await AudiobookshelfService.shared.login(
            username: username,
            password: password,
            serverURL: serverURL,
            customHeaders: customHeaders ?? [:]
        )

        let resolvedToken = user.accessToken ?? user.token
        guard let resolvedToken, !resolvedToken.isEmpty else {
            throw AudiobookshelfError.authenticationFailed
        }

        return buildConnection(
            token: resolvedToken,
            refreshToken: user.refreshToken,
            userId: user.id,
            username: user.username,
            serverURL: serverURL,
            customHeaders: customHeaders,
            authMode: .usernamePassword
        )
    }

    func authenticateWithOIDC(
        serverURL: String,
        redirectURIOverride: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        _ = redirectURIOverride
        guard serverURL.lowercased().hasPrefix("https://") else {
            throw NSError(domain: "ABS", code: -1, userInfo: [NSLocalizedDescriptionKey: "OIDC requires an HTTPS server URL."])
        }

        let verifier = randomPKCEVerifier()
        let challenge = pkceChallenge(from: verifier)
        let expectedState = randomStateParameter()
        let callbackScheme = AppAuthRedirectURI.absScheme
        let redirectURI = AppAuthRedirectURI.audiobookshelf

        let preflight = try await AudiobookshelfService.shared.preflightOIDC(
            serverURL: serverURL,
            challenge: challenge,
            redirectURI: redirectURI,
            state: expectedState,
            customHeaders: customHeaders ?? [:]
        )

        let callbackURL = try await presentOIDCAuth(
            url: preflight.authorizationURL,
            callbackScheme: callbackScheme
        )

        guard let cb = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AudiobookshelfError.invalidResponse
        }
        if let authErr = cb.queryItems?.first(where: { $0.name == "error" })?.value {
            throw AudiobookshelfError.uploadFailed(authErr)
        }
        guard let code = cb.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AudiobookshelfError.invalidResponse
        }
        let returnedState = cb.queryItems?.first(where: { $0.name == "state" })?.value

        let user = try await AudiobookshelfService.shared.loginWithOIDC(
            serverURL: serverURL,
            code: code,
            verifier: verifier,
            state: returnedState,
            cookies: preflight.cookies,
            customHeaders: customHeaders ?? [:]
        )

        let resolvedToken = user.accessToken ?? user.token
        guard let resolvedToken, !resolvedToken.isEmpty else {
            throw AudiobookshelfError.authenticationFailed
        }

        return buildConnection(
            token: resolvedToken,
            refreshToken: user.refreshToken,
            userId: user.id,
            username: user.username,
            serverURL: serverURL,
            customHeaders: customHeaders,
            authMode: .sso
        )
    }

    private func buildConnection(
        token: String,
        refreshToken: String?,
        userId: String,
        username: String,
        serverURL: String,
        customHeaders: [String: String]?,
        authMode: ConnectionAuthMode
    ) -> ServerConnection {
        let connection = ServerConnection(
            name: "Audiobookshelf",
            url: serverURL,
            type: .audiobookshelf,
            username: username,
            token: token,
            userId: userId,
            isConnected: true,
            lastVerified: Date(),
            customHeaders: customHeaders,
            authMode: authMode
        )

        if let refreshToken, !refreshToken.isEmpty {
            KeychainHelper.shared.set(refreshToken, key: "abs_refresh_\(connection.id.uuidString)")
        }

        return connection
    }

    @MainActor
    private func presentOIDCAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    let authErr = error as? ASWebAuthenticationSessionError
                    if authErr?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.networkError(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.invalidResponse)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = OAuthManager.shared
            session.prefersEphemeralWebBrowserSession = false
            if session.start() {
                absAuthSession = session
            } else {
                continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start auth session"))
            }
        }
    }

    private func randomPKCEVerifier(length: Int = 64) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private func pkceChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomStateParameter() -> String {
        UUID().uuidString
    }
}

final class StorytellerLoginDelegate: UnifiedLoginDelegate {
    @MainActor private var storytellerAuthSession: ASWebAuthenticationSession?

    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let conn = ServerConnection(name: "Storyteller", url: serverURL, type: .storyteller, username: username, password: password)
        let provider = StorytellerProvider(connection: conn)
        let token = try await provider.loginWithCredentials(usernameOrEmail: username, password: password)

        var authedConn = conn
        authedConn.token = token
        let authedProvider = StorytellerProvider(connection: authedConn)
        let user = try await authedProvider.fetchCurrentUser()

        return ServerConnection(
            name: "Storyteller",
            url: serverURL,
            type: .storyteller,
            username: username,
            password: password,
            token: token,
            userId: user.id,
            isConnected: true,
            lastVerified: Date(),
            authMode: .usernamePassword
        )
    }

    func authenticateWithWebLogin(serverURL: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        guard let authURL = URL(string: "\(serverURL)/api/v2/token/app") else {
            throw NSError(domain: "Storyteller", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }

        let callbackURL = try await presentWebAuth(url: authURL, callbackScheme: "storyteller")

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let shortToken = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            throw NSError(domain: "Storyteller", code: -1, userInfo: [NSLocalizedDescriptionKey: "No token received from login"])
        }

        let conn = ServerConnection(name: "Storyteller", url: serverURL, type: .storyteller)
        let provider = StorytellerProvider(connection: conn)
        let longToken = try await provider.exchangeAppToken(shortToken)

        var authedConn = conn
        authedConn.token = longToken
        let authedProvider = StorytellerProvider(connection: authedConn)
        let user = try await authedProvider.fetchCurrentUser()

        return ServerConnection(
            name: "Storyteller",
            url: serverURL,
            type: .storyteller,
            username: user.username,
            token: longToken,
            userId: user.id,
            isConnected: true,
            lastVerified: Date(),
            authMode: .sso
        )
    }

    @MainActor
    private func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    let authErr = error as? ASWebAuthenticationSessionError
                    if authErr?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.networkError(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.invalidResponse)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = OAuthManager.shared
            session.prefersEphemeralWebBrowserSession = false
            if session.start() {
                storytellerAuthSession = session
            } else {
                continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start authentication session"))
            }
        }
    }
}
