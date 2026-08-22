import Foundation
import Logging

@MainActor
@Observable
final class SmartCollectionStore {
    static let shared = SmartCollectionStore()

    @ObservationIgnored private static let storageKey = "enve_user_smart_collections"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var userCollections: [SmartCollection]

    var merged: [SmartCollection] {
        SmartCollectionGenerator.generateSystemCollections() + userCollections
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([SmartCollection].self, from: data)
        {
            self.userCollections = decoded
        } else {
            self.userCollections = []
        }
        AppLogger.general.info(
            "[SmartCollectionStore] Loaded \(merged.count) (\(merged.count - userCollections.count) system, \(userCollections.count) user)"
        )
    }

    func save(_ collection: SmartCollection) {
        if let index = userCollections.firstIndex(where: { $0.id == collection.id }) {
            userCollections[index] = collection
        } else {
            userCollections.append(collection)
        }
        persist()
    }

    func delete(_ collection: SmartCollection) {
        userCollections.removeAll { $0.id == collection.id }
        persist()
    }

    func clearAll() {
        userCollections.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    func refresh() {
        guard let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([SmartCollection].self, from: data)
        else { return }
        userCollections = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(userCollections) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
