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

    nonisolated(unsafe) private let userDefaults: UserDefaults
    nonisolated private let preferencesDomain: String

    static let shared = StorageService()

    public nonisolated init() {
        userDefaults = .standard
        preferencesDomain = Bundle.main.bundleIdentifier!
    }

    nonisolated init(defaults: UserDefaults, preferencesDomain: String) {
        userDefaults = defaults
        self.preferencesDomain = preferencesDomain
    }

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
        userDefaults.removePersistentDomain(forName: preferencesDomain)
    }

}
