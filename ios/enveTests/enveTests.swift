import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct BookStoreClearAllDataTests {
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
            "BookStoreTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        return SwiftDataBookStore(container: container)
    }

    private func makeBook() -> Book {
        Book(
            id: "book-1",
            title: "Delete Pipeline",
            source: .local,
            backendId: "unit",
            providerId: UUID(),
            libraryId: "library-1"
        )
    }

    @Test func clearAllDataRemovesAllPersistedEntities() async throws {
        let store = try makeStore()
        let book = makeBook()

        await store.upsertBooks([book])
        await store.upsertProgress(
            bookUniqueId: book.uniqueId,
            stableId: book.stableId,
            currentTime: 120,
            duration: 600,
            ebookProgress: nil,
            epubLocator: nil,
            isFinished: false,
            lastUpdate: Date(),
            hideFromContinue: false,
            preserveEbookPosition: false
        )
        await store.upsertLink(ebookStableId: "ebook-1", audiobookStableId: book.stableId, chapterOffset: 2)
        await store.upsertBookmark(
            Bookmark(bookId: book.id, position: 45, title: "Test mark", mediaType: .audiobook),
            bookStableId: book.stableId
        )
        await store.upsertAnnotation(
            ReaderAnnotation(bookId: book.id, position: 0.4, text: "Highlight"),
            bookStableId: book.stableId
        )
        await store.cacheChapters(
            [Chapter(id: "ch1", start: 0, end: 60, title: "One", index: 0)],
            forBookStableId: book.stableId
        )

        #expect(await store.bookCount() == 1)
        #expect(!(await store.allLinks().isEmpty))
        #expect(!(await store.bookmarks(forBookStableId: book.stableId).isEmpty))
        #expect(!(await store.annotations(forBookStableId: book.stableId).isEmpty))
        #expect(await store.cachedChapters(forBookStableId: book.stableId) != nil)
        #expect(await store.progress(forBookUniqueId: book.uniqueId) != nil)

        await store.clearAllData()

        #expect(await store.bookCount() == 0)
        #expect(await store.activeBooks(excludingSource: "booklore", minProgressThreshold: 0).isEmpty)
        #expect(await store.allLinks().isEmpty)
        #expect(await store.bookmarks(forBookStableId: book.stableId).isEmpty)
        #expect(await store.annotations(forBookStableId: book.stableId).isEmpty)
        #expect(await store.cachedChapters(forBookStableId: book.stableId) == nil)
        #expect(await store.progress(forBookUniqueId: book.uniqueId) == nil)
    }

    @Test func clearAllDataIsIdempotent() async throws {
        let store = try makeStore()
        await store.clearAllData()
        await store.clearAllData()
        #expect(await store.bookCount() == 0)
    }
}
