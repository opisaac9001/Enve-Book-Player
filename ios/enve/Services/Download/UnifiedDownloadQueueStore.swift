import Foundation

struct UnifiedDownloadQueueStore {
    static let finishedTaskRetention: TimeInterval = 86_400

    private let defaults: UserDefaults
    private let key: String
    private let rejectsUnreadableStorage: Bool

    init(defaults: UserDefaults = .standard, key: String = "UnifiedDownloadQueue") {
        self.defaults = defaults
        self.key = key
        rejectsUnreadableStorage = false
    }

    init(storage: ProfileStorageLocations, key: String = "UnifiedDownloadQueue") throws {
        defaults = try storage.openPreferences()
        self.key = key
        rejectsUnreadableStorage = storage.profileID != FamilyProfile.ownerID
        if rejectsUnreadableStorage, let value = defaults.object(forKey: key) {
            guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
            _ = try JSONDecoder().decode([BookDownloadTask].self, from: data)
        }
    }

    func load() -> [BookDownloadTask] {
        guard let data = defaults.data(forKey: key),
            let stored = try? JSONDecoder().decode([BookDownloadTask].self, from: data)
        else {
            return []
        }

        let cutoff = Date().addingTimeInterval(-Self.finishedTaskRetention)
        return stored.filter { task in
            if task.status == .completed || task.status == .cancelled {
                return task.updatedAt > cutoff
            }
            return true
        }
    }

    func save(_ tasks: [BookDownloadTask]) {
        if rejectsUnreadableStorage, let value = defaults.object(forKey: key) {
            guard let data = value as? Data,
                (try? JSONDecoder().decode([BookDownloadTask].self, from: data)) != nil
            else { return }
        }
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: key)
    }
}
