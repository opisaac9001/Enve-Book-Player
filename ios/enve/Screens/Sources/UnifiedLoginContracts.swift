// AGENT-LOCKED
import Foundation

enum UnifiedAuthMethod: String, CaseIterable {
    case usernamePassword = "Username & Password"
    case token = "Token / API Key"
    case quickConnect = "Quick Connect"
    case oidc = "Single Sign-On"
    case webLogin = "Web Login (SSO)"
}

protocol UnifiedLoginDelegate: AnyObject {
    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection

    func authenticateWithToken(serverURL: String, token: String, customHeaders: [String: String]?) async throws -> ServerConnection

    func startQuickConnect(serverURL: String, customHeaders: [String: String]?) async throws -> (code: String, secret: String)

    func pollQuickConnect(secret: String, serverURL: String, customHeaders: [String: String]?) async throws -> ServerConnection

    func authenticateWithOIDC(
        serverURL: String,
        redirectURIOverride: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection

    func authenticateWithWebLogin(serverURL: String, customHeaders: [String: String]?) async throws -> ServerConnection

    func fetchLibraries(connection: ServerConnection) async throws -> [LibraryMetadata]
}

extension UnifiedLoginDelegate {
    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection { throw LoginError.unsupported }
    func authenticateWithToken(serverURL: String, token: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        throw LoginError.unsupported
    }
    func startQuickConnect(serverURL: String, customHeaders: [String: String]?) async throws -> (code: String, secret: String) {
        throw LoginError.unsupported
    }
    func pollQuickConnect(secret: String, serverURL: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        throw LoginError.unsupported
    }
    func authenticateWithOIDC(
        serverURL: String,
        redirectURIOverride: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection { throw LoginError.unsupported }
    func authenticateWithWebLogin(serverURL: String, customHeaders: [String: String]?) async throws -> ServerConnection {
        throw LoginError.unsupported
    }
    func fetchLibraries(connection: ServerConnection) async throws -> [LibraryMetadata] { [] }
}

private enum LoginError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This auth method is not supported by this provider." }
}
