// AGENT-LOCKED
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Logging

private enum OAuthCredentials {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "DeveloperSettings", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let values = plist as? [String: String]
        else {
            return [:]
        }
        return values
    }()

    static var googleDriveClientID: String { value(for: "GoogleDriveClientID") }
    static var dropboxAppKey: String { value(for: "DropboxAppKey") }
    static var redirectScheme: String {
        let configured = value(for: "OAuthRedirectScheme")
        return configured.isEmpty ? "com.enve.enve" : configured
    }

    private static func value(for key: String) -> String {
        values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum AppAuthRedirectURI {
    static var scheme: String { OAuthCredentials.redirectScheme }
    static let absScheme = "enveapp"
    static let audiobookshelf = "enveapp://oauth/abs"
    static let grimmory = "booklore://oauth2-callback"
    static let grimmoryScheme = "booklore"

    static let grimmoryNew = "grimmory://oauth2-callback"
    static let grimmoryNewScheme = "grimmory"

    static let grimmoryEnveSpecific = "enveapp://oauth/grimmory"
    static let bookOrbitCallbackPath = "/oauth2-callback"

    static let grimmoryPresetOptions: [String] = [
        grimmory,
        grimmoryNew,
        grimmoryEnveSpecific,
    ]

    static func scheme(for redirectURI: String) -> String {
        URLComponents(string: redirectURI)?.scheme ?? grimmoryScheme
    }
}

struct OAuthConfig: Sendable {
    let clientId: String
    let clientSecret: String?
    let redirectUri: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let scopes: [String]
    let usePKCE: Bool

    static func googleDrive() -> OAuthConfig {
        return OAuthConfig(
            clientId: OAuthCredentials.googleDriveClientID,
            clientSecret: nil,
            redirectUri: "\(OAuthCredentials.redirectScheme):/oauth/google",
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: ["https://www.googleapis.com/auth/drive.readonly"],
            usePKCE: true
        )
    }

    static func dropbox() -> OAuthConfig {
        return OAuthConfig(
            clientId: OAuthCredentials.dropboxAppKey,
            clientSecret: nil,
            redirectUri: "\(OAuthCredentials.redirectScheme):/oauth/dropbox",
            authorizationEndpoint: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
            tokenEndpoint: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            scopes: ["files.content.read", "files.metadata.read"],
            usePKCE: true
        )
    }
}

struct OAuthToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String
    let scope: String?
    let issuedAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }

    init(accessToken: String, refreshToken: String?, expiresIn: Int?, tokenType: String, scope: String?, issuedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
        self.issuedAt = issuedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        tokenType = try container.decode(String.self, forKey: .tokenType)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        issuedAt = Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(expiresIn, forKey: .expiresIn)
        try container.encode(tokenType, forKey: .tokenType)
        try container.encodeIfPresent(scope, forKey: .scope)
    }

    var isExpired: Bool {
        guard let expiresIn = expiresIn else { return false }
        let expirationDate = issuedAt.addingTimeInterval(TimeInterval(expiresIn))
        return Date() >= expirationDate
    }

    var expiresAt: Date? {
        guard let expiresIn = expiresIn else { return nil }
        return issuedAt.addingTimeInterval(TimeInterval(expiresIn))
    }
}

enum OAuthError: LocalizedError {
    case userCancelled
    case invalidConfiguration
    case invalidResponse
    case networkError(Error)
    case authorizationFailed(String)
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Authentication cancelled by user"
        case .invalidConfiguration:
            return "OAuth credentials not configured. Please set up your client ID and secret in OAuthManager.swift"
        case .invalidResponse:
            return "Invalid response from authorization server"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .authorizationFailed(let message):
            return "Authorization failed: \(message)"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .refreshFailed(let message):
            return "Token refresh failed: \(message)"
        case .missingRefreshToken:
            return "No refresh token available"
        }
    }
}

@MainActor
final class OAuthManager: NSObject, ObservableObject {
    static let shared = OAuthManager()

    @Published private(set) var isAuthenticating = false

    private var authSession: ASWebAuthenticationSession?
    private let session = URLSession.shared

    private override init() {
        super.init()
    }

    func authorize(config: OAuthConfig) async throws -> OAuthToken {
        isAuthenticating = true
        defer { isAuthenticating = false }

        if config.clientId.contains("YOUR_") || config.clientId.isEmpty {
            throw OAuthError.invalidConfiguration
        }
        if let secret = config.clientSecret, secret.contains("YOUR_") || secret.isEmpty {
            throw OAuthError.invalidConfiguration
        }

        let pkce = config.usePKCE ? generatePKCE() : nil

        let state = generateSecureRandom(length: 32)

        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "state", value: state),
        ]

        if let pkce = pkce {
            queryItems.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }

        components?.queryItems = queryItems

        guard let authURL = components?.url else {
            throw OAuthError.invalidConfiguration
        }

        let callbackScheme = config.redirectUri.components(separatedBy: ":").first ?? config.redirectUri

        let (authCode, returnedState) = try await presentAuthenticationUI(authURL: authURL, callbackScheme: callbackScheme)

        guard returnedState == state else {
            throw OAuthError.authorizationFailed("State parameter mismatch. Possible CSRF attack")
        }

        return try await exchangeCodeForToken(
            code: authCode,
            config: config,
            codeVerifier: pkce?.verifier
        )
    }

    private func presentAuthenticationUI(authURL: URL, callbackScheme: String) async throws -> (code: String, state: String?) {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    let asError = error as? ASWebAuthenticationSessionError
                    if asError?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.networkError(error))
                    }
                    return
                }

                guard let callbackURL = callbackURL,
                    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                    let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: OAuthError.invalidResponse)
                    return
                }

                let state = components.queryItems?.first(where: { $0.name == "state" })?.value
                continuation.resume(returning: (code: code, state: state))
            }

            #if os(iOS)
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            #endif

            if !session.start() {
                continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start authentication session"))
            }

            self.authSession = session
        }
    }

    private func exchangeCodeForToken(
        code: String,
        config: OAuthConfig,
        codeVerifier: String?
    ) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var parameters = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientId,
            "redirect_uri": config.redirectUri,
        ]

        if let codeVerifier = codeVerifier {
            parameters["code_verifier"] = codeVerifier
        }

        if let clientSecret = config.clientSecret {
            parameters["client_secret"] = clientSecret
        }

        request.httpBody =
            parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLogger.network.error("OAuth token exchange failed: HTTP \(httpResponse.statusCode)")
            throw OAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        if String(data: data, encoding: .utf8) != nil {
            AppLogger.network.info("OAuth token response received (\(data.count) bytes)")
        }

        do {
            let token = try JSONDecoder().decode(OAuthToken.self, from: data)
            AppLogger.network.info("Successfully decoded OAuth token")
            return token
        } catch {
            AppLogger.network.error("Failed to decode OAuth token: \(error)")
            AppLogger.network.info("Raw response: <redacted, \(data.count) bytes>")
            throw OAuthError.tokenExchangeFailed("Failed to decode token: \(error.localizedDescription)")
        }
    }

    func refreshToken(refreshToken: String, config: OAuthConfig) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientId,
        ]

        if let clientSecret = config.clientSecret {
            parameters["client_secret"] = clientSecret
        }

        request.httpBody =
            parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthError.refreshFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        var token = try JSONDecoder().decode(OAuthToken.self, from: data)
        if token.refreshToken == nil {
            token = OAuthToken(
                accessToken: token.accessToken,
                refreshToken: refreshToken,
                expiresIn: token.expiresIn,
                tokenType: token.tokenType,
                scope: token.scope,
                issuedAt: Date()
            )
        } else {
            token = OAuthToken(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresIn: token.expiresIn,
                tokenType: token.tokenType,
                scope: token.scope,
                issuedAt: Date()
            )
        }

        return token
    }

    private struct PKCEPair {
        let verifier: String
        let challenge: String
    }

    private func generatePKCE() -> PKCEPair {
        let verifier = generateSecureRandom(length: 64)

        let challengeData = Data(verifier.utf8)
        let hash = SHA256.hash(data: challengeData)
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    private func generateSecureRandom(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let allWindows = scenes.flatMap { $0.windows }
        if let keyWindow = allWindows.first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        if let firstWindow = allWindows.first {
            return firstWindow
        }
        if let firstScene = scenes.first {
            return ASPresentationAnchor(windowScene: firstScene)
        }
        AppLogger.general.error("No UIWindowScene available for OAuth presentation; using fallback anchor")
        return ASPresentationAnchor(frame: .zero)
    }
}
#endif
