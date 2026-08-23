import Foundation
import Testing

@testable import enve

struct GrimmoryCatalogCheckpointStoreTests {
    @Test func resumesMatchingCatalogSnapshotWithCommittedProgress() throws {
        let connectionId = UUID()
        let libraryId = "library-\(UUID().uuidString)"
        defer { GrimmoryCatalogCheckpointStore.clear(connectionId: connectionId, libraryId: libraryId) }
        let firstPage = Data("first".utf8)
        var initial = try GrimmoryCatalogCheckpointStore.prepare(
            connectionId: connectionId,
            libraryId: libraryId,
            serverIdentity: "https://example.invalid",
            totalPages: 3,
            totalElements: 8,
            pageSize: 3,
            firstPageFingerprint: "snapshot-a",
            firstPageData: firstPage
        ).checkpoint
        try GrimmoryCatalogCheckpointStore.recordPage(Data("second".utf8), page: 1, checkpoint: &initial)
        try GrimmoryCatalogCheckpointStore.bindReconciliation(
            ReconciliationStart(generation: 7, existingCount: 4),
            checkpoint: &initial
        )
        try GrimmoryCatalogCheckpointStore.markCommitted(pages: [0, 1], bookCount: 6, checkpoint: &initial)

        let resumed = try GrimmoryCatalogCheckpointStore.prepare(
            connectionId: connectionId,
            libraryId: libraryId,
            serverIdentity: "https://example.invalid",
            totalPages: 3,
            totalElements: 8,
            pageSize: 3,
            firstPageFingerprint: "snapshot-a",
            firstPageData: firstPage
        )

        #expect(resumed.resumed)
        #expect(resumed.checkpoint.completedPages == [0, 1])
        #expect(resumed.checkpoint.committedPages == [0, 1])
        #expect(resumed.checkpoint.committedBookCount == 6)
        #expect(try GrimmoryCatalogCheckpointStore.pageData(connectionId: connectionId, libraryId: libraryId, page: 1) == Data("second".utf8))
    }

    @Test func changedSnapshotInvalidatesStagedPages() throws {
        let connectionId = UUID()
        let libraryId = "library-\(UUID().uuidString)"
        defer { GrimmoryCatalogCheckpointStore.clear(connectionId: connectionId, libraryId: libraryId) }
        var initial = try GrimmoryCatalogCheckpointStore.prepare(
            connectionId: connectionId,
            libraryId: libraryId,
            serverIdentity: "https://example.invalid",
            totalPages: 2,
            totalElements: 4,
            pageSize: 2,
            firstPageFingerprint: "snapshot-a",
            firstPageData: Data("first-a".utf8)
        ).checkpoint
        try GrimmoryCatalogCheckpointStore.recordPage(Data("second".utf8), page: 1, checkpoint: &initial)

        let replaced = try GrimmoryCatalogCheckpointStore.prepare(
            connectionId: connectionId,
            libraryId: libraryId,
            serverIdentity: "https://example.invalid",
            totalPages: 1,
            totalElements: 1,
            pageSize: 2,
            firstPageFingerprint: "snapshot-b",
            firstPageData: Data("first-b".utf8)
        )

        #expect(!replaced.resumed)
        #expect(replaced.checkpoint.completedPages == [0])
        #expect(throws: (any Error).self) {
            try GrimmoryCatalogCheckpointStore.pageData(connectionId: connectionId, libraryId: libraryId, page: 1)
        }
    }
}
