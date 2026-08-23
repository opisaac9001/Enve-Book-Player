import Foundation

@MainActor
@Observable
final class DeletedBooksTombstoneStore {
    static let shared = DeletedBooksTombstoneStore()

    struct Entry: Codable, Identifiable, Sendable {
        let stableId: String
        let title: String
        let deletedAt: Date
        var id: String { stableId }
    }

    @ObservationIgnored private static let storageKey = "permanently_deleted_books_v2"
    @ObservationIgnored private static let legacyStorageKey = "permanently_deleted_book_stable_ids"

    private var entries: [String: Entry]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            self.entries = decoded
        } else if let legacy = UserDefaults.standard.data(forKey: Self.legacyStorageKey),
            let ids = try? JSONDecoder().decode(Set<String>.self, from: legacy)
        {

            self.entries = Dictionary(
                uniqueKeysWithValues: ids.map {
                    ($0, Entry(stableId: $0, title: "Deleted Book", deletedAt: .distantPast))
                }
            )
            persist()
            UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
        } else {
            self.entries = [:]
        }
    }

    var allDeleted: Set<String> { Set(entries.keys) }

    var allEntries: [Entry] {
        entries.values.sorted { $0.deletedAt > $1.deletedAt }
    }

    var isEmpty: Bool { entries.isEmpty }

    func isDeleted(_ stableId: String) -> Bool {
        entries[stableId] != nil
    }

    func markDeleted(_ stableId: String, title: String) {
        entries[stableId] = Entry(stableId: stableId, title: title, deletedAt: Date())
        persist()
    }

    func markRestored(_ stableId: String) {
        entries.removeValue(forKey: stableId)
        persist()
    }

    func clearAll() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
