import Foundation
import Logging

struct LibrarySourceSnapshot: Sendable {
    let connections: [LibrarySourceConnectionSummary]
    let libraries: [LibrarySourceLibrarySummary]
}

struct LibrarySourceConnectionSummary: Identifiable, Sendable {
    let id: UUID
    let name: String
    let type: ProviderType
}

struct LibrarySourceLibrarySummary: Identifiable, Sendable {
    let id: String
    let providerId: UUID
    let name: String

    var uniqueId: String { "\(providerId)_\(id)" }
}

struct SettingsSourcesSnapshot {
    let activeConnections: [ServerConnection]
    let archivedConnections: [ServerConnection]
    let reauthConnectionIds: Set<UUID>
    let importProgress: LibraryImportProgress?
}

struct SourcesDragDropBook: Identifiable, Sendable {
    let id: String
    let title: String
    let author: String?
    let format: String
    let fileSize: Int64
}

enum SourcesConnectionCompletion {
    case chooseWebDAVRoot(server: WebDAVServerConfig, connection: ServerConnection)
    case chooseCloudFolder(connection: ServerConnection)
    case completed
}

enum SourcesFilesImportMode: Sendable {
    case groupByFolder
    case splitSelectedBooks

    var remoteMode: RemoteImportService.FilesAudioSelectionMode {
        switch self {
        case .groupByFolder: .groupByFolder
        case .splitSelectedBooks: .splitSelectedBooks
        }
    }
}

enum SourcesConnectionError: LocalizedError {
    case invalidWebDAVURL

    var errorDescription: String? {
        switch self {
        case .invalidWebDAVURL:
            "That WebDAV address doesn't look right."
        }
    }
}

@MainActor
@Observable
final class SourcesEngine {
    private let appState: AppState
    private let catalog: LibraryCatalogCoordinator
    private var hasRefreshedLibrarySourceNames = false
    private var librarySourceRevision = 0

    init(appState: AppState = .shared, catalog: LibraryCatalogCoordinator = .shared) {
        self.appState = appState
        self.catalog = catalog
    }

    var librarySourceSnapshot: LibrarySourceSnapshot {
        _ = librarySourceRevision
        let connections = appState.providerConnections.connections
            .filter { !$0.isArchived }
            .map { LibrarySourceConnectionSummary(id: $0.id, name: $0.name, type: $0.type) }

        let activeIds = Set(connections.map(\.id))
        var librariesByKey: [String: LibrarySourceLibrarySummary] = [:]

        for library in catalog.libraries where activeIds.contains(library.providerId) {
            librariesByKey[library.uniqueId] = LibrarySourceLibrarySummary(
                id: library.id,
                providerId: library.providerId,
                name: library.name
            )
        }

        for book in appState.allBooks where activeIds.contains(book.providerId) {
            let libraryId = book.libraryId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !libraryId.isEmpty else { continue }
            let key = "\(book.providerId)_\(libraryId)"
            guard librariesByKey[key] == nil else { continue }

            let fallbackName = book.libraryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            librariesByKey[key] = LibrarySourceLibrarySummary(
                id: libraryId,
                providerId: book.providerId,
                name: fallbackName.isEmpty ? libraryId : fallbackName
            )
        }

        let libraries = Array(librariesByKey.values)
            .sorted {
                if $0.providerId != $1.providerId {
                    return sourceTitle($0.providerId, connections: connections)
                        .localizedStandardCompare(sourceTitle($1.providerId, connections: connections)) == .orderedAscending
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        return LibrarySourceSnapshot(connections: connections, libraries: libraries)
    }

    func refreshLibrarySourceNamesIfNeeded() async {
        guard !hasRefreshedLibrarySourceNames else { return }
        hasRefreshedLibrarySourceNames = true

        let activeConnections = appState.providerConnections.connections.filter { !$0.isArchived }
        var changed = false
        for connection in activeConnections {
            guard let provider = appState.getProvider(connection.id) else { continue }
            guard let libraries = try? await provider.fetchLibraries() else { continue }
            changed = upsertSourceLibraries(libraries) || changed
        }

        if changed {
            librarySourceRevision &+= 1
            catalog.saveMetadataChanges()
        }
    }

    var settingsSnapshot: SettingsSourcesSnapshot {
        SettingsSourcesSnapshot(
            activeConnections: appState.providerConnections.connections.filter { !$0.isArchived },
            archivedConnections: appState.providerConnections.connections.filter(\.isArchived),
            reauthConnectionIds: Set(appState.providerConnections.connectionsNeedingReauth.map(\.id)),
            importProgress: appState.presentation.libraryImportProgress
        )
    }

    func hasActiveConnection(type: ProviderType) -> Bool {
        appState.providerConnections.connections.contains { $0.type == type && !$0.isArchived }
    }

    func activeConnections(type: ProviderType) -> [ServerConnection] {
        appState.providerConnections.connections.filter { $0.type == type && !$0.isArchived }
    }

    private func upsertSourceLibraries(_ libraries: [Library]) -> Bool {
        var changed = false
        for library in libraries {
            if let index = catalog.libraries.firstIndex(where: { $0.id == library.id && $0.providerId == library.providerId }) {
                if catalog.libraries[index] != library {
                    catalog.libraries[index] = library
                    changed = true
                }
            } else {
                catalog.libraries.append(library)
                changed = true
            }
        }
        return changed
    }

    #if !os(tvOS)
    func makeLoginDelegate(for type: ProviderType) -> any UnifiedLoginDelegate {
        switch type {
        case .emby: EmbyLoginDelegate()
        case .jellyfin: JellyfinLoginDelegate()
        case .audiobookshelf: AudiobookshelfLoginDelegate()
        case .storyteller: StorytellerLoginDelegate()
        case .booklore: GrimmoryLoginDelegate(appState: appState)
        case .bookOrbit: BookOrbitLoginDelegate(appState: appState)
        case .webdav: ValidatedConnectionLoginDelegate(appState: appState, providerType: .webdav, defaultName: "WebDAV")
        case .torbox: ValidatedConnectionLoginDelegate(appState: appState, providerType: .torbox, defaultName: "TorBox")
        case .komga: KomgaLoginDelegate(appState: appState)
        case .kavita: ValidatedConnectionLoginDelegate(appState: appState, providerType: .kavita, defaultName: "Kavita")
        case .opds: ValidatedConnectionLoginDelegate(appState: appState, providerType: .opds, defaultName: "OPDS")
        default: ValidatedConnectionLoginDelegate(appState: appState, providerType: type, defaultName: type.rawValue.capitalized)
        }
    }
    #endif

    func completeAuthenticatedConnection(_ connection: ServerConnection) throws -> SourcesConnectionCompletion {
        let connection = SourcesFinalizer.resolvedConnection(connection, in: appState)
        SourcesFinalizer.persistPassword(for: connection)

        switch connection.type {
        case .webdav:
            guard let baseURL = URL(string: connection.url) else {
                throw SourcesConnectionError.invalidWebDAVURL
            }
            let server = WebDAVServerConfig(
                id: connection.id.uuidString,
                name: connection.name,
                baseURL: baseURL,
                username: connection.username,
                password: connection.password,
                authType: (connection.authMode == .token || connection.authMode == .sso)
                    ? .none
                    : ((connection.username != nil) ? .basic : .none),
                rootPath: "/",
                isEnabled: true,
                lastConnected: Date()
            )
            RemoteImportService.shared.saveWebDAVServer(server)
            SourcesFinalizer.upsert(connection, into: appState)
            return .chooseWebDAVRoot(server: server, connection: connection)

        case .torbox:
            let webDAVBaseURL = URL(string: "https://webdav.torbox.app")!
            let password = connection.token ?? connection.password
            let server = WebDAVServerConfig(
                id: connection.id.uuidString,
                name: connection.name,
                baseURL: webDAVBaseURL,
                username: "torbox",
                password: password,
                authType: .basic,
                rootPath: "/",
                isEnabled: true,
                lastConnected: Date()
            )
            RemoteImportService.shared.saveWebDAVServer(server)
            SourcesFinalizer.upsert(connection, into: appState)
            return .chooseWebDAVRoot(server: server, connection: connection)

        case .realdebrid:
            SourcesFinalizer.upsert(connection, into: appState)
            return .chooseCloudFolder(connection: connection)

        default:
            SourcesFinalizer.upsert(connection, into: appState)
            Task { await self.importAndSync(providerId: connection.id) }
            return .completed
        }
    }

    func updateWebDAVRoot(server: WebDAVServerConfig, connectionId: UUID, selectedPath: String) async {
        await updateWebDAVRoots(server: server, connectionId: connectionId, selectedPaths: [selectedPath])
    }

    func updateWebDAVRoots(server: WebDAVServerConfig, connectionId: UUID, selectedPaths: [String]) async {
        var updated = server
        let normalized = normalizedWebDAVPaths(selectedPaths)
        let roots = normalized.isEmpty ? ["/"] : normalized
        updated.rootPath = roots.first ?? "/"
        updated.indexedPaths = roots
        RemoteImportService.shared.saveWebDAVServer(updated)
        if let idx = appState.providerConnections.connections.firstIndex(where: { $0.id == connectionId }) {
            appState.providerConnections.connections[idx].rootPath = updated.rootPath
        }
        await importAndSync(providerId: connectionId)
    }

    private func normalizedWebDAVPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalized = trimmed.isEmpty ? "/" : trimmed
            if !normalized.hasPrefix("/") { normalized = "/" + normalized }
            if normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    func updateCloudFolderRoot(connectionId: UUID, selectedPath: String?) async {
        if let selectedPath, let idx = appState.providerConnections.connections.firstIndex(where: { $0.id == connectionId }) {
            appState.providerConnections.connections[idx].rootPath = selectedPath
        }
        await importAndSync(providerId: connectionId)
    }

    func importAndSync(providerId: UUID) async {
        await SourcesFinalizer.importAndSync(catalog: catalog, providerId: providerId)
    }

    func importFiles(urls: [URL], mode: SourcesFilesImportMode) async throws -> Int {
        let imported = try await RemoteImportService.shared.importFromFilesApp(
            urls: urls,
            audioSelectionMode: mode.remoteMode
        )

        let library = LocalLibrary(
            id: LocalLibraryService.fileSharingLibraryId,
            name: "Drag & Drop Books",
            folderPath: LocalLibraryService.fileSharingRootURL.path,
            createdAt: Date(),
            isEnabled: true,
            type: .fileSharing
        )
        LocalLibraryStorageStore.shared.saveLibrary(library)

        let scanResult = try await LocalLibraryService.shared.scanLibrary(library)
        LocalLibraryStorageStore.shared.saveScanResult(scanResult)

        for bookFile in imported {
            if let coverPath = bookFile.metadata?.coverImagePath,
                FileManager.default.fileExists(atPath: coverPath),
                let data = try? Data(contentsOf: URL(fileURLWithPath: coverPath))
            {
                let book = bookFile.toBook(libraryId: LocalLibraryService.fileSharingLibraryId)
                await AppCache.shared.setCoverData(data, for: book)
            }
        }

        catalog.forceNextLocalRefresh = true
        NotificationCenter.default.post(name: .localLibraryUpdated, object: LocalLibraryService.fileSharingLibraryId)
        AppLogger.library.info("Imported \(imported.count) books from Files picker")

        return imported.count
    }

    func dragDropBooks() -> [SourcesDragDropBook] {
        LocalLibraryStorageStore.shared.loadBooks(libraryId: LocalLibraryService.fileSharingLibraryId)
            .map {
                SourcesDragDropBook(
                    id: $0.id,
                    title: $0.displayTitle,
                    author: $0.displayAuthor,
                    format: $0.format,
                    fileSize: $0.fileSize
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func scanDragDropLibrary() async throws -> Int {
        let library = fileSharingLibrary()
        LocalLibraryStorageStore.shared.saveLibrary(library)
        let result = try await LocalLibraryService.shared.scanLibrary(library)
        LocalLibraryStorageStore.shared.saveScanResult(result)
        catalog.forceNextLocalRefresh = true
        NotificationCenter.default.post(name: .localLibraryUpdated, object: library.id)
        return result.totalBooks
    }

    func bookCountsByConnection(_ connections: [ServerConnection]) async -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for connection in connections {
            counts[connection.id] = await appState.bookStore.bookCount(providerId: connection.id, mediaType: nil)
        }
        return counts
    }

    func refreshActiveConnectionLibraries() async {
        for connection in appState.providerConnections.connections where !connection.isArchived {
            await catalog.refreshConnectionLibraries(providerId: connection.id)
        }
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func refreshVisibleLibraryScope(_ sourceFilter: LibrarySourceFilter) async {
        switch sourceFilter {
        case .all:
            await catalog.refreshLibrary(forceFullReconciliation: true)
        case .device:
            await catalog.refreshLocalLibrariesFromUI()
        case let .connection(providerId):
            await catalog.refreshConnectionLibraries(
                providerId: providerId,
                forceFullReconciliation: true
            )
        case let .library(providerId, libraryId):
            await catalog.refreshLibrary(
                providerId: providerId,
                libraryId: libraryId,
                forceFullReconciliation: true
            )
        }

        while catalog.isRefreshing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }

        NotificationCenter.default.post(name: .collectionsDidChange, object: nil)
    }

    func refreshServerCollections() async {
        await catalog.refreshServerCollections()
    }

    private func sourceTitle(_ id: UUID, connections: [LibrarySourceConnectionSummary]) -> String {
        connections.first { $0.id == id }?.name ?? "Source"
    }

    private func fileSharingLibrary() -> LocalLibrary {
        LocalLibraryStorageStore.shared.loadLibraries()
            .first { $0.id == LocalLibraryService.fileSharingLibraryId }
            ?? LocalLibrary(
                id: LocalLibraryService.fileSharingLibraryId,
                name: "Drag & Drop Books",
                folderPath: LocalLibraryService.fileSharingRootURL.path,
                createdAt: Date(),
                isEnabled: true,
                type: .fileSharing
            )
    }
}

enum SourcesFinalizer {
    static func resolvedConnection(_ connection: ServerConnection, in appState: AppState) -> ServerConnection {
        guard let duplicateIndex = duplicateIndex(for: connection, in: appState.providerConnections.connections) else {
            return connection
        }
        var resolved = connection
        resolved.id = appState.providerConnections.connections[duplicateIndex].id
        return resolved
    }

    static func persistPassword(for connection: ServerConnection) {
        connection.persistSecretsToSharedKeychain()

        guard let password = connection.password, !password.isEmpty else { return }
        let key: String
        switch connection.type {
        case .storyteller: key = "storyteller_password_\(connection.id.uuidString)"
        case .audiobookshelf: key = "abs_password_\(connection.id.uuidString)"
        default: key = "\(connection.type.rawValue)_password_\(connection.id.uuidString)"
        }
        KeychainHelper.shared.set(password, key: key)
    }

    @discardableResult
    static func upsert(_ connection: ServerConnection, into appState: AppState) -> ServerConnection {
        let resolved = resolvedConnection(connection, in: appState)
        if let index = appState.providerConnections.connections.firstIndex(where: { $0.id == connection.id }) {
            appState.providerConnections.connections[index] = resolved
        } else if let duplicateIndex = duplicateIndex(for: connection, in: appState.providerConnections.connections) {
            appState.providerConnections.connections[duplicateIndex] = resolved
        } else {
            appState.providerConnections.connections.append(resolved)
        }
        AuthenticationFailureStore.shared.clear(connectionId: resolved.id)
        appState.providerConnections.clearReauthentication(connectionId: resolved.id)
        return resolved
    }

    static func importAndSync(catalog: LibraryCatalogCoordinator = .shared, providerId: UUID) async {
        await catalog.refreshConnectionLibraries(providerId: providerId)
        _ = await SyncCoordinator.shared.runRecentlyPlayedSync(trigger: .appLaunch)
    }

    private static func duplicateIndex(for connection: ServerConnection, in connections: [ServerConnection]) -> Int? {
        guard let target = normalizedEndpoint(connection.url) else { return nil }
        return connections.firstIndex {
            $0.id != connection.id
                && !$0.isArchived
                && $0.type == connection.type
                && normalizedEndpoint($0.url) == target
        }
    }

    private static func normalizedEndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return nil
        }
        let portValue = components.port
        let usesDefaultPort = (scheme == "http" && portValue == 80) || (scheme == "https" && portValue == 443)
        let port = usesDefaultPort ? "" : portValue.map { ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return "\(scheme)://\(host)\(port)\(path.isEmpty ? "" : "/\(path)")"
    }
}
