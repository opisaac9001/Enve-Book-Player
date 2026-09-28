import Foundation

/// Persist per-book endpoints and unresolved references beyond the catalog import that discovers them.
@MainActor
final class OPDSProgressionEndpointStore {
    static let shared = OPDSProgressionEndpointStore()

    private struct Entry: Codable {
        let connectionId: UUID
        let endpoint: OPDSProgressionEndpoint
    }

    private static let storageKey = "opds.progression.endpoints.v1"
    private static let retainedReferencesKey = "opds.progression.retained-references.v1"

    private let defaults: UserDefaults
    private var entries: [String: Entry]
    /// Retain unresolved references for the next push only while the book has a progression service.
    private var retained: [String: [String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load([String: Entry].self, from: defaults, key: Self.storageKey) ?? [:]
        retained = Self.load([String: [String]].self, from: defaults, key: Self.retainedReferencesKey) ?? [:]
    }

    func endpoint(forBookStableId stableId: String) -> OPDSProgressionEndpoint? {
        entries[stableId]?.endpoint
    }

    /// Skip the library query when this connection advertises no progression services.
    func hasEndpoints(forConnectionId connectionId: UUID) -> Bool {
        entries.contains { $0.value.connectionId == connectionId }
    }

    func retainedReferences(forBookStableId stableId: String) -> [String] {
        retained[stableId] ?? []
    }

    /// Replace retained references with the service's latest response, including an empty array.
    func retainReferences(_ references: [String], forBookStableId stableId: String) {
        let kept = references.filter { !$0.isEmpty }
        guard kept != (retained[stableId] ?? []) else { return }
        retained[stableId] = kept.isEmpty ? nil : kept
        persist(retained, forKey: Self.retainedReferencesKey)
    }

    /// Only complete snapshots may remove missing endpoints; partial snapshots may add them.
    func apply(
        _ discovered: [String: OPDSProgressionEndpoint],
        connectionId: UUID,
        snapshotIsComplete: Bool
    ) {
        var updated = entries
        if snapshotIsComplete {
            updated = updated.filter { $0.value.connectionId != connectionId || discovered[$0.key] != nil }
        }
        for (stableId, endpoint) in discovered {
            updated[stableId] = Entry(connectionId: connectionId, endpoint: endpoint)
        }
        entries = updated
        persist(entries, forKey: Self.storageKey)
        pruneRetainedReferences()
    }

    func retainConnections(_ connectionIds: Set<UUID>) {
        let retainedEntries = entries.filter { connectionIds.contains($0.value.connectionId) }
        guard retainedEntries.count != entries.count else { return }
        entries = retainedEntries
        persist(entries, forKey: Self.storageKey)
        pruneRetainedReferences()
    }

    func clearAll() {
        entries.removeAll()
        retained.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.retainedReferencesKey)
    }

    /// A reference that outlived its service would be pushed to a publication Enve no longer syncs.
    private func pruneRetainedReferences() {
        let kept = retained.filter { entries[$0.key] != nil }
        guard kept.count != retained.count else { return }
        retained = kept
        persist(retained, forKey: Self.retainedReferencesKey)
    }

    private func persist(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
