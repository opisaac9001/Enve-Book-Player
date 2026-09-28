import AuthenticationServices
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

nonisolated enum OPDSAuthenticationError: LocalizedError, Equatable {
    case flowNotSupported(String)
    case missingEndpoint
    case untrustedEndpoint(String)
    case rejected(String)
    case cancelled
    case noToken
    case randomnessUnavailable

    var errorDescription: String? {
        switch self {
        case .flowNotSupported(let type): "Enve cannot sign in with \(type)."
        case .missingEndpoint: "The server did not say where to sign in."
        case .untrustedEndpoint(let host):
            "Enve will not send sign-in details to \(host) over an unencrypted connection."
        case .rejected(let message): message
        case .cancelled: "Sign-in was cancelled."
        case .noToken: "The server completed sign-in without returning a token."
        case .randomnessUnavailable: "Enve could not start the sign-in securely. Try again."
        }
    }
}

/// URLSession handles Basic/Digest; this service exchanges and refreshes OAuth tokens.
@MainActor
final class OPDSAuthenticationService: NSObject {
    static let shared = OPDSAuthenticationService()

    /// The OPDS Authentication 1.0 identifier every client presenting this specification must use.
    static let clientIdentifier = "http://opds-spec.org/auth/client"
    /// The trailing slash is part of the redirect URI the specification registers.
    static let callbackURL = URL(string: "\(EnveBookLink.scheme)://opds-auth/")!

    private let store: OPDSAuthenticationStore
    private var browserSession: ASWebAuthenticationSession?
    private var pendingBrowserFlow: CheckedContinuation<URL, Error>?
    /// One refresh per connection at a time, so a sync pass and a catalog load do not race for the token.
    private var refreshTasks: [UUID: Task<OAuthToken?, Never>] = [:]

    init(store: OPDSAuthenticationStore = .shared) {
        self.store = store
        super.init()
    }

    // MARK: Credential flows

    /// Returns nil for Basic/Digest; feedURL constrains where a credential exchange may send the password.
    func signIn(
        connectionId: UUID,
        flow: OPDSAuthenticationFlow,
        login: String,
        password: String,
        documentURL: URL?,
        feedURL: URL
    ) async throws -> OAuthToken? {
        switch flow.kind {
        case .httpCredentials:
            store.setSession(
                OPDSAuthenticationStore.Session(
                    flowType: flow.type,
                    documentURL: documentURL ?? store.session(for: connectionId)?.documentURL,
                    accountLabel: login
                ),
                for: connectionId
            )
            store.setToken(nil, for: connectionId)
            store.recordChallenge(nil, for: connectionId)
            return nil

        case .local, .oauthPassword:
            guard let endpoint = flow.authenticateURL else { throw OPDSAuthenticationError.missingEndpoint }
            var parameters = ["username": login, "password": password]
            // `local` is the same exchange without a grant: the server checks the credentials itself.
            if flow.kind == .oauthPassword { parameters["grant_type"] = "password" }
            let token = try await exchange(parameters, at: endpoint, feedURL: feedURL)
            adopt(token, flow: flow, documentURL: documentURL, accountLabel: login, for: connectionId)
            return token

        case .oauthImplicit:
            throw OPDSAuthenticationError.flowNotSupported(flow.type)
        case .unsupported:
            throw OPDSAuthenticationError.flowNotSupported(flow.type)
        }
    }

    // MARK: Implicit flow

    func signInWithBrowser(
        connectionId: UUID,
        flow: OPDSAuthenticationFlow,
        documentURL: URL?,
        feedURL: URL
    ) async throws -> OAuthToken {
        guard flow.kind == .oauthImplicit else { throw OPDSAuthenticationError.flowNotSupported(flow.type) }
        guard let endpoint = flow.authenticateURL else { throw OPDSAuthenticationError.missingEndpoint }
        guard OPDSCredentialTransport.isPostable(endpoint, feedURL: feedURL) else {
            throw OPDSAuthenticationError.untrustedEndpoint(endpoint.host ?? "that server")
        }

        guard let state = Self.nonce() else { throw OPDSAuthenticationError.randomnessUnavailable }
        guard let authorizationURL = Self.authorizationURL(endpoint: endpoint, state: state) else {
            throw OPDSAuthenticationError.missingEndpoint
        }

        let callback = try await presentBrowser(at: authorizationURL)
        guard let token = Self.token(inCallback: callback, expectedState: state) else {
            throw OPDSAuthenticationError.noToken
        }
        adopt(token, flow: flow, documentURL: documentURL, accountLabel: nil, for: connectionId)
        return token
    }

    /// Handle relaunch callbacks as well as sheet redirects; return whether a flow consumed the URL.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard Self.isCallback(url), let pending = pendingBrowserFlow else { return false }
        pendingBrowserFlow = nil
        // `cancel()` is unavailable on tvOS, which has no sign-in sheet to start a browser flow from.
        #if !os(tvOS)
        browserSession?.cancel()
        #endif
        browserSession = nil
        pending.resume(returning: url)
        return true
    }

    static func isCallback(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(callbackURL.scheme ?? "") == .orderedSame
            && url.host?.caseInsensitiveCompare(callbackURL.host ?? "") == .orderedSame
    }

    // MARK: Refresh

    /// Refresh expired tokens when an endpoint is available; return nil when no token can be sent.
    @discardableResult
    func validToken(for connectionId: UUID, feedURL: URL) async -> OAuthToken? {
        if let token = store.token(for: connectionId), !token.isExpired { return token }
        if let existing = refreshTasks[connectionId] { return await existing.value }

        let task = Task<OAuthToken?, Never> { [weak self] in
            guard let self else { return nil }
            defer { self.refreshTasks[connectionId] = nil }
            return await self.performRefresh(for: connectionId, feedURL: feedURL)
        }
        refreshTasks[connectionId] = task
        return await task.value
    }

    private func performRefresh(for connectionId: UUID, feedURL: URL) async -> OAuthToken? {
        guard let session = store.session(for: connectionId),
            let endpoint = session.refreshURL,
            let stale = store.token(for: connectionId),
            let refreshToken = stale.refreshToken
        else { return nil }

        do {
            let refreshed = try await exchange(
                ["grant_type": "refresh_token", "refresh_token": refreshToken],
                at: endpoint,
                feedURL: feedURL
            )
            // A server that rotates nothing still expects the original refresh token next time.
            let merged = OAuthToken(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refreshToken,
                expiresIn: refreshed.expiresIn,
                tokenType: refreshed.tokenType,
                scope: refreshed.scope,
                issuedAt: refreshed.issuedAt
            )
            store.setToken(merged, for: connectionId)
            return merged
        } catch {
            AppLogger.network.warning("[OPDS] Token refresh failed; the connection needs a new sign-in")
            store.setToken(nil, for: connectionId)
            return nil
        }
    }

    // MARK: Internals

    /// Token responses may omit the authentication-document URL; retain the catalog's existing value.
    private func adopt(
        _ token: OAuthToken,
        flow: OPDSAuthenticationFlow,
        documentURL: URL?,
        accountLabel: String?,
        for connectionId: UUID
    ) {
        store.setToken(token, for: connectionId)
        store.setSession(
            OPDSAuthenticationStore.Session(
                flowType: flow.type,
                authenticateURL: flow.authenticateURL,
                refreshURL: flow.refreshURL,
                documentURL: documentURL ?? store.session(for: connectionId)?.documentURL,
                accountLabel: accountLabel
            ),
            for: connectionId
        )
        store.recordChallenge(nil, for: connectionId)
    }

    private func exchange(
        _ parameters: [String: String],
        at endpoint: URL,
        feedURL: URL
    ) async throws -> OAuthToken {
        guard OPDSCredentialTransport.isPostable(endpoint, feedURL: feedURL) else {
            throw OPDSAuthenticationError.untrustedEndpoint(endpoint.host ?? "that server")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthManager.formEncodedBody(parameters)

        let (data, http) = try await OPDSCredentialTransport.send(request)
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw OPDSAuthenticationError.rejected(Self.failureMessage(status: http.statusCode, data: data))
        }
        guard let token = Self.decodeToken(data) else { throw OPDSAuthenticationError.noToken }
        return token
    }

    private func presentBrowser(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            pendingBrowserFlow = continuation

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackURL.scheme
            ) { [weak self] callbackURL, error in
                guard let self, let pending = self.pendingBrowserFlow else { return }
                self.pendingBrowserFlow = nil
                self.browserSession = nil

                if let callbackURL {
                    pending.resume(returning: callbackURL)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    pending.resume(throwing: OPDSAuthenticationError.cancelled)
                } else {
                    pending.resume(throwing: error ?? OPDSAuthenticationError.noToken)
                }
            }
            #if os(iOS)
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            #endif
            browserSession = session

            if !session.start() {
                pendingBrowserFlow = nil
                browserSession = nil
                continuation.resume(throwing: OPDSAuthenticationError.cancelled)
            }
        }
    }

    static func authorizationURL(endpoint: URL, state: String) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else { return nil }
        var items = components.queryItems ?? []

        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }

        if !items.contains(where: { $0.name == "client_id" }) {
            items.append(URLQueryItem(name: "client_id", value: clientIdentifier))
        }
        set("response_type", "token")
        set("redirect_uri", callbackURL.absoluteString)
        set("state", state)

        components.queryItems = items
        return components.url
    }

    /// Accept tokens in the fragment or, for compatibility with some servers, the query.
    static func token(inCallback url: URL, expectedState: String?) -> OAuthToken? {
        var fields: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] {
            if let value = item.value { fields[item.name] = value }
        }
        for pair in (components?.fragment ?? "").split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<equals])
            let value = String(pair[pair.index(after: equals)...])
            fields[name] = value.removingPercentEncoding ?? value
        }

        if let expectedState, fields["state"] != expectedState { return nil }
        guard let accessToken = fields["access_token"], !accessToken.isEmpty else { return nil }

        return OAuthToken(
            accessToken: accessToken,
            refreshToken: fields["refresh_token"],
            expiresIn: fields["expires_in"].flatMap(Int.init),
            tokenType: fields["token_type"] ?? "Bearer",
            scope: fields["scope"],
            issuedAt: Date()
        )
    }

    static func decodeToken(_ data: Data) -> OAuthToken? {
        struct Wire: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            let tokenType: String?
            let scope: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case tokenType = "token_type"
                case scope
            }
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.accessToken.isEmpty else {
            return nil
        }
        return OAuthToken(
            accessToken: wire.accessToken,
            refreshToken: wire.refreshToken,
            expiresIn: wire.expiresIn,
            tokenType: wire.tokenType ?? "Bearer",
            scope: wire.scope,
            issuedAt: Date()
        )
    }

    /// Report OAuth errors or status codes without echoing token endpoint bodies.
    static func failureMessage(status: Int, data: Data) -> String {
        struct Failure: Decodable {
            let error: String?
            let errorDescription: String?

            enum CodingKeys: String, CodingKey {
                case error
                case errorDescription = "error_description"
            }
        }

        if status == 400 || status == 401 {
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                if let description = failure.errorDescription, !description.isEmpty { return description }
                if let code = failure.error, !code.isEmpty {
                    return code == "invalid_grant" ? "That username and password were not accepted." : code
                }
            }
            return "That username and password were not accepted."
        }
        return "The sign-in service returned HTTP \(status)."
    }

    /// Abort if secure random generation fails; OAuth state must be unpredictable.
    private static func nonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
extension OPDSAuthenticationService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let key = windows.first(where: \.isKeyWindow) { return key }
        if let first = windows.first { return first }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        return ASPresentationAnchor(frame: .zero)
    }
}
#endif
