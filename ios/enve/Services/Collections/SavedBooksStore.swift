import Foundation

@MainActor
@Observable
final class SavedBooksStore {
    static let shared = SavedBooksStore()

    typealias List = SavedBookList

    struct Mutation: Codable, Equatable {
        let revision: UUID
        let uniqueId: String
        let list: List
        let saved: Bool
    }

    @ObservationIgnored private static let storageKey = "enve_saved_books"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var favorites: [String]
    private(set) var later: [String]
    private(set) var pending: [Mutation]
    private(set) var updating: Set<String> = []
    private(set) var syncErrors: [String: String] = [:]
    private(set) var syncingProviders: Set<UUID> = []

    @ObservationIgnored private var syncedProviders: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(SavedBooks.self, from: data) {
            favorites = saved.favorites
            later = saved.later
            pending = saved.pending
            syncedProviders = saved.syncedProviders
        } else {
            favorites = []
            later = []
            pending = []
            syncedProviders = []
        }
    }

    func ids(in list: List) -> [String] {
        list == .favorites ? favorites : later
    }

    func contains(_ id: String, in list: List) -> Bool {
        ids(in: list).contains(id)
    }

    func isUpdating(_ id: String, in list: List) -> Bool {
        updating.contains("\(list.rawValue):\(id)")
    }

    func setUpdating(_ updating: Bool, id: String, in list: List) {
        let key = "\(list.rawValue):\(id)"
        if updating {
            self.updating.insert(key)
        } else {
            self.updating.remove(key)
        }
    }

    func setSyncError(_ message: String?, for id: String) {
        syncErrors[id] = message
    }

    func toggle(_ id: String, in list: List) {
        set(id, in: list, saved: !contains(id, in: list), enqueue: false)
    }

    func set(_ id: String, in list: List, saved: Bool, enqueue: Bool) {
        switch list {
        case .favorites:
            favorites.removeAll { $0 == id }
            if saved {
                favorites.insert(id, at: 0)
            }
        case .later:
            later.removeAll { $0 == id }
            if saved {
                later.insert(id, at: 0)
            }
        }
        pending.removeAll { $0.uniqueId == id && $0.list == list }
        if enqueue {
            pending.append(Mutation(revision: UUID(), uniqueId: id, list: list, saved: saved))
        }
        persist()
    }

    func prepareFirstSync(providerId: UUID) {
        guard !syncedProviders.contains(providerId) else { return }
        let prefix = "\(providerId)_"
        for list in List.allCases {
            for id in ids(in: list) where id.hasPrefix(prefix) {
                guard !pending.contains(where: { $0.uniqueId == id && $0.list == list }) else { continue }
                pending.append(Mutation(revision: UUID(), uniqueId: id, list: list, saved: true))
            }
        }
        syncedProviders.insert(providerId)
        persist()
    }

    func pendingMutations(for providerId: UUID) -> [Mutation] {
        let prefix = "\(providerId)_"
        return pending.filter { $0.uniqueId.hasPrefix(prefix) }
    }

    func reconcile(providerId: UUID, snapshot: [List: Set<String>]) {
        guard List.allCases.allSatisfy({ snapshot[$0] != nil }) else { return }
        let prefix = "\(providerId)_"
        for list in List.allCases {
            let remoteIds = snapshot[list]!
            let confirmed = Set(remoteIds.map { prefix + $0 })
            let acknowledged = pending.filter {
                $0.list == list
                    && $0.uniqueId.hasPrefix(prefix)
                    && (confirmed.contains($0.uniqueId) == $0.saved)
            }
            let acknowledgedRevisions = Set(acknowledged.map(\.revision))
            pending.removeAll { acknowledgedRevisions.contains($0.revision) }
            for mutation in acknowledged { syncErrors[mutation.uniqueId] = nil }

            var visible = confirmed
            for mutation in pending where mutation.list == list && mutation.uniqueId.hasPrefix(prefix) {
                if mutation.saved {
                    visible.insert(mutation.uniqueId)
                } else {
                    visible.remove(mutation.uniqueId)
                }
            }
            switch list {
            case .favorites:
                let existing = favorites.filter { !$0.hasPrefix(prefix) || visible.contains($0) }
                favorites = existing + visible.subtracting(existing).sorted()
            case .later:
                let existing = later.filter { !$0.hasPrefix(prefix) || visible.contains($0) }
                later = existing + visible.subtracting(existing).sorted()
            }
        }
        persist()
    }

    func beginSync(providerId: UUID) -> Bool {
        syncingProviders.insert(providerId).inserted
    }

    func endSync(providerId: UUID) {
        syncingProviders.remove(providerId)
    }

    private func persist() {
        let saved = SavedBooks(
            favorites: favorites,
            later: later,
            pending: pending,
            syncedProviders: syncedProviders
        )
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private struct SavedBooks: Codable {
        let favorites: [String]
        let later: [String]
        let pending: [Mutation]
        let syncedProviders: Set<UUID>

        private enum CodingKeys: String, CodingKey {
            case favorites, later, pending, syncedProviders
        }

        init(favorites: [String], later: [String], pending: [Mutation], syncedProviders: Set<UUID>) {
            self.favorites = favorites
            self.later = later
            self.pending = pending
            self.syncedProviders = syncedProviders
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            favorites = try container.decode([String].self, forKey: .favorites)
            later = try container.decode([String].self, forKey: .later)
            pending = try container.decodeIfPresent([Mutation].self, forKey: .pending) ?? []
            syncedProviders = try container.decodeIfPresent(Set<UUID>.self, forKey: .syncedProviders) ?? []
        }
    }
}
