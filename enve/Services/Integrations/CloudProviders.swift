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

    func authenticateWithCredentials(serverURL: String, username: String, password: String) async throws {
        AppLogger.network.info("[JellyfinConnectionManager] ===== AUTHENTICATION STARTED =====")
        AppLogger.network.info("[JellyfinConnectionManager] Server URL: \(URL(string: serverURL)?.redacted.absoluteString ?? "<invalid>")")
        AppLogger.network.info("[JellyfinConnectionManager] Username: \(username)")

        let provider = JellyfinProvider()

        try await provider.authenticate(serverURL: serverURL, username: username, password: password)

        AppLogger.network.info("[JellyfinConnectionManager] Authentication successful")

        self.jellyfinProvider = provider
        self.serverURL = serverURL
        self.authenticationState = .authenticated

        let connectionId = UUID()
        let connection = ServerConnection(
            id: connectionId,
            name: "Jellyfin",
            url: serverURL,
            type: .jellyfin,
            username: username,
            token: provider.connection.token,
            userId: provider.connection.userId,
            isConnected: true,
            lastVerified: Date(),
            selectedLibraryIds: nil
        )

        self.currentConnectionId = connectionId

        AppLogger.network.info("[JellyfinConnectionManager] Saving connection to AppState...")

        if let existingIndex = AppState.shared.providerConnections.connections.firstIndex(where: {
            $0.type == .jellyfin && $0.url == serverURL && $0.username == username
        }) {
            var updatedConnection = AppState.shared.providerConnections.connections[existingIndex]
            updatedConnection.token = connection.token
            updatedConnection.userId = connection.userId
            updatedConnection.isConnected = true
            updatedConnection.lastVerified = Date()
            AppState.shared.providerConnections.connections[existingIndex] = updatedConnection
            self.currentConnectionId = updatedConnection.id
            AppLogger.network.info("[JellyfinConnectionManager] Updated existing connection")
        } else {
            AppState.shared.providerConnections.connections.append(connection)
            AppLogger.network.info("[JellyfinConnectionManager] Added new connection")
        }

        AppLogger.network.info(
            "[JellyfinConnectionManager] Connection saved to AppState (Total: \(AppState.shared.providerConnections.connections.count) connections)"
        )
        AppLogger.network.info("[JellyfinConnectionManager] ===== AUTHENTICATION COMPLETE =====")
    }

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
