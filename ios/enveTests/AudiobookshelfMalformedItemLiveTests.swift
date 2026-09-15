import Foundation
import Testing

@testable import enve

@MainActor
struct AudiobookshelfMalformedItemLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_ABS_MALFORMED_FIXTURE_URL"] != nil))
    func malformedItemDoesNotRejectValidNeighbors() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["ENVE_ABS_MALFORMED_FIXTURE_URL"])
        let connection = ServerConnection(
            name: "Malformed ABS fixture",
            url: endpoint,
            type: .audiobookshelf,
            token: "fixture-token"
        )
        let provider = AudiobookshelfProvider(connection: connection)
        RejectedContentStore.shared.clear()
        defer { RejectedContentStore.shared.clear() }

        let source = try await provider.makeCatalogBatchSource(
            libraryId: "library-1",
            resumeAfter: nil,
            expectedSnapshotIdentifier: nil
        )
        let batch = try #require(try await source.next())

        #expect(batch.books.map(\.id) == ["valid-1", "valid-2"])
        #expect(!batch.completesSnapshot)
        #expect(batch.resumeToken == nil)
        #expect(try await source.next() == nil)

        let rejected = try #require(RejectedContentStore.shared.entries.first)
        #expect(RejectedContentStore.shared.entries.count == 1)
        #expect(rejected.itemIdentifier == "broken-1")
    }
}
