import Foundation
import Testing

@testable import enve

@MainActor
struct SavedBooksStoreTests {
    @Test func savesDistinctProviderBooksAndRestoresBothLists() throws {
        let suite = "SavedBooksStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedBooksStore(defaults: defaults)
        store.toggle("provider-one_book", in: .favorites)
        store.toggle("provider-two_book", in: .favorites)
        store.toggle("provider-one_book", in: .later)

        #expect(store.favorites == ["provider-two_book", "provider-one_book"])
        #expect(store.later == ["provider-one_book"])

        let restored = SavedBooksStore(defaults: defaults)
        #expect(restored.favorites == store.favorites)
        #expect(restored.later == store.later)

        restored.toggle("provider-one_book", in: .favorites)
        #expect(restored.favorites == ["provider-two_book"])
        #expect(restored.contains("provider-one_book", in: .later))
    }

    @Test func firstServerRefreshPreservesLocalSavesUntilConfirmed() throws {
        let suite = "SavedBooksStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providerId = UUID()
        let id = "\(providerId)_book"
        let store = SavedBooksStore(defaults: defaults)
        store.toggle(id, in: .favorites)

        store.prepareFirstSync(providerId: providerId)
        store.reconcile(providerId: providerId, snapshot: [.favorites: [], .later: []])
        #expect(store.favorites == [id])
        #expect(store.pendingMutations(for: providerId).count == 1)

        let restored = SavedBooksStore(defaults: defaults)
        restored.reconcile(providerId: providerId, snapshot: [.favorites: ["book"], .later: []])
        #expect(restored.favorites == [id])
        #expect(restored.pending.isEmpty)

        restored.reconcile(providerId: providerId, snapshot: [.favorites: [], .later: []])
        #expect(restored.favorites.isEmpty)
    }

    @Test func pendingRemovalOverlaysStaleServerSnapshotWithoutTouchingOtherSources() throws {
        let suite = "SavedBooksStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstProvider = UUID()
        let secondProvider = UUID()
        let firstId = "\(firstProvider)_same-id"
        let secondId = "\(secondProvider)_same-id"
        let store = SavedBooksStore(defaults: defaults)
        store.toggle(secondId, in: .favorites)
        store.prepareFirstSync(providerId: firstProvider)
        store.reconcile(providerId: firstProvider, snapshot: [.favorites: ["same-id"], .later: []])

        store.set(firstId, in: .favorites, saved: false, enqueue: true)
        store.reconcile(providerId: firstProvider, snapshot: [.favorites: ["same-id"], .later: []])
        #expect(store.favorites == [secondId])
        #expect(store.pendingMutations(for: firstProvider).count == 1)

        store.reconcile(providerId: firstProvider, snapshot: [.favorites: [], .later: []])
        #expect(store.favorites == [secondId])
        #expect(store.pendingMutations(for: firstProvider).isEmpty)
    }
}
