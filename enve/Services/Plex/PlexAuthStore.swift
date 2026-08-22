// AGENT-LOCKED
import Foundation

@MainActor
final class PlexAuthStore {
    static let shared = PlexAuthStore()

    private static let userTokenKey = "plexToken"
    private static let serverTokenKey = "plexServerAccessToken"
    private static let serverUrlKey = "plexServerUrl"
    private static let machineIdKey = "plexMachineIdentifier"
    private static let clientIdKey = "plexClientIdentifier"
    private static let currentAccountIdKey = "plexCurrentAccountId"

    private var keychain: KeychainHelper { KeychainHelper.shared }
    private let userDefaults = UserDefaults.standard

    private init() {}

    func saveToken(_ token: String) {
        keychain.set(token, key: Self.userTokenKey)
    }

    func loadToken() -> String? {
        keychain.get(Self.userTokenKey)
    }

    func removeToken() {
        try? keychain.remove(Self.userTokenKey)
    }

    func saveServerAccessToken(_ token: String) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keychain.set(token, key: Self.serverTokenKey)
    }

    func loadServerAccessToken() -> String? {
        keychain.get(Self.serverTokenKey)
    }

    func removeServerAccessToken() {
        try? keychain.remove(Self.serverTokenKey)
    }

    func tokenForServerRequests() -> String? {
        loadServerAccessToken() ?? loadToken()
    }

    func clearData() {
        removeToken()
        removeServerAccessToken()
        userDefaults.removeObject(forKey: Self.serverUrlKey)
        userDefaults.removeObject(forKey: Self.machineIdKey)
    }

    func saveCurrentAccountId(_ accountId: String) {
        userDefaults.set(accountId, forKey: Self.currentAccountIdKey)
    }

    func loadCurrentAccountId() -> String? {
        userDefaults.string(forKey: Self.currentAccountIdKey)
    }

    func clearCurrentAccountId() {
        userDefaults.removeObject(forKey: Self.currentAccountIdKey)
    }

    func cacheNamespace() -> String {
        loadCurrentAccountId() ?? "signed-out"
    }

    func saveServerUrl(_ url: String) {
        userDefaults.set(url, forKey: Self.serverUrlKey)
    }

    func loadServerUrl() -> String? {
        guard let value = userDefaults.string(forKey: Self.serverUrlKey),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    func loadClientIdentifier() -> String {
        if let existing = userDefaults.string(forKey: Self.clientIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: Self.clientIdKey)
        return newId
    }

    func saveMachineIdentifier(_ identifier: String) {
        userDefaults.set(identifier, forKey: Self.machineIdKey)
    }

    func loadMachineIdentifier() -> String? {
        userDefaults.string(forKey: Self.machineIdKey)
    }
}
