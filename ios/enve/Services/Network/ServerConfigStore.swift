// AGENT-LOCKED
import Foundation

@MainActor
final class ServerConfigStore {
    static let shared = ServerConfigStore()

    private static let backendsKey = "backends"
    private static let smbServersKey = "smbServers"
    private static let smbBooksPrefix = "smbBooks_"
    private static let smbPasswordPrefix = "smb:password:"

    private let userDefaults = UserDefaults.standard
    private var keychain: KeychainHelper { KeychainHelper.shared }

    private init() {}

    func saveBackends(_ backends: [BackendConfig]) {
        guard let encoded = try? JSONEncoder().encode(backends) else { return }
        userDefaults.set(encoded, forKey: Self.backendsKey)
    }

    func loadBackends() -> [BackendConfig] {
        guard let data = userDefaults.data(forKey: Self.backendsKey),
            let backends = try? JSONDecoder().decode([BackendConfig].self, from: data)
        else {
            return []
        }
        return backends
    }

    func saveSMBServers(_ servers: [SMBServerConfiguration]) {
        guard let encoded = try? JSONEncoder().encode(servers) else { return }
        userDefaults.set(encoded, forKey: Self.smbServersKey)
    }

    func loadSMBServers() -> [SMBServerConfiguration] {
        guard let data = userDefaults.data(forKey: Self.smbServersKey),
            let servers = try? JSONDecoder().decode([SMBServerConfiguration].self, from: data)
        else {
            return []
        }
        return servers
    }

    func saveSMBPassword(_ password: String, for serverId: UUID) {
        keychain.set(password, key: Self.smbPasswordPrefix + serverId.uuidString)
    }

    func loadSMBPassword(for serverId: UUID) -> String? {
        keychain.get(Self.smbPasswordPrefix + serverId.uuidString)
    }

    func deleteSMBPassword(for serverId: UUID) {
        try? keychain.remove(Self.smbPasswordPrefix + serverId.uuidString)
    }

    func saveSMBBooks(serverId: UUID, books: [LocalBookFile]) {
        let key = Self.smbBooksPrefix + serverId.uuidString
        guard let data = try? JSONEncoder().encode(books) else { return }
        userDefaults.set(data, forKey: key)
    }

    func loadSMBBooks(serverId: UUID) -> [LocalBookFile] {
        let key = Self.smbBooksPrefix + serverId.uuidString
        guard let data = userDefaults.data(forKey: key),
            let books = try? JSONDecoder().decode([LocalBookFile].self, from: data)
        else {
            return []
        }
        return books
    }
}
