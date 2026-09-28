import Foundation

/// The provider catalog-mapping revision each library was last fully reconciled with. Delta syncs only
/// revisit items the server changed, so records mapped by older code are repaired by one full reconciliation.
final class CatalogMappingRevisionStore {
    static let shared = CatalogMappingRevisionStore()

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "catalogMappingRevisions") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func isStale(providerId: UUID, libraryId: String, revision: Int) -> Bool {
        revision > (revisions[Self.key(providerId: providerId, libraryId: libraryId)] ?? 0)
    }

    func recordReconciled(providerId: UUID, libraryId: String, revision: Int) {
        let key = Self.key(providerId: providerId, libraryId: libraryId)
        var stored = revisions
        guard revision != stored[key] ?? 0 else { return }
        stored[key] = revision
        defaults.set(stored, forKey: storageKey)
    }

    private var revisions: [String: Int] {
        defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }

    private static func key(providerId: UUID, libraryId: String) -> String {
        "\(providerId.uuidString)|\(libraryId)"
    }
}
