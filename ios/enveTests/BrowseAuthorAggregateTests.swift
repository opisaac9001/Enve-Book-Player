import Foundation
import SQLite3
import SwiftData
import Testing

@testable import enve

@MainActor
struct BrowseAuthorAggregateTests {
    private let providerId = UUID(uuidString: "6A0C2D7E-3F51-4B8A-9E2C-1D4F5A6B7C8D")!

    @Test func downloadedAudiobooksFindMatchesAcrossPageBoundaries() async throws {
        let store = try makeInMemoryStore()
        let books = (0..<1005).map { index in
            Book(id: String(format: "audio-%04d", index), title: "Audio \(index)", source: .local, providerId: providerId)
        }
        await store.upsertBooks(books)
        let selected = [books[0], books[1000], books[1004]]
        let keys = Set(selected.map { LocalStorageManager.sanitizedId(for: $0.stableId) })

        let downloaded = await store.downloadedAudiobooks(storageKeys: keys)

        #expect(Set(downloaded.map(\.uniqueId)) == Set(selected.map(\.uniqueId)))
        let sourceCounts = await store.bookCountsBySource()
        #expect(sourceCounts.count == 1)
        #expect(sourceCounts.first?.count == books.count)
        let sections = await store.bookCountsBySection(source: Book.BookSource.local.rawValue)
        #expect(sections.count == 1)
        #expect(sections.first?.count == books.count)
    }

    @Test func pagedStoreAggregationCountsEveryBookAcrossLexicalPageBoundaries() async throws {
        let store = try makeInMemoryStore()
        let books = fixtureBooks()
        await store.upsertBooks(books)
        await store.setDeleted(true, stableId: try #require(books.first { $0.id == "c1" }).stableId)

        let worker = store.makeWorker()
        let paged = try await worker.fetchBrowseAuthorAggregates(mediaType: "ebook", pageSize: 2)
        let unpaged = try await worker.fetchBrowseAuthorAggregates(mediaType: "ebook", pageSize: 1000)
        let byName = Dictionary(uniqueKeysWithValues: paged.map { ($0.name, $0) })

        #expect(Set(paged) == Set(unpaged))
        #expect(Set(byName.keys) == ["J.K. Rowling", "Neil Gaiman", "Terry Pratchett"])

        let rowling = try #require(byName["J.K. Rowling"])
        #expect(rowling.bookCount == 3)
        #expect(rowling.representativeThumb == "thumb-b10")
        #expect(rowling.representativeBookUniqueID == uniqueId("b10"))
        #expect(Set(rowling.matchingNames) == ["J.K. Rowling", "J.K. Rowling, Neil Gaiman", "JK Rowling"])

        let gaiman = try #require(byName["Neil Gaiman"])
        #expect(gaiman.bookCount == 2)
        #expect(gaiman.representativeThumb == "thumb-a2")
        #expect(gaiman.representativeBookUniqueID == uniqueId("a2"))
        #expect(Set(gaiman.matchingNames) == ["J.K. Rowling, Neil Gaiman", "Neil Gaiman"])

        let pratchett = try #require(byName["Terry Pratchett"])
        #expect(pratchett.bookCount == 1)
        #expect(pratchett.representativeThumb == nil)
        #expect(pratchett.representativeBookUniqueID == uniqueId("a10"))
    }

    @Test func mediaScopeMergeKeepsRepresentativeIdentityAndResolvesCoverWithinScope() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let books = fixtureBooks(providerId: fixture.providerID)
        await fixture.session.bookStore.upsertBooks(books)
        let library = fixture.session.engine.library

        let ebookFirst = await library.authorAggregates(mediaScope: ["ebook", "audiobook"])
        #expect(ebookFirst.map(\.name) == ["J.K. Rowling", "Neil Gaiman", "Terry Pratchett"])
        let gaiman = try #require(ebookFirst.first { $0.name == "Neil Gaiman" })
        #expect(gaiman.bookCount == 3)
        #expect(gaiman.representativeBookUniqueID == uniqueId("a2", providerId: fixture.providerID))
        #expect(ebookFirst.first { $0.name == "Terry Pratchett" }?.bookCount == 2)

        let cover = await library.coverBook(forAuthor: gaiman, mediaScope: ["ebook", "audiobook"])
        #expect(cover?.uniqueId == gaiman.representativeBookUniqueID)
        #expect(cover?.thumb == "thumb-a2")
        #expect(await library.coverBook(forAuthor: gaiman, mediaScope: ["audiobook"]) == nil)

        let audioFirst = await library.authorAggregates(mediaScope: ["audiobook", "ebook"])
        let audioGaiman = try #require(audioFirst.first { $0.name == "Neil Gaiman" })
        #expect(audioGaiman.bookCount == 3)
        #expect(audioGaiman.representativeBookUniqueID == uniqueId("z1", providerId: fixture.providerID))
        #expect(await library.coverBook(forAuthor: audioGaiman, mediaScope: ["audiobook"])?.mediaType == .audiobook)
        await fixture.close()
    }

    @Test func mergeFillsMissingThumbFromLaterMediaAndOrdersDeterministically() throws {
        let ebook = [
            BrowseAuthorAggregate(name: "Alpha", bookCount: 2, representativeThumb: nil, representativeBookUniqueID: "ebook-alpha"),
            BrowseAuthorAggregate(name: "alpha", bookCount: 1, representativeThumb: "t", representativeBookUniqueID: "ebook-lower"),
        ]
        let audio = [
            BrowseAuthorAggregate(
                name: "Alpha", bookCount: 4, representativeThumb: "audio-thumb", representativeBookUniqueID: "audio-alpha", matchingNames: ["A. Alpha"]
            ),
        ]

        let merged = LibraryEngine.mergedAuthorAggregates([ebook, audio])
        let reversed = LibraryEngine.mergedAuthorAggregates([[ebook[1], ebook[0]], audio])

        #expect(merged == reversed)
        #expect(Set(merged.map(\.name)) == ["Alpha", "alpha"])
        let alpha = try #require(merged.first { $0.name == "Alpha" })
        #expect(alpha.bookCount == 6)
        #expect(alpha.representativeThumb == "audio-thumb")
        #expect(alpha.representativeBookUniqueID == "audio-alpha")
        #expect(Set(alpha.matchingNames) == ["Alpha", "A. Alpha"])
    }

    @Test func inMemoryAggregationUsesFirstBookWithArtworkAsRepresentative() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let books = fixtureBooks(providerId: fixture.providerID).filter { $0.mediaType == .ebook }

        let aggregates = fixture.session.engine.library.authorAggregates(from: books)
        let byName = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.name, $0) })

        #expect(aggregates.map(\.name) == ["J.K. Rowling", "Neil Gaiman", "Terry Pratchett"])
        #expect(byName["J.K. Rowling"]?.bookCount == 3)
        #expect(byName["Terry Pratchett"]?.bookCount == 2)
        let gaiman = try #require(byName["Neil Gaiman"])
        let firstWithArtwork = try #require(books.first { $0.author?.contains("Neil Gaiman") == true && $0.thumb != nil })
        #expect(gaiman.representativeBookUniqueID == firstWithArtwork.uniqueId)
        #expect(gaiman.representativeThumb == firstWithArtwork.thumb)
        await fixture.close()
    }

    @Test func tunerIndexesServeAuthorPagingAndNameLookups() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeTunedStore(in: root)

        let paging = try queryPlan(
            "SELECT Z_PK FROM ZBOOKRECORD WHERE ZMEDIATYPE = 'ebook' AND ZISDELETED = 0 AND ZUNIQUEID > '' ORDER BY ZUNIQUEID LIMIT 1000",
            at: url
        )
        #expect(paging.contains { $0.contains("ZBOOKRECORD_MEDIATYPE_UNIQUEID_IDX") })
        #expect(!paging.contains { $0.contains("TEMP B-TREE") })

        let author = try queryPlan(
            "SELECT Z_PK FROM ZBOOKRECORD WHERE ZAUTHOR = 'Neil Gaiman' AND ZMEDIATYPE = 'ebook' AND ZISDELETED = 0",
            at: url
        )
        #expect(author.contains { $0.contains("ZBOOKRECORD_AUTHOR_MEDIATYPE_IDX") })

        let narrator = try queryPlan(
            "SELECT Z_PK FROM ZBOOKRECORD WHERE ZNARRATOR = 'Narrator' AND ZMEDIATYPE = 'audiobook' AND ZISDELETED = 0",
            at: url
        )
        #expect(narrator.contains { $0.contains("ZBOOKRECORD_NARRATOR_MEDIATYPE_IDX") })
    }

    @Test(arguments: ["", " AND ZLASTUPDATE <= 800000000 AND (ZLASTUPDATE < 800000000 OR ZUNIQUEID < 'z')"])
    func tunerIndexServesDownloadedEbookKeysetPagesWithoutSorting(cursorClause: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeTunedStore(in: root)

        let plan = try queryPlan(
            """
            SELECT Z_PK FROM ZBOOKRECORD WHERE ZMEDIATYPE = 'ebook' AND ZISDELETED = 0 AND ZISHIDDEN = 0 \
            AND (ZEBOOKFILEURLPATH IS NOT NULL OR (ZSOURCE = 'local' AND ZFILEPATH IS NOT NULL))\(cursorClause) \
            ORDER BY ZLASTUPDATE DESC, ZUNIQUEID DESC LIMIT 200
            """,
            at: url
        )
        #expect(plan.contains { $0.contains("ZBOOKRECORD_MEDIATYPE_LASTUPDATE_UNIQUE_IDX") })
        #expect(!plan.contains { $0.contains("TEMP B-TREE") })
    }

    private func makeTunedStore(in root: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration("BookStore", schema: schema, url: root.appendingPathComponent("BookStore.sqlite"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: BookStoreMigrationPlan.self, configurations: [configuration])
        await SwiftDataBookStore(container: container).upsertBooks(fixtureBooks())
        _ = try BookStoreSQLTuner.apply(to: configuration.url)
        return configuration.url
    }

    // Uppercase IDs sort before lowercase and "a10" before "a2" lexically, so a size-2 page splits each author's books.
    private func fixtureBooks(providerId: UUID? = nil) -> [Book] {
        let entries: [(id: String, author: String, thumb: String?, mediaType: AppMediaType)] = [
            ("b9", "J.K. Rowling", "thumb-b9", .ebook),
            ("b10", "JK Rowling", "thumb-b10", .ebook),
            ("B1", "J.K. Rowling, Neil Gaiman", nil, .ebook),
            ("a2", "Neil Gaiman", "thumb-a2", .ebook),
            ("a10", "Terry Pratchett", nil, .ebook),
            ("c1", "Terry Pratchett", "thumb-c1", .ebook),
            ("z1", "Neil Gaiman", "thumb-z1", .audiobook),
        ]
        return entries.map { entry in
            var book = Book(
                id: entry.id,
                title: "Book \(entry.id)",
                source: .local,
                backendId: "unit",
                providerId: providerId ?? self.providerId,
                libraryId: "library-1"
            )
            book.author = entry.author
            book.thumb = entry.thumb
            book.mediaType = entry.mediaType
            return book
        }
    }

    private func uniqueId(_ id: String, providerId: UUID? = nil) -> String {
        "\(providerId ?? self.providerId)_\(id)"
    }

    private func makeInMemoryStore() throws -> SwiftDataBookStore {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "BrowseAuthorAggregateTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func queryPlan(_ sql: String, at url: URL) throws -> [String] {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(sql)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) { details.append(String(cString: text)) }
        }
        return details
    }
}
