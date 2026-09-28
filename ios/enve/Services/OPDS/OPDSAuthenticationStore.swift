import Foundation
import Logging

/// Store bearer tokens in Keychain and refresh endpoints in UserDefaults for cold launches.
@MainActor
final class OPDSAuthenticationStore {
    static let shared = OPDSAuthenticationStore()

    /// The adopted flow and the endpoints it needs again later.
    struct Session: Codable, Equatable {
        var flowType: String
        var authenticateURL: URL? = nil
        var refreshURL: URL? = nil
        var documentURL: URL? = nil
        /// What the reader signed in as, for the sources screen. Never a password.
        var accountLabel: String? = nil
    }

    private static let storageKey = "opds.authentication.sessions.v1"

    private let defaults: UserDefaults
    private let tokens: any OPDSTokenStoring
    private var sessions: [String: Session]
    /// Keep authentication challenges in memory until sign-in succeeds.
    private var challenges: [UUID: OPDSAuthenticationDocument] = [:]

    init(defaults: UserDefaults = .standard, tokens: any OPDSTokenStoring = KeychainOPDSTokenStore()) {
        self.defaults = defaults
        self.tokens = tokens
        sessions = (defaults.data(forKey: Self.storageKey))
            .flatMap { try? JSONDecoder().decode([String: Session].self, from: $0) } ?? [:]
    }

    func session(for connectionId: UUID) -> Session? {
        sessions[connectionId.uuidString]
    }

    func setSession(_ session: Session?, for connectionId: UUID) {
        sessions[connectionId.uuidString] = session
        persist()
    }

    func token(for connectionId: UUID) -> OAuthToken? {
        tokens.token(forConnectionId: connectionId)
    }

    func setToken(_ token: OAuthToken?, for connectionId: UUID) {
        tokens.setToken(token, forConnectionId: connectionId)
    }

    /// Withhold expired tokens until refresh completes.
    func authorizationHeaderValue(for connectionId: UUID) -> String? {
        guard let token = tokens.token(forConnectionId: connectionId), !token.isExpired else { return nil }
        let scheme = token.tokenType.isEmpty ? "Bearer" : token.tokenType
        return "\(scheme) \(token.accessToken)"
    }

    func challenge(for connectionId: UUID) -> OPDSAuthenticationDocument? {
        challenges[connectionId]
    }

    func recordChallenge(_ document: OPDSAuthenticationDocument?, for connectionId: UUID) {
        challenges[connectionId] = document
    }

    /// Clear credentials but retain the sign-in document URL to allow reauthentication without another 401.
    func signOut(connectionId: UUID) {
        challenges[connectionId] = nil
        tokens.setToken(nil, forConnectionId: connectionId)
        let documentURL = sessions[connectionId.uuidString]?.documentURL
        setSession(documentURL.map { Session(flowType: "", documentURL: $0) }, for: connectionId)
    }

    /// A remembered document URL alone does not constitute an authenticated session.
    func isSignedIn(connectionId: UUID) -> Bool {
        session(for: connectionId).map { !$0.flowType.isEmpty } ?? false
    }

    func retainConnections(_ connectionIds: Set<UUID>) {
        let keep = Set(connectionIds.map(\.uuidString))
        let dropped = sessions.keys.filter { !keep.contains($0) }
        guard !dropped.isEmpty else { return }
        for key in dropped {
            sessions[key] = nil
            if let id = UUID(uuidString: key) { tokens.setToken(nil, forConnectionId: id) }
        }
        challenges = challenges.filter { connectionIds.contains($0.key) }
        persist()
    }

    func clearAll() {
        for key in sessions.keys {
            if let id = UUID(uuidString: key) { tokens.setToken(nil, forConnectionId: id) }
        }
        sessions.removeAll()
        challenges.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Injectable token storage for testing retention and expiry without Keychain access.
@MainActor
protocol OPDSTokenStoring {
    func token(forConnectionId connectionId: UUID) -> OAuthToken?
    func setToken(_ token: OAuthToken?, forConnectionId connectionId: UUID)
}

@MainActor
struct KeychainOPDSTokenStore: OPDSTokenStoring {
    private func provider(_ connectionId: UUID) -> String { "opds-\(connectionId.uuidString)" }

    func token(forConnectionId connectionId: UUID) -> OAuthToken? {
        try? SecureTokenStorage.shared.loadToken(forProvider: provider(connectionId))
    }

    func setToken(_ token: OAuthToken?, forConnectionId connectionId: UUID) {
        do {
            if let token {
                try SecureTokenStorage.shared.saveToken(token, forProvider: provider(connectionId))
            } else {
                try SecureTokenStorage.shared.deleteToken(forProvider: provider(connectionId))
            }
        } catch {
            AppLogger.network.error("[OPDS] Could not update the stored sign-in for a connection")
        }
    }
}
