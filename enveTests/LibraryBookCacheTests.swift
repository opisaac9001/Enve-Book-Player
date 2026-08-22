import Combine
import Foundation
import Testing

@testable import enve

@MainActor
struct LibraryBookCacheTests {
    @Test func rebuildingBooksUpdatesBothIndexes() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let first = book(id: "one", stableId: "stable-one")
        let second = book(id: "two", stableId: "stable-two")

        cache.books = [first, second]

        #expect(cache.uniqueIdIndex[first.uniqueId] == 0)
        #expect(cache.uniqueIdIndex[second.uniqueId] == 1)
        #expect(cache.stableIdIndex[first.stableId] == 0)
        #expect(cache.stableIdIndex[second.stableId] == 1)
    }

    @Test func duplicateUniqueIdsAreRemovedBeforePublishing() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let providerId = UUID()
        let original = book(id: "same", stableId: "original", providerId: providerId)
        let duplicate = book(id: "same", stableId: "duplicate", providerId: providerId)
        var notificationCount = 0
        let cancellable = cache.changes.sink { notificationCount += 1 }

        cache.books = [original, duplicate]

        #expect(cache.books == [original])
        #expect(cache.uniqueIdIndex == [original.uniqueId: 0])
        #expect(notificationCount == 1)
        _ = cancellable
    }

    @Test func suppressedMutationCanRebuildAndPublishExplicitly() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        var notificationCount = 0
        let cancellable = cache.changes.sink { notificationCount += 1 }
        cache.suppressNotifications = true
        cache.skipsIndexRebuild = true

        let stored = book(id: "stored", stableId: "stable")
        cache.books = [stored]

        #expect(cache.uniqueIdIndex.isEmpty)
        #expect(notificationCount == 0)
        cache.skipsIndexRebuild = false
        cache.rebuildIndices()
        cache.suppressNotifications = false
        cache.changes.send(())
        #expect(cache.uniqueIdIndex[stored.uniqueId] == 0)
        #expect(notificationCount == 1)
        _ = cancellable
    }

    @Test func replacingExistingBookPreservesIndexes() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let original = book(id: "stored", stableId: "stable")
        cache.books = [original]
        var replacement = original
        replacement.title = "Updated"

        #expect(cache.replaceExisting(replacement))
        #expect(cache.book(uniqueId: original.uniqueId)?.title == "Updated")
        #expect(cache.uniqueIdIndex[original.uniqueId] == 0)
        #expect(cache.stableIdIndex[original.stableId] == 0)
    }

    private func book(id: String, stableId: String, providerId: UUID = UUID()) -> Book {
        Book(
            id: id,
            title: id,
            source: .local,
            mediaType: .ebook,
            providerId: providerId,
            libraryId: stableId
        )
    }
}

private final class NoopBookWriter: BookWriting {
    func upsertBooks(_ books: [Book]) async {}
    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async {}
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int { 0 }
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int { 0 }
    func updateEbookFileURL(uniqueId: String, url: URL?) async {}
    func setHidden(_ hidden: Bool, stableId: String) async {}
    func setDeleted(_ deleted: Bool, stableId: String) async {}
    func deleteBooks(uniqueIds: Set<String>) async {}
    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {}
    func clearAllData() async {}
}

@MainActor
private final class SessionStub: CurrentBookSession {
    var currentBook: Book?
}

@MainActor
private final class RecordingBookWriter: BookWriting {
    private(set) var upserts: [[Book]] = []
    private var waiter: CheckedContinuation<[Book], Never>?

    /// Suspends until the cache's write-through reaches the writer.
    func nextUpsert() async -> [Book] {
        if let recorded = upserts.first { return recorded }
        return await withCheckedContinuation { waiter = $0 }
    }

    func upsertBooks(_ books: [Book]) async {
        upserts.append(books)
        waiter?.resume(returning: books)
        waiter = nil
    }
    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async {}
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int { 0 }
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int { 0 }
    func updateEbookFileURL(uniqueId: String, url: URL?) async {}
    func setHidden(_ hidden: Bool, stableId: String) async {}
    func setDeleted(_ deleted: Bool, stableId: String) async {}
    func deleteBooks(uniqueIds: Set<String>) async {}
    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {}
    func clearAllData() async {}
}

@MainActor
struct LibraryBookCacheOwnershipTests {
    @Test func mutatingByUniqueIdUpdatesMirrorHotCacheAndSession() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let session = SessionStub()
        cache.session = session
        let stored = book(id: "one", stableId: "stable-one")
        cache.books = [stored]
        session.currentBook = stored

        let updated = cache.mutateBook(uniqueId: stored.uniqueId) { $0.title = "Renamed" }

        #expect(updated?.title == "Renamed")
        #expect(cache.books[0].title == "Renamed")
        #expect(cache.hot.book(uniqueId: stored.uniqueId)?.title == "Renamed")
        #expect(session.currentBook?.title == "Renamed")
    }

    @Test func mutatingLeavesUnrelatedSessionBookAlone() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let session = SessionStub()
        cache.session = session
        let stored = book(id: "one", stableId: "stable-one")
        let selected = book(id: "two", stableId: "stable-two")
        cache.books = [stored, selected]
        session.currentBook = selected

        cache.mutateBook(uniqueId: stored.uniqueId) { $0.title = "Renamed" }

        #expect(session.currentBook?.title == selected.title)
    }

    @Test func mutatingAnUnknownIdentifierReportsNoChange() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        cache.books = [book(id: "one", stableId: "stable-one")]

        #expect(cache.mutateBook(uniqueId: "missing") { $0.title = "Renamed" } == nil)
        #expect(cache.mutateBook(stableId: "missing") { $0.title = "Renamed" } == nil)
    }

    @Test func batchedMutationPublishesOnceAndRebuildsIndexes() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let first = book(id: "one", stableId: "stable-one")
        let second = book(id: "two", stableId: "stable-two")
        cache.books = [first, second]

        var notificationCount = 0
        let cancellable = cache.changes.sink { notificationCount += 1 }

        let updated = cache.mutateBooks([
            (uniqueId: first.uniqueId, transform: { $0.title = "A" }),
            (uniqueId: second.uniqueId, transform: { $0.title = "B" }),
        ])

        #expect(updated.map(\.title) == ["A", "B"])
        #expect(notificationCount == 0)
        #expect(cache.uniqueIdIndex[second.uniqueId] == 1)
        _ = cancellable
    }

    @Test func batchRestoresThePriorInvalidationPolicy() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        cache.suppressNotifications = true
        cache.skipsIndexRebuild = true

        cache.performBatch {
            cache.books = [book(id: "one", stableId: "stable-one")]
        }

        #expect(cache.suppressNotifications)
        #expect(cache.skipsIndexRebuild)
        #expect(cache.uniqueIdIndex.isEmpty)
    }

    @Test func transactionPublishesASingleChangeOnUnwind() async {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        var notificationCount = 0
        let cancellable = cache.changes.sink { notificationCount += 1 }

        await cache.performTransaction {
            cache.books = [book(id: "one", stableId: "stable-one")]
            cache.books.append(book(id: "two", stableId: "stable-two"))
        }

        #expect(notificationCount == 1)
        #expect(cache.uniqueIdIndex.count == 2)
        _ = cancellable
    }

    @Test func mutationWritesThroughToPersistence() async {
        let writer = RecordingBookWriter()
        let cache = LibraryBookCache(writer: writer)
        let stored = book(id: "one", stableId: "stable-one")
        cache.books = [stored]

        cache.mutateBook(uniqueId: stored.uniqueId) { $0.title = "Renamed" }

        #expect(await writer.nextUpsert().contains { $0.title == "Renamed" })
    }

    @Test func loadingASnapshotSkipsDeduplicationAndWarmsTheHotCache() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let stored = book(id: "one", stableId: "stable-one")

        cache.load([stored])

        #expect(cache.books == [stored])
        #expect(cache.hot.book(uniqueId: stored.uniqueId) == stored)
        #expect(!cache.skipsDeduplication)
    }

    @Test func ensureBookInMemoryIsIdempotentPerStableId() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let stored = book(id: "one", stableId: "stable-one")

        cache.ensureBookInMemory(stored)
        cache.ensureBookInMemory(stored)

        #expect(cache.books.count == 1)
    }

    @Test func hotCacheLookupPromotesMirrorHits() {
        let cache = LibraryBookCache(writer: NoopBookWriter())
        let stored = book(id: "one", stableId: "stable-one")
        cache.books = [stored]

        #expect(cache.hot.book(uniqueId: stored.uniqueId) == nil)
        #expect(cache.bookInMemory(uniqueId: stored.uniqueId) == stored)
        #expect(cache.hot.book(uniqueId: stored.uniqueId) == stored)
    }

    private func book(id: String, stableId: String, providerId: UUID = UUID()) -> Book {
        Book(
            id: id,
            title: id,
            source: .local,
            mediaType: .ebook,
            providerId: providerId,
            libraryId: stableId
        )
    }
}
