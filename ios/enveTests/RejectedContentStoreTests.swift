import Foundation
import Testing

@testable import enve

@MainActor
struct RejectedContentStoreTests {
    private struct FixtureItem: Decodable, Equatable {
        let id: String
        let title: String
        let duration: Double
    }

    @Test func lossyArrayKeepsValidNeighborsAndDescribesOnlyMalformedItem() throws {
        let data = Data(
            #"[{"id":"valid-1","title":"One","duration":10},{"id":"broken-1","title":"Broken","duration":"invalid"},{"id":"valid-2","title":"Two","duration":20}]"#.utf8
        )

        let decoded = try JSONDecoder().decode(LossyDecodableArray<FixtureItem>.self, from: data)

        #expect(decoded.values.map(\.id) == ["valid-1", "valid-2"])
        #expect(decoded.rejectedItems.count == 1)
        #expect(decoded.rejectedItems.first?.itemIdentifier == "broken-1")
        #expect(decoded.rejectedItems.first?.title == "Broken")
        #expect(decoded.rejectedItems.first?.reason == "Unexpected value at Index 1.duration.")
    }

    @Test func lossyArrayFindsCommonProviderIdentityShapes() throws {
        struct MetadataFixture: Decodable {
            struct Metadata: Decodable {
                let identifier: String
                let title: String
            }

            let metadata: Metadata
            let required: Int
        }

        let data = Data(
            #"[{"metadata":{"identifier":"opds-1","title":"Broken OPDS item"},"required":"invalid"}]"#.utf8
        )
        let decoded = try JSONDecoder().decode(LossyDecodableArray<MetadataFixture>.self, from: data)

        #expect(decoded.values.isEmpty)
        #expect(decoded.rejectedItems.first?.itemIdentifier == "opds-1")
        #expect(decoded.rejectedItems.first?.title == "Broken OPDS item")
    }

    @Test func recordsOnlyRejectedItemsAndResolvesThemAfterAValidImport() throws {
        let suiteName = "RejectedContentStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RejectedContentStore(defaults: defaults)
        let providerId = UUID()

        store.record(
            providerId: providerId,
            providerType: .audiobookshelf,
            sourceName: "Fixture",
            libraryId: "library-1",
            candidates: [
                RejectedContentCandidate(
                    itemIdentifier: "broken-1",
                    title: "Broken fixture",
                    reason: "Unexpected value at results.Index 1.media.metadata.",
                    fallbackIdentifier: "page-0-item-1"
                )
            ]
        )

        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.itemIdentifier == "broken-1")
        #expect(entry.title == "Broken fixture")

        store.resolve(
            providerId: providerId,
            libraryId: "library-1",
            itemIdentifiers: ["valid-1", "valid-2"]
        )
        #expect(store.entries.count == 1)

        store.resolve(
            providerId: providerId,
            libraryId: "library-1",
            itemIdentifiers: ["broken-1"]
        )
        #expect(store.entries.isEmpty)
    }

    @Test func duplicateRejectionsUpdateOnePersistentEntry() throws {
        let suiteName = "RejectedContentStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providerId = UUID()
        let candidate = RejectedContentCandidate(
            itemIdentifier: "broken-1",
            title: nil,
            reason: "Missing media at results.Index 1.",
            fallbackIdentifier: "page-0-item-1"
        )
        let store = RejectedContentStore(defaults: defaults)

        store.record(
            providerId: providerId,
            providerType: .audiobookshelf,
            sourceName: "Fixture",
            libraryId: "library-1",
            candidates: [candidate],
            at: Date(timeIntervalSince1970: 10)
        )
        store.record(
            providerId: providerId,
            providerType: .audiobookshelf,
            sourceName: "Fixture",
            libraryId: "library-1",
            candidates: [candidate],
            at: Date(timeIntervalSince1970: 20)
        )

        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.rejectionCount == 2)
        #expect(entry.lastRejectedAt == Date(timeIntervalSince1970: 20))
        #expect(RejectedContentStore(defaults: defaults).entries == store.entries)
    }
}
