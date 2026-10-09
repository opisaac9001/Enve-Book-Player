import Combine
import Foundation
import Logging

/// Read/write view of the configured server connections, for owners that repair or prune them.
@MainActor
protocol ProviderConnectionEditing: AnyObject {
    var connections: [ServerConnection] { get set }
}

/// Provider resolution and reauthentication signalling, for owners that drive catalog refresh.
@MainActor
protocol ProviderConnectionResolving: AnyObject {
    var connections: [ServerConnection] { get }
    var connectionsNeedingReauth: [ServerConnection] { get }
    var allProviders: [UUID: LibraryProvider] { get }
    var providerCount: Int { get }

    subscript(providerId: UUID) -> LibraryProvider? { get }

    func markNeedsReauthentication(providerId: UUID, error: Error)
    func clearReauthentication(connectionId: UUID)
}

@Observable
@MainActor
final class ProviderConnectionStore: ProviderConnectionAccessing, ProviderConnectionEditing, ProviderConnectionResolving {
    private static let storageKey = "enve_server_connections"
    private static let secretsMigratedKey = "enve.connectionSecretsMigratedV1"

    var connections: [ServerConnection] = [] {
        didSet {
            persist()
            syncProviders()
            refreshAuthenticationFailures()
            if activeSignature(oldValue) != activeSignature(connections) {
                configurationDidChange?()
            }
            changes.send(connections)
        }
    }

    private(set) var connectionsNeedingReauth: [ServerConnection] = []
    let changes = PassthroughSubject<[ServerConnection], Never>()
    var configurationDidChange: (() -> Void)?

    private var isRetired = false
    private var authenticationTasks: [Task<Void, Never>] = []
    private var providers: [UUID: LibraryProvider] = [:]
    private let providerFactory: @MainActor (ServerConnection) -> LibraryProvider?
    private(set) var persistsConnections: Bool
    private let defaults: UserDefaults
    private let keychain: SharedKeychainStore
    private let serverConfig: ServerConfigStore
    private let isOwnerProfile: Bool
    private let authenticationFailures: AuthenticationFailureStore
    private let pendingSync: PendingSyncQueueStore

    var allProviders: [UUID: LibraryProvider] { providers }
    var providerCount: Int { providers.count }

    convenience init(
        initialConnections: [ServerConnection]? = nil,
        providerFactory: @escaping @MainActor (ServerConnection) -> LibraryProvider? = ProviderFactory.create(for:)
    ) {
        self.init(
            profileID: FamilyProfile.ownerID,
            defaults: .standard,
            keychain: .shared,
            serverConfig: .shared,
            initialConnections: initialConnections,
            providerFactory: providerFactory
        )
    }

    init(
        profileID: String,
        defaults: UserDefaults,
        keychain: SharedKeychainStore,
        serverConfig: ServerConfigStore,
        authenticationFailures: AuthenticationFailureStore = .shared,
        pendingSync: PendingSyncQueueStore = .shared,
        initialConnections: [ServerConnection]? = nil,
        providerFactory: @escaping @MainActor (ServerConnection) -> LibraryProvider? = ProviderFactory.create(for:)
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.serverConfig = serverConfig
        self.authenticationFailures = authenticationFailures
        self.pendingSync = pendingSync
        isOwnerProfile = profileID == FamilyProfile.ownerID
        self.providerFactory = providerFactory
        persistsConnections = initialConnections == nil
        connections = initialConnections ?? load()
        syncProviders()
        refreshAuthenticationFailures()
    }

    subscript(providerId: UUID) -> LibraryProvider? {
        get { provider(for: providerId) }
        set {
            providers[providerId] = newValue
            if let newValue {
                setupCallbacks(newValue)
            }
        }
    }

    func provider(for providerId: UUID) -> LibraryProvider? {
        guard !isRetired else { return nil }
        if let provider = providers[providerId] {
            return provider
        }
        guard let connection = connections.first(where: { $0.id == providerId && !$0.isArchived }),
            let provider = providerFactory(connection)
        else {
            return nil
        }
        providers[providerId] = provider
        setupCallbacks(provider)
        return provider
    }

    func provider(for book: Book) -> LibraryProvider? {
        let directProvider = provider(for: book.providerId)

        guard book.source == .emby else { return directProvider }
        if directProvider is EmbyProvider { return directProvider }

        if let backendId = book.backendId.flatMap(UUID.init(uuidString:)),
            let backendProvider = provider(for: backendId) as? EmbyProvider
        {
            return backendProvider
        }

        let embyConnections = connections.filter { $0.type == .emby && !$0.isArchived }
        let connection =
            embyConnections.first(where: { $0.id == book.providerId })
            ?? embyConnections.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(book.backendId ?? "") == .orderedSame
            })
            ?? embyConnections.first(where: { $0.selectedLibraryIds?.contains(book.libraryId) == true })
            ?? (embyConnections.count == 1 ? embyConnections[0] : nil)

        guard let connection else { return nil }
        return provider(for: connection.id)
    }

    func backend(id: String) -> BackendConfig? {
        let searchId = id.lowercased()
        if let connection = connections.first(where: {
            $0.id.uuidString.lowercased() == searchId
        }) {
            return BackendConfig(from: connection)
        }
        guard isOwnerProfile else { return nil }
        return serverConfig.loadBackends().first {
            $0.id.lowercased() == searchId
        }
    }

    func allBackends() -> [BackendConfig] {
        var backends = connections.compactMap(BackendConfig.init(from:))
        let connectionBackendIds = Set(backends.map(\.id))
        guard isOwnerProfile else { return backends }
        backends.append(
            contentsOf: serverConfig.loadBackends().filter {
                !connectionBackendIds.contains($0.id)
            }
        )
        return backends
    }

    func syncProviders() {
        guard !isRetired else { return }
        let connectionIds = Set(connections.filter { !$0.isArchived }.map(\.id))
        providers = providers.filter { connectionIds.contains($0.key) }

        for connection in connections where !connection.isArchived {
            if let existing = providers[connection.id] {
                if existing.connection.type == connection.type {
                    existing.connection = connection
                    continue
                }
            }

            let provider = providerFactory(connection)
            providers[connection.id] = provider
            if let provider { setupCallbacks(provider) }
        }
    }

    func refresh() {
        connections = load()
    }

    func updateToken(_ updatedConnection: ServerConnection) {
        guard let index = connections.firstIndex(where: { $0.id == updatedConnection.id }) else { return }
        var updated = connections[index]
        updated.token = updatedConnection.token
        updated.password = updatedConnection.password
        updated.customHeaders = updatedConnection.customHeaders
        updated.lastVerified = updatedConnection.lastVerified
        if updatedConnection.token?.isEmpty == false {
            updated.isConnected = true
        }
        connections[index] = updated
        providers[updatedConnection.id]?.connection = updated
    }

    func markNeedsReauthentication(_ connection: ServerConnection) {
        guard !connectionsNeedingReauth.contains(where: { $0.id == connection.id }) else { return }
        connectionsNeedingReauth.append(connection)
    }

    func clearReauthentication(connectionId: UUID) {
        connectionsNeedingReauth.removeAll { $0.id == connectionId }
        pendingSync.resumeSuspended()
    }

    func refreshAudiobookshelfAuthentication() async {
        guard !isRetired else { return }
        if isRefreshingAudiobookshelfAuthentication {
            AppLogger.general.warning("ABS auth refresh already running, skipping duplicate request")
            return
        }
        isRefreshingAudiobookshelfAuthentication = true
        defer { isRefreshingAudiobookshelfAuthentication = false }

        let targets = connections.filter {
            $0.type == .audiobookshelf
                && !$0.isArchived
                && !authenticationFailures.isBlocked(connectionId: $0.id)
        }
        guard !targets.isEmpty else { return }

        AppLogger.general.info("Refreshing auth for \(targets.count) Audiobookshelf server(s) in parallel...")

        var tasks: [Task<Void, Never>] = []
        for connection in targets {
            tasks.append(
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !self.isRetired,
                        let provider = self.provider(for: connection.id) as? AudiobookshelfProvider
                    else { return }

                    do {
                        let isValid = try await Task.withTimeout(seconds: 10) {
                            try await provider.validateConnection()
                        }
                        guard !self.isRetired else { return }
                        if isValid {
                            if let index = self.connections.firstIndex(where: { $0.id == connection.id }) {
                                var updated = self.connections[index]
                                if !updated.isConnected || updated.token != provider.connection.token {
                                    updated.isConnected = true
                                    updated.token = provider.connection.token
                                    updated.lastVerified = Date()
                                    self.connections[index] = updated
                                    provider.connection = updated
                                }
                            }
                            AppLogger.general.info("Auth refreshed for: \(connection.name)")
                        } else {
                            AppLogger.general.info("Auth validation returned false for \(connection.name)")
                        }
                    } catch {
                        AppLogger.general.error(
                            "Auth refresh timed out or failed for \(connection.name): \(error.localizedDescription)"
                        )
                        self.markNeedsReauthentication(providerId: connection.id, error: error)
                    }
                }
            )
        }

        authenticationTasks = tasks
        for task in tasks { await task.value }
        authenticationTasks.removeAll()
    }

    func refreshBookloreAuthentication() async {
        guard !isRetired else { return }
        let targets = connections.filter {
            $0.type == .booklore
                && !$0.isArchived
                && !authenticationFailures.isBlocked(connectionId: $0.id)
        }
        guard !targets.isEmpty else { return }

        AppLogger.general.info("Refreshing auth for \(targets.count) Booklore server(s)...")

        for connection in targets {
            guard let provider = self[connection.id] as? BookloreProvider else { continue }

            do {
                _ = try await Task.withTimeout(seconds: 20) {
                    try await provider.refreshCoverImageSession()
                    try await provider.ensureCloudflareSessionValid()
                }
                AppLogger.general.info("Auth refreshed for: \(connection.name)")
            } catch {
                AppLogger.general.error(
                    "Booklore auth refresh failed for \(connection.name): \(error.localizedDescription)"
                )
                markNeedsReauthentication(providerId: connection.id, error: error)
            }
        }
    }

    func retire() async {
        isRetired = true
        configurationDidChange = nil
        let jobs = authenticationTasks
        jobs.forEach { $0.cancel() }
        for job in jobs { await job.value }
        let retiringProviders = Array(providers.values)
        providers.removeAll()
        for provider in retiringProviders { await provider.retire() }
    }

    func bookloreProvider(for url: URL) -> BookloreProvider? {
        guard let host = url.host?.lowercased(),
            let connection = connections.first(where: {
                $0.type == .booklore
                    && !$0.isArchived
                    && URL(string: $0.url)?.host?.lowercased() == host
            })
        else {
            return nil
        }
        return self[connection.id] as? BookloreProvider
    }

    func markNeedsReauthentication(providerId: UUID, error: Error) {
        guard Self.requiresReauthentication(after: error),
            let index = connections.firstIndex(where: { $0.id == providerId })
        else {
            return
        }

        var connection = connections[index]
        connection.isConnected = false
        connections[index] = connection
        authenticationFailures.block(connectionId: providerId)
        markNeedsReauthentication(connection)
        AppLogger.general.warning(
            "[ProviderConnections] Marked \(connection.name) as requiring reauth after authorization failure"
        )
    }

    static func requiresReauthentication(after error: Error) -> Bool {
        let lowercasedDescription = error.localizedDescription.lowercased()
        if let providerError = error as? ProviderError {
            switch providerError {
            case .unauthorized, .rateLimited:
                return true
            default:
                return false
            }
        }
        return lowercasedDescription.contains("unauthorized")
            || lowercasedDescription.contains("authentication failed")
            || lowercasedDescription.contains("cloudflare access rejected")
            || lowercasedDescription.contains("service_token_status=false")
            || lowercasedDescription.contains("too many authentication attempts")
            || lowercasedDescription.contains("too many login attempts")
    }

    private func setupCallbacks(_ provider: LibraryProvider) {
        let callback: (ServerConnection) -> Void = { [weak self] updatedConnection in
            self?.updateToken(updatedConnection)
        }
        (provider as? AudiobookshelfProvider)?.onTokenUpdated = callback
        (provider as? BookloreProvider)?.onTokenUpdated = callback
        (provider as? StorytellerProvider)?.onTokenUpdated = callback
        (provider as? BookOrbitProvider)?.onTokenUpdated = callback
        (provider as? SiloProvider)?.onTokenUpdated = callback
    }

    private var isRefreshingAudiobookshelfAuthentication = false

    private func refreshAuthenticationFailures() {
        let blocked = authenticationFailures.blockedConnectionIds
        connectionsNeedingReauth = connections.filter {
            !$0.isArchived && blocked.contains($0.id)
        }
    }

    private func activeSignature(_ connections: [ServerConnection]) -> Set<String> {
        Set(
            connections.filter { !$0.isArchived }.map {
                "\($0.id):\($0.selectedLibraryIds?.sorted().joined(separator: ",") ?? "")"
            }
        )
    }

    private func persist() {
        guard persistsConnections else { return }
        let snapshot = connections
        do {
            defaults.set(try encode(snapshot), forKey: Self.storageKey)
        } catch {
            AppLogger.general.error("Server connections save skipped: \(error.localizedDescription)")
            return
        }

        guard isOwnerProfile, PlatformRuntime.cloudKitEnabled else { return }
        Task { @MainActor [snapshot] in
            for connection in snapshot {
                await ServerConnectionCloudKitSync.shared.pushChange(connection)
            }
        }
    }

    private func encode(_ connections: [ServerConnection]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.userInfo[ServerConnection.keychainUserInfoKey] = keychain
        return try encoder.encode(connections)
    }

    private func decode(_ data: Data) throws -> [ServerConnection] {
        let decoder = JSONDecoder()
        decoder.userInfo[ServerConnection.keychainUserInfoKey] = keychain
        return try decoder.decode([ServerConnection].self, from: data)
    }

    private func load() -> [ServerConnection] {
        migrateSecretsIfNeeded()
        var loaded: [ServerConnection] = []
        if let data = defaults.data(forKey: Self.storageKey), !data.isEmpty {
            do {
                loaded = try decode(data)
            } catch {
                AppLogger.general.error(
                    "Failed to decode connections blob (\(data.count) bytes); preserving blob: \(error.localizedDescription)"
                )
                StoreHealth.shared.state = .rebuildRequired
                return []
            }
        }

        let legacyBackends = isOwnerProfile ? serverConfig.loadBackends() : []
        let existingIds = Set(loaded.map { $0.id.uuidString.lowercased() })
        for backend in legacyBackends {
            guard let id = UUID(uuidString: backend.id),
                !existingIds.contains(id.uuidString.lowercased())
            else {
                continue
            }
            loaded.append(
                ServerConnection(
                    id: id,
                    name: backend.name,
                    url: backend.url,
                    type: providerType(for: backend.type),
                    username: backend.username,
                    token: backend.token,
                    userId: backend.userId,
                    isConnected: backend.enabled,
                    lastVerified: nil,
                    selectedLibraryIds: backend.selectedLibraryIds
                )
            )
        }

        if loaded.contains(where: { !$0.url.lowercased().contains("example.com") }) {
            loaded.removeAll { $0.url.lowercased().contains("example.com") }
        }
        return loaded
    }

    private func providerType(for backendType: BackendConfig.BackendType) -> ProviderType {
        switch backendType {
        case .plex: .plex
        case .audiobookshelf: .audiobookshelf
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .storyteller: .storyteller
        }
    }

    private func migrateSecretsIfNeeded() {
        guard !defaults.bool(forKey: Self.secretsMigratedKey) else { return }
        guard let data = defaults.data(forKey: Self.storageKey), !data.isEmpty else {
            defaults.set(true, forKey: Self.secretsMigratedKey)
            return
        }
        do {
            let decoded = try decode(data)
            defaults.set(try encode(decoded), forKey: Self.storageKey)
            defaults.set(true, forKey: Self.secretsMigratedKey)
        } catch {
            AppLogger.general.error("Connection secret migration deferred: \(error.localizedDescription)")
        }
    }
}
