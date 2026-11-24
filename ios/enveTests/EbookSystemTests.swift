import Foundation
import CoreSpotlight
import SwiftData
import Testing

@testable import enve

@MainActor
struct EbookSystemTests {
    @Test func searchFindsBooksBeyondTheFirstLibraryPage() async throws {
        let store = try makeStore()
        var books = (0..<600).map { book("book-\($0)", title: "Catalog book \($0)") }
        books[599].title = "The Distant Lighthouse"
        books[599].author = "Mira Vale"
        await store.upsertBooks(books)
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }

        #expect(await fixture.service.search("  Distant Lighthouse  ").map(\.id) == [books[599].stableId])
        #expect(await fixture.service.search("Mira Vale").map(\.id) == [books[599].stableId])
    }

    @Test func hiddenDeletedAndAudioBooksCannotResolve() async throws {
        let store = try makeStore()
        let visible = book("visible")
        let hidden = book("hidden")
        let deleted = book("deleted")
        var audio = book("audio")
        audio.mediaType = .audiobook
        await store.upsertBooks([visible, hidden, deleted, audio])
        await store.setHidden(true, stableId: hidden.stableId)
        await store.setDeleted(true, stableId: deleted.stableId)
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }

        #expect(await fixture.service.entities(for: [hidden.stableId, deleted.stableId, audio.stableId, visible.stableId]).map(\.id) == [visible.stableId])
        await #expect(throws: EbookSystemError.self) { try await fixture.service.requestOpen(hidden.stableId) }
        #expect(fixture.service.pendingRequest == nil)
    }

    @Test func continueUsesLastOpenedAndPreservesItsLocator() async throws {
        let store = try makeStore()
        var last = book("last")
        last.epubLocator = #"{"href":"chapter-3.xhtml","locations":{"totalProgression":0.3}}"#
        await store.upsertBooks([last])
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        fixture.lastOpened.record(last)

        try await fixture.service.requestContinue()
        let request = try #require(fixture.service.pendingRequest)
        #expect(await fixture.service.resolve(request)?.epubLocator == last.epubLocator)
    }

    @Test func continueFallsBackWhenLastOpenedWasRemoved() async throws {
        let store = try makeStore()
        var reading = book("reading")
        reading.ebookProgress = 0.3
        reading.lastUpdate = Date()
        let removed = book("removed")
        await store.upsertBooks([reading, removed])
        await store.setDeleted(true, stableId: removed.stableId)
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        fixture.lastOpened.record(removed)

        try await fixture.service.requestContinue()
        #expect(fixture.service.pendingRequest?.bookID == reading.stableId)
    }

    @Test func noReadingHistoryReturnsAnActionableError() async throws {
        let fixture = makeService(try makeStore())
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        await #expect(throws: EbookSystemError.nothingToContinue) { try await fixture.service.requestContinue() }
    }

    @Test func continueSkipsFinishedAndDismissedLastOpenedBooks() async throws {
        let store = try makeStore()
        var finished = book("finished")
        finished.isFinished = true
        var dismissed = book("dismissed")
        dismissed.hideFromContinue = true
        await store.upsertBooks([finished, dismissed])
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        for book in [finished, dismissed] {
            fixture.lastOpened.record(book)
            await #expect(throws: EbookSystemError.nothingToContinue) { try await fixture.service.requestContinue() }
        }
    }

    @Test func revokedAccessCannotQueryOrDeliverPendingBooks() async throws {
        let store = try makeStore()
        let ebook = book("private")
        await store.upsertBooks([ebook])
        var allowed = true
        let fixture = makeService(store, isAllowed: { allowed })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        try await fixture.service.requestOpen(ebook.stableId)
        let request = try #require(fixture.service.pendingRequest)
        allowed = false

        #expect(await fixture.service.search("Book").isEmpty)
        #expect(await fixture.service.suggestions().isEmpty)
        #expect(await fixture.service.spotlightBooks().isEmpty)
        #expect(await fixture.service.entities(for: [ebook.stableId]).isEmpty)
        #expect(await fixture.service.resolve(request) == nil)
        await #expect(throws: EbookSystemError.self) { try await fixture.service.requestContinue() }
        fixture.service.revoke()
        #expect(fixture.service.pendingRequest == nil)
    }

    @Test func finishingOldRequestDoesNotConsumeNewerRequest() async throws {
        let store = try makeStore()
        let first = book("first")
        let second = book("second")
        await store.upsertBooks([first, second])
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        try await fixture.service.requestOpen(first.stableId)
        let old = try #require(fixture.service.pendingRequest)
        try await fixture.service.requestOpen(second.stableId)
        fixture.service.finish(old)

        #expect(await fixture.service.resolve(old) == nil)
        #expect(fixture.service.pendingRequest?.bookID == second.stableId)
    }

    @Test func suggestionsDeduplicateLastOpenedAndContinueReading() async throws {
        let store = try makeStore()
        var ebook = book("reading")
        ebook.ebookProgress = 0.4
        await store.upsertBooks([ebook])
        let fixture = makeService(store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        fixture.lastOpened.record(ebook)
        #expect(await fixture.service.suggestions().map(\.id) == [ebook.stableId])
    }

    @Test func spotlightUsesNamespacedIDsWithoutExportingServerURLs() {
        var ebook = book("book:123")
        ebook.author = "Mira Vale"
        ebook.thumb = "https://example.invalid/cover?token=private"
        let item = EbookSpotlightIndex.item(SystemEbook(ebook))
        #expect(EbookSpotlightIndex.bookID(from: item.uniqueIdentifier) == ebook.stableId)
        #expect(EbookSpotlightIndex.bookID(from: "other-app:123") == nil)
        #expect(EbookSpotlightIndex.bookID(from: EbookSpotlightIndex.domain + ":") == nil)
        #expect(item.attributeSet.title == ebook.title)
        #expect(item.attributeSet.authorNames == ["Mira Vale"])
        #expect(item.attributeSet.contentURL == nil)
        #expect(item.attributeSet.thumbnailURL == nil)
    }

    private func makeService(_ store: SwiftDataBookStore, isAllowed: @escaping () -> Bool = { true }) ->
        (service: EbookSystemService, lastOpened: LastOpenedBookStore, defaults: UserDefaults, name: String) {
        let name = "EbookSystemTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let lastOpened = LastOpenedBookStore(defaults: defaults)
        return (EbookSystemService(books: store, lastOpened: lastOpened, isAllowed: isAllowed), lastOpened, defaults, name)
    }

    private func makeStore() throws -> SwiftDataBookStore {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let config = ModelConfiguration("EbookSystemTests-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [config]))
    }

    private func book(_ id: String, title: String = "Book") -> Book {
        Book(id: id, title: title, source: .local, backendId: id, mediaType: .ebook)
    }
}
