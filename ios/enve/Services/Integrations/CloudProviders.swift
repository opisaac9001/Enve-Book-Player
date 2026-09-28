import Combine
import Foundation
import Logging

class iCloudDriveProvider: BookSourceProvider, ObservableObject {
    let id = UUID().uuidString
    let displayName = "iCloud Drive"
    let iconName = "icloud.fill"
    let capabilities: SourceCapabilities = [.folderBrowsing]
    @Published var authenticationState: AuthenticationState = .authenticated

    func authenticate() async throws {}
    func refreshAuthentication() async throws {}
    func signOut() async throws { authenticationState = .notAuthenticated }
    func listRoot() async throws -> [RemoteItem] { [] }
    func listFolder(_ itemId: String) async throws -> [RemoteItem] { [] }
    func search(_ query: String) async throws -> [RemoteItem] { [] }
    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile {
        ResolvedFile(localURL: nil, streamURL: nil, expiresAt: nil, requiresAuthHeader: false, authHeaderValue: nil, contentLength: nil)
    }
    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata? { nil }
}

class DropboxProvider: BookSourceProvider, ObservableObject {
    let id = UUID().uuidString
    let displayName = "Dropbox"
    let iconName = "shippingbox.fill"
    let capabilities: SourceCapabilities = [.folderBrowsing]
    @Published var authenticationState: AuthenticationState = .notAuthenticated

    func authenticate() async throws { authenticationState = .authenticated }
    func refreshAuthentication() async throws {}
    func signOut() async throws { authenticationState = .notAuthenticated }
    func listRoot() async throws -> [RemoteItem] { [] }
    func listFolder(_ itemId: String) async throws -> [RemoteItem] { [] }
    func search(_ query: String) async throws -> [RemoteItem] { [] }
    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile {
        ResolvedFile(localURL: nil, streamURL: nil, expiresAt: nil, requiresAuthHeader: false, authHeaderValue: nil, contentLength: nil)
    }
    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata? { nil }
}

@MainActor
class JellyfinConnectionManager: ObservableObject {
    @Published var authenticationState: AuthenticationState = .notAuthenticated
    @Published var serverURL: String = ""

    private var jellyfinProvider: JellyfinProvider?
    private var currentConnectionId: UUID?

    func refreshAuthentication() async throws {
        AppLogger.network.info("[JellyfinConnectionManager] Refreshing authentication...")
        if let connectionId = currentConnectionId,
            AppState.shared.providerConnections.connections.contains(where: { $0.id == connectionId })
        {
            authenticationState = .authenticated
        } else {
            authenticationState = .tokenExpired
        }
    }

    func signOut() async throws {
        AppLogger.network.info("[JellyfinConnectionManager] Signing out...")

        if let connectionId = currentConnectionId {
            AppState.shared.providerConnections.connections.removeAll { $0.id == connectionId }
        }

        try? SecureTokenStorage.shared.deleteCredentials(forService: "jellyfin")

        jellyfinProvider = nil
        currentConnectionId = nil
        serverURL = ""
        authenticationState = .notAuthenticated

        AppLogger.network.info("[JellyfinConnectionManager] Signed out successfully")
    }
}
