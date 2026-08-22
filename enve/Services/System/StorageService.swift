import Combine
import Foundation
import Logging
import SwiftUI

extension Notification.Name {
    static let preferencesDidChange = Notification.Name("preferencesDidChange")
    static let bookProgressDidChange = Notification.Name("bookProgressDidChange")
    static let localLibraryDeleted = Notification.Name("localLibraryDeleted")
    static let localLibraryUpdated = Notification.Name("localLibraryUpdated")
    static let collectionsDidChange = Notification.Name("collectionsDidChange")
    static let plexSessionDidChange = Notification.Name("plexSessionDidChange")
    static let appDataDidClear = Notification.Name("appDataDidClear")
    static let themeAppearanceDidChange = Notification.Name("themeAppearanceDidChange")
}

public final class StorageService {

    private let userDefaults = UserDefaults.standard
    private var keychain: KeychainHelper { KeychainHelper.shared }

    static let shared = StorageService()

    public nonisolated init() {}

    func loadDeviceUUID() -> String {
        if let uuid = userDefaults.string(forKey: "enve_device_uuid") {
            return uuid
        }
        let uuid = UUID().uuidString
        userDefaults.set(uuid, forKey: "enve_device_uuid")
        return uuid
    }

    func save<T: Codable>(_ object: T, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(object) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    func load<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = userDefaults.data(forKey: key),
            let object = try? JSONDecoder().decode(type, from: data)
        else {
            return nil
        }
        return object
    }

    func remove(forKey key: String) {
        userDefaults.removeObject(forKey: key)
    }

    func clearAll() {
        let domain = Bundle.main.bundleIdentifier!
        userDefaults.removePersistentDomain(forName: domain)
    }

    func saveSearchHistory(_ history: [String]) {
        userDefaults.set(history, forKey: "searchHistory")
    }

    func loadSearchHistory() -> [String] {
        return userDefaults.stringArray(forKey: "searchHistory") ?? []
    }

    func saveConnectedServices(_ services: ConnectedServices) {
        save(services, forKey: "connectedServices")
    }

    func loadConnectedServices() -> ConnectedServices {
        return load(ConnectedServices.self, forKey: "connectedServices") ?? ConnectedServices()
    }

}
