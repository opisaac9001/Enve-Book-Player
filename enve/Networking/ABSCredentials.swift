// AGENT-LOCKED
import Foundation

struct ABSJWT: Sendable {
    enum TokenType: String, Sendable {
        case access
        case api
        case refresh
        case unknown
    }

    let userId: String?
    let username: String?
    let exp: TimeInterval?
    let type: TokenType

    nonisolated init?(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        let payload = String(parts[1])
        var base64 =
            payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: paddingLength)

        guard let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        self.userId = json["userId"] as? String
        self.username = json["username"] as? String
        self.exp = json["exp"] as? TimeInterval
        self.type = (json["type"] as? String).flatMap(TokenType.init(rawValue:)) ?? .unknown
    }

    nonisolated func isExpiring(buffer: TimeInterval = 60) -> Bool {
        guard let exp else { return false }
        return Date().timeIntervalSince1970 >= (exp - buffer)
    }

    nonisolated var isExpired: Bool {
        guard let exp else { return false }
        return Date().timeIntervalSince1970 >= exp
    }
}

enum ABSCredentials: Sendable {
    case bearer(accessToken: String, refreshToken: String, expiresAt: TimeInterval)
    case legacy(token: String)

    var authorizationHeader: String {
        switch self {
        case .bearer(let accessToken, _, _):
            return "Bearer \(accessToken)"
        case .legacy(let token):
            return token.contains(".") ? "Bearer \(token)" : token
        }
    }

    var accessToken: String {
        switch self {
        case .bearer(let t, _, _): return t
        case .legacy(let t): return t
        }
    }

    var refreshToken: String? {
        switch self {
        case .bearer(_, let r, _): return r
        case .legacy: return nil
        }
    }
}

actor ABSCredentialsActor {

    private weak var provider: AudiobookshelfProvider?

    private var refreshTask: Task<ABSCredentials, Error>?

    init(provider: AudiobookshelfProvider) {
        self.provider = provider
    }

    var freshCredentials: ABSCredentials {
        get async throws {
            guard let provider else {
                throw ProviderError.unauthorized
            }

            let snapshot = await provider.tokenSnapshot
            guard let token = snapshot.token, !token.isEmpty else {
                throw ProviderError.unauthorized
            }

            guard let jwt = ABSJWT(token) else {
                return .legacy(token: token)
            }

            if jwt.type == .api {
                return .legacy(token: token)
            }

            if !jwt.isExpiring(buffer: 60) {
                if let rt = snapshot.refreshToken {
                    return .bearer(accessToken: token, refreshToken: rt, expiresAt: jwt.exp ?? 0)
                }
                return .legacy(token: token)
            }

            if let refreshTask {
                return try await refreshTask.value
            }

            let task = Task<ABSCredentials, Error> {
                defer { refreshTask = nil }
                return try await provider.performTokenRefresh()
            }
            refreshTask = task
            return try await task.value
        }
    }

    func forceRefresh() async throws -> ABSCredentials {
        refreshTask?.cancel()
        refreshTask = nil

        guard let provider else { throw ProviderError.unauthorized }

        let task = Task<ABSCredentials, Error> {
            defer { refreshTask = nil }
            return try await provider.performTokenRefresh()
        }
        refreshTask = task
        return try await task.value
    }
}

struct ABSTokenSnapshot: Sendable {
    let token: String?
    let refreshToken: String?
}
