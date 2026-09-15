import Testing

@testable import enve

@MainActor
struct LibraryCatalogBatchSourceTests {
    @Test func partialPageImportsValidBooksWithoutCompletingSnapshot() async throws {
        let firstPage = LibraryCatalogPage(
            books: [Book(id: "valid-1", title: "Valid One")],
            totalCount: 2,
            isLast: false,
            isComplete: false
        )
        let finalPage = LibraryCatalogPage(
            books: [Book(id: "valid-2", title: "Valid Two")],
            totalCount: 2,
            isLast: true
        )
        let source = LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: 1,
            pageConcurrency: 1,
            resumeAfter: nil,
            expectedSnapshotIdentifier: nil,
            fetchPage: { page in
                #expect(page == 1)
                return finalPage
            }
        )

        let firstBatch = try #require(try await source.next())
        #expect(firstBatch.books.map(\.id) == ["valid-1"])
        #expect(firstBatch.resumeToken == nil)
        #expect(!firstBatch.completesSnapshot)

        let secondBatch = try #require(try await source.next())
        #expect(secondBatch.books.map(\.id) == ["valid-2"])
        #expect(secondBatch.resumeToken == nil)
        #expect(!secondBatch.completesSnapshot)
        #expect(try await source.next() == nil)
    }

    @Test func completePagesStillCompleteSnapshot() async throws {
        let firstPage = LibraryCatalogPage(
            books: [Book(id: "valid-1", title: "Valid One")],
            totalCount: 2,
            isLast: false
        )
        let finalPage = LibraryCatalogPage(
            books: [Book(id: "valid-2", title: "Valid Two")],
            totalCount: 2,
            isLast: true
        )
        let source = LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: 1,
            pageConcurrency: 1,
            resumeAfter: nil,
            expectedSnapshotIdentifier: nil,
            fetchPage: { _ in finalPage }
        )

        _ = try await source.next()
        let finalBatch = try #require(try await source.next())
        #expect(finalBatch.completesSnapshot)
        #expect(try await source.next() == nil)
    }

    @Test func incompleteWholeSnapshotImportsBooksWithoutAuthorizingReconciliation() async throws {
        let source = LibraryCatalogBatchSource.snapshot(
            books: [Book(id: "valid-1", title: "Valid One"), Book(id: "valid-2", title: "Valid Two")],
            batchSize: 1,
            isComplete: false,
            resumeAfter: nil,
            expectedSnapshotIdentifier: nil
        )

        let first = try #require(try await source.next())
        #expect(first.books.map(\.id) == ["valid-1"])
        #expect(first.resumeToken == nil)
        #expect(!first.completesSnapshot)

        let second = try #require(try await source.next())
        #expect(second.books.map(\.id) == ["valid-2"])
        #expect(second.resumeToken == nil)
        #expect(!second.completesSnapshot)
        #expect(try await source.next() == nil)
    }
}
