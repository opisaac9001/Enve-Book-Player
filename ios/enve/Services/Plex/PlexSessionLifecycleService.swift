import Foundation

@MainActor
final class PlexSessionLifecycleService {
    static let shared = PlexSessionLifecycleService()

    struct ArchivedState: Codable, Equatable {
        let plexBackends: [BackendConfig]
        let selectedLibraryPreference: SelectedLibraryPreference?
        let plexServerUrl: String?
        let plexMachineIdentifier: String?
        let archivedAt: Date
    }

    private let userDefaults = UserDefaults.standard

    private init() {}

    func archiveCurrentState() {
        guard let accountId = PlexAuthStore.shared.loadCurrentAccountId(), !accountId.isEmpty else {
            return
        }

        let allBackends = ServerConfigStore.shared.loadBackends()
        let plexBackendsSanitized: [BackendConfig] =
            allBackends
            .filter { $0.type == .plex }
            .map { backend in
                BackendConfig(
                    id: backend.id,
                    name: backend.name,
                    type: backend.type,
                    url: backend.url,
                    token: nil,
                    enabled: backend.enabled,
                    username: backend.username,
                    password: nil,
                    userId: nil,
                    selectedLibraryIds: backend.selectedLibraryIds
                )
            }

        let selection = LibraryDisplayPreferencesStore.shared.loadSelectedLibraryPreference()
        let plexSelection: SelectedLibraryPreference? = (selection?.type == "artist") ? selection : nil

        let archived = ArchivedState(
            plexBackends: plexBackendsSanitized,
            selectedLibraryPreference: plexSelection,
            plexServerUrl: PlexAuthStore.shared.loadServerUrl(),
            plexMachineIdentifier: PlexAuthStore.shared.loadMachineIdentifier(),
            archivedAt: Date()
        )

        encode(archived, forKey: archiveKey(for: accountId))
    }

    func restoreState(for accountId: String, token: String?) {
        guard let archived = decode(ArchivedState.self, forKey: archiveKey(for: accountId)) else {
            return
        }

        if let url = archived.plexServerUrl, !url.isEmpty {
            PlexAuthStore.shared.saveServerUrl(url)
        }

        if let machineId = archived.plexMachineIdentifier, !machineId.isEmpty {
            PlexAuthStore.shared.saveMachineIdentifier(machineId)
        }

        var current = ServerConfigStore.shared.loadBackends().filter { $0.type != .plex }
        let restoredPlexBackends: [BackendConfig] = archived.plexBackends.map { backend in
            BackendConfig(
                id: backend.id,
                name: backend.name,
                type: backend.type,
                url: backend.url,
                token: token,
                enabled: backend.enabled,
                username: backend.username,
                password: nil,
                userId: nil,
                selectedLibraryIds: backend.selectedLibraryIds
            )
        }
        current.append(contentsOf: restoredPlexBackends)
        ServerConfigStore.shared.saveBackends(current)

        if let selection = archived.selectedLibraryPreference {
            encode(selection, forKey: "selectedLibraryPreference")
        }
    }

    func archiveAndClearSession() {
        archiveCurrentState()

        PlexAuthStore.shared.clearData()
        PlexAuthStore.shared.clearCurrentAccountId()

        let nonPlex = ServerConfigStore.shared.loadBackends().filter { $0.type != .plex }
        ServerConfigStore.shared.saveBackends(nonPlex)

        if LibraryDisplayPreferencesStore.shared.loadSelectedLibraryPreference()?.type == "artist" {
            LibraryDisplayPreferencesStore.shared.clearSelectedLibraryPreference()
        }

        NotificationCenter.default.post(name: .plexSessionDidChange, object: nil)
    }

    private func archiveKey(for accountId: String) -> String {
        "plexArchive_\(accountId)"
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = userDefaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(type, from: data)
        else {
            return nil
        }
        return decoded
    }
}
