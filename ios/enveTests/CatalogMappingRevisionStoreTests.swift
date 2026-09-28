import Foundation
import Testing

@testable import enve

struct CatalogMappingRevisionStoreTests {
    @Test func aLibraryReconciledByOlderMappingIsStaleUntilReconciledAgain() throws {
        let suiteName = "CatalogMappingRevisionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CatalogMappingRevisionStore(defaults: defaults)
        let providerId = UUID()

        #expect(!store.isStale(providerId: providerId, libraryId: "books", revision: 0))
        #expect(store.isStale(providerId: providerId, libraryId: "books", revision: 1))

        store.recordReconciled(providerId: providerId, libraryId: "books", revision: 1)

        #expect(!store.isStale(providerId: providerId, libraryId: "books", revision: 1))
        #expect(store.isStale(providerId: providerId, libraryId: "podcasts", revision: 1))
        #expect(!CatalogMappingRevisionStore(defaults: defaults).isStale(providerId: providerId, libraryId: "books", revision: 1))
        #expect(CatalogMappingRevisionStore(defaults: defaults).isStale(providerId: providerId, libraryId: "books", revision: 2))
    }
}
