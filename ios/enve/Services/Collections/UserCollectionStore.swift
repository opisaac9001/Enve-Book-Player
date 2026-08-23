import Foundation

@MainActor
@Observable
final class UserCollectionStore {
    static let shared = UserCollectionStore()

    @ObservationIgnored private static let storageKey = "enve_user_collections"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var collections: [Collection]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([Collection].self, from: data)
        {
            self.collections = decoded
        } else {
            self.collections = []
        }
    }

    func save(_ collection: Collection) {
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index] = collection
        } else {
            collections.append(collection)
        }
        persist()
        NotificationCenter.default.post(name: .collectionsDidChange, object: nil)
    }

    func delete(_ collection: Collection) {
        let before = collections.count
        collections.removeAll { $0.id == collection.id }
        guard collections.count != before else { return }
        persist()
        NotificationCenter.default.post(name: .collectionsDidChange, object: nil)
    }

    func refresh() {
        guard let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([Collection].self, from: data)
        else { return }
        collections = decoded
    }

    func clearAll() {
        collections.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
