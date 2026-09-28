import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct BookStoreRepositoryContractTests {
    @Test func queryAndWriteFacetsShareOneAuthoritativeStore() async throws {
        let store = try makeStore()
        let querying: any BookQuerying = store
        let writing: any BookWriting = store
        let book = makeBook()

        await writing.upsertBooks([book])

        #expect(await querying.book(uniqueId: book.uniqueId)?.stableId == book.stableId)
        #expect(await querying.bookCount() == 1)
        #expect(await querying.allBookUniqueIds() == [book.uniqueId])
    }

    @Test func progressFacetRoundTripsAuthoritativeProgress() async throws {
        let store = try makeStore()
        let writing: any BookWriting = store
        let progress: any ProgressRepository = store
        let book = makeBook()
        let observedAt = Date(timeIntervalSince1970: 500)
        await writing.upsertBooks([book])

        await progress.upsertProgress(
            bookUniqueId: book.uniqueId,
            stableId: book.stableId,
            currentTime: 120,
            duration: 600,
            ebookProgress: nil,
            epubLocator: nil,
            isFinished: false,
            lastUpdate: observedAt,
            hideFromContinue: false,
            preserveEbookPosition: false
        )

        let snapshot = await progress.progress(forBookUniqueId: book.uniqueId)
        #expect(snapshot?.currentTime == 120)
        #expect(snapshot?.duration == 600)
        #expect(snapshot?.lastUpdate == observedAt)
    }

    @Test func ebookProgressUpdateMirrorsExactLocatorIntoProgressFacet() async throws {
        let store = try makeStore()
        let writing: any BookWriting = store
        let progress: any ProgressRepository = store
        var book = makeBook()
        book.mediaType = .ebook
        book.lastUpdate = Date(timeIntervalSince1970: 100)
        let locator = #"{"href":"OEBPS/c11.xhtml","locations":{"totalProgression":0.0034722222222222225,"progression":0.5,"enveSourceEngine":"readium","position":6},"type":"application/xhtml+xml"}"#
        let observedAt = Date(timeIntervalSince1970: 700)
        await writing.upsertBooks([book])

        await progress.updateEbookProgress(
            uniqueId: book.uniqueId,
            ebookProgress: 0.0034722222222222225,
            epubLocator: locator,
            isFinished: false,
            lastUpdate: observedAt
        )

        let snapshot = await progress.progress(forBookUniqueId: book.uniqueId)
        #expect(snapshot?.ebookProgress == 0.0034722222222222225)
        #expect(snapshot?.epubLocator == locator)
        #expect(snapshot?.lastUpdate == observedAt)
        #expect(await store.book(uniqueId: book.uniqueId)?.epubLocator == locator)
    }

    @Test func ebookBookSnapshotUpsertMirrorsExactLocatorIntoProgressFacet() async throws {
        let store = try makeStore()
        let writing: any BookWriting = store
        let progress: any ProgressRepository = store
        var book = makeBook()
        book.mediaType = .ebook
        book.ebookProgress = 0.4753787878787879
        book.currentTime = 21.392045454545457
        book.duration = 45
        book.lastUpdate = Date(timeIntervalSince1970: 900)
        let locator = #"{"href":"OEBPS/c2AA.xhtml","locations":{"enveSourceEngine":"readium","progression":0.9375,"totalProgression":0.4753787878787879,"position":754},"type":"application/xhtml+xml"}"#
        book.epubLocator = locator

        await writing.upsertBooks([book])

        let snapshot = await progress.progress(forBookUniqueId: book.uniqueId)
        #expect(snapshot?.ebookProgress == book.ebookProgress)
        #expect(snapshot?.epubLocator == locator)
        #expect(snapshot?.currentTime == book.currentTime)
        #expect(snapshot?.duration == book.duration)
        #expect(snapshot?.lastUpdate == book.lastUpdate)
    }

    @Test func readerArtifactFacetRoundTripsIndependentArtifacts() async throws {
        let store = try makeStore()
        let artifacts: any ReaderArtifactRepository = store
        let bookmark = Bookmark(bookId: "book-1", position: 42, title: "Mark", mediaType: .audiobook)
        let annotation = ReaderAnnotation(bookId: "book-1", position: 0.5, text: "Note")

        await artifacts.upsertBookmark(bookmark, bookStableId: "stable-1")
        await artifacts.upsertAnnotation(annotation, bookStableId: "stable-1")
        await artifacts.cacheChapters(
            [Chapter(id: "chapter-1", start: 0, end: 60, title: "One", index: 0)],
            forBookStableId: "stable-1"
        )

        #expect(await artifacts.bookmarks(forBookStableId: "stable-1").map(\.id) == [bookmark.id])
        #expect(await artifacts.annotations(forBookStableId: "stable-1").map(\.id) == [annotation.id])
        #expect(await artifacts.cachedChapters(forBookStableId: "stable-1")?.map(\.id) == ["chapter-1"])
        #expect(await store.readerArtifactBookStableIds() == ["stable-1"])
    }

    @Test func optimizedLibraryProjectionsReturnOnlyRelevantRows() async throws {
        let store = try makeStore()
        var downloaded = makeBook()
        downloaded.isFinished = true
        downloaded.lastUpdate = Date(timeIntervalSince1970: 1_000)

        let other = Book(
            id: "book-2",
            title: "Other Book",
            source: .local,
            backendId: "unit",
            providerId: downloaded.providerId,
            libraryId: "library-1"
        )
        await store.upsertBooks([downloaded, other])

        let storageKey = LocalStorageManager.sanitizedId(for: downloaded.downloadKey)
        let downloadedBooks = await store.downloadedAudiobooks(storageKeys: [storageKey])
        #expect(downloadedBooks.map(\.stableId) == [downloaded.stableId])

        let finished = await store.finishedBookSummaries()
        #expect(finished == [FinishedBookSummary(
            stableId: downloaded.stableId,
            mediaType: .audiobook,
            lastUpdate: downloaded.lastUpdate
        )])

        let slices = await store.bookStatisticsSlices()
        #expect(Set(slices.map(\.id)) == [downloaded.id, other.id])
        #expect(slices.first(where: { $0.id == downloaded.id })?.progress == 1)
    }

    @Test func seriesAggregatesScopeToTheSourceInsteadOfASample() async throws {
        let store = try makeStore()
        let abs = UUID()
        let komga = UUID()
        func book(_ id: String, series: String, provider: UUID, library: String) -> Book {
            var book = Book(
                id: id,
                title: id,
                source: .audiobookshelf,
                backendId: "unit",
                providerId: provider,
                libraryId: library
            )
            book.series = series
            book.mediaType = .ebook
            return book
        }
        await store.upsertBooks([
            book("a1", series: "Gutenberg", provider: abs, library: "books"),
            book("a2", series: "Gutenberg", provider: abs, library: "books"),
            book("a3", series: "Austen", provider: abs, library: "classics"),
            book("k1", series: "Comics", provider: komga, library: "books"),
        ])

        let connection = await store.browseSeriesAggregates(mediaType: "ebook", providerId: abs, libraryId: nil)
        let library = await store.browseSeriesAggregates(mediaType: "ebook", providerId: abs, libraryId: "classics")

        #expect(Dictionary(uniqueKeysWithValues: connection.map { ($0.name, $0.bookCount) }) == ["Gutenberg": 2, "Austen": 1])
        #expect(library.map(\.name) == ["Austen"])
    }

    private func makeStore() throws -> SwiftDataBookStore {
        let schema = Schema([
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
        ])
        let config = ModelConfiguration(
            "BookStoreContractTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return SwiftDataBookStore(
            container: try ModelContainer(for: schema, configurations: [config])
        )
    }

    private func makeBook() -> Book {
        Book(
            id: "book-1",
            title: "Repository Contract",
            source: .local,
            backendId: "unit",
            providerId: UUID(uuidString: "037F7AEC-8674-481B-AE53-8F93B92B9401")!,
            libraryId: "library-1"
        )
    }
}
