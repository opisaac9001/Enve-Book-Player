import Foundation

struct UnifiedDownloadQueueStore {
    static let finishedTaskRetention: TimeInterval = 86_400

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "UnifiedDownloadQueue") {
        self.defaults = defaults
        self.key = key
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
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: key)
    }
}
