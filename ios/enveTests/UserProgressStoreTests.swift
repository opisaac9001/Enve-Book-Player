import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
private final class ProgressSessionStub: CurrentBookSession {
    var currentBook: Book?
}

@MainActor
private final class ProgressConnectionStub: ProviderConnectionAccessing {
    var connections: [ServerConnection] = []

    func backend(id: String) -> BackendConfig? { nil }
    func allBackends() -> [BackendConfig] { [] }
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
private final class ProgressNoopWriter: BookWriting {
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
private struct ProgressFixture {
    let library = LibraryBookCache(writer: ProgressNoopWriter())
    let session = ProgressSessionStub()
    let connections = ProgressConnectionStub()
    let store: SwiftDataBookStore
    let progressFileURL: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults

    init() throws {
        let schema = Schema([
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
        ])
        let configuration = ModelConfiguration(
            "UserProgressStoreTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        store = SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
        progressFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserProgressStoreTests-\(UUID().uuidString).json")
        defaultsSuiteName = "UserProgressStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    func makeStore() -> UserProgressStore {
        UserProgressStore(
            library: library,
            session: session,
            bookStore: store,
            providerConnections: connections,
            progressFileURL: progressFileURL,
            progressCache: BookProgressStore(defaults: defaults),
            defaults: defaults
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: progressFileURL)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}

@MainActor
struct UserProgressStoreTests {
    @Test func updatePublishesProgressIntoMirrorAndSession() throws {
        let fixture = try ProgressFixture()
        let book = makeBook(id: "one", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [book]
        fixture.session.currentBook = book
        let store = fixture.makeStore()

        store.update(makeProgress(for: book, currentTime: 120, at: Date(timeIntervalSince1970: 500)))

        #expect(store.progress(forUniqueId: book.uniqueId)?.currentTime == 120)
        #expect(fixture.library.books[0].currentTime == 120)
        #expect(fixture.library.hot.book(uniqueId: book.uniqueId)?.currentTime == 120)
        #expect(fixture.session.currentBook?.currentTime == 120)
        fixture.cleanUp()
    }

    @Test func updateIgnoresProgressOlderThanTheStoredEntry() throws {
        let fixture = try ProgressFixture()
        let book = makeBook(id: "one", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [book]
        let store = fixture.makeStore()

        store.update(makeProgress(for: book, currentTime: 120, at: Date(timeIntervalSince1970: 500)))
        store.update(makeProgress(for: book, currentTime: 5, at: Date(timeIntervalSince1970: 400)))

        #expect(store.progress(forUniqueId: book.uniqueId)?.currentTime == 120)
        #expect(fixture.library.books[0].currentTime == 120)
        fixture.cleanUp()
    }

    @Test func updateIgnoresProgressOlderThanTheInMemoryBook() throws {
        let fixture = try ProgressFixture()
        let book = makeBook(id: "one", lastUpdate: Date(timeIntervalSince1970: 900))
        fixture.library.books = [book]
        let store = fixture.makeStore()

        store.update(makeProgress(for: book, currentTime: 120, at: Date(timeIntervalSince1970: 500)))

        #expect(store.progress(forUniqueId: book.uniqueId) == nil)
        #expect(fixture.library.books[0].currentTime == 0)
        fixture.cleanUp()
    }

    @Test func authoritativeServerActivityAppliesToMirrorAndRepository() async throws {
        let fixture = try ProgressFixture()
        let book = makeBook(id: "one", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [book]
        await fixture.store.upsertBooks([book])
        let store = fixture.makeStore()
        let observedAt = Date(timeIntervalSince1970: 800)

        await store.applyAuthoritativeServerActivity([
            (
                progress: makeProgress(for: book, currentTime: 300, at: observedAt),
                book: book,
                hideFromContinue: true,
                epubLocator: "locator",
                serverReadStatus: "READ"
            )
        ])

        #expect(fixture.library.books[0].currentTime == 300)
        #expect(fixture.library.books[0].hideFromContinue)
        #expect(fixture.library.books[0].serverReadStatus == "READ")
        #expect(store.progress(forUniqueId: book.uniqueId)?.currentTime == 300)
        let persisted = await fixture.store.progress(forBookUniqueId: book.uniqueId)
        #expect(persisted?.currentTime == 300)
        fixture.cleanUp()
    }

    @Test func retainDropsEntriesForBooksNoLongerPresent() throws {
        let fixture = try ProgressFixture()
        let kept = makeBook(id: "kept", lastUpdate: Date(timeIntervalSince1970: 100))
        let dropped = makeBook(id: "dropped", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [kept, dropped]
        let store = fixture.makeStore()
        store.update(makeProgress(for: kept, currentTime: 10, at: Date(timeIntervalSince1970: 500)))
        store.update(makeProgress(for: dropped, currentTime: 20, at: Date(timeIntervalSince1970: 500)))

        store.retain(uniqueIds: [kept.uniqueId])

        #expect(store.progress(forUniqueId: kept.uniqueId)?.currentTime == 10)
        #expect(store.progress(forUniqueId: dropped.uniqueId) == nil)
        fixture.cleanUp()
    }

    @Test func transferMovesRescuedProgressOntoTheServerBook() throws {
        let fixture = try ProgressFixture()
        let rescued = makeBook(id: "rescued", lastUpdate: Date(timeIntervalSince1970: 100))
        let server = makeBook(id: "server", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [rescued, server]
        let store = fixture.makeStore()
        store.update(makeProgress(for: rescued, currentTime: 45, at: Date(timeIntervalSince1970: 500)))

        store.transferProgress(fromUniqueId: rescued.uniqueId, to: server)

        #expect(store.progress(forUniqueId: rescued.uniqueId) == nil)
        #expect(store.progress(forUniqueId: server.uniqueId)?.currentTime == 45)
        fixture.cleanUp()
    }

    @Test func immediatePersistWritesTheProgressFile() throws {
        let fixture = try ProgressFixture()
        let book = makeBook(id: "one", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [book]
        let store = fixture.makeStore()
        store.update(makeProgress(for: book, currentTime: 75, at: Date(timeIntervalSince1970: 500)))

        store.persist(immediate: true)

        let data = try Data(contentsOf: fixture.progressFileURL)
        let decoded = try JSONDecoder().decode([String: UserMediaProgress].self, from: data)
        #expect(decoded[book.uniqueId]?.currentTime == 75)
        fixture.cleanUp()
    }

    @Test func removeAllClearsPublishedEntries() throws {
        let fixture = try ProgressFixture()
        let book = makeBook(id: "one", lastUpdate: Date(timeIntervalSince1970: 100))
        fixture.library.books = [book]
        let store = fixture.makeStore()
        store.update(makeProgress(for: book, currentTime: 10, at: Date(timeIntervalSince1970: 500)))

        store.removeAll()

        #expect(store.entries.isEmpty)
        fixture.cleanUp()
    }
}

private let progressTestProviderId = UUID(uuidString: "9F1E5F1E-6C5B-4E3E-9C2A-9F52A0F6A777")!

private func makeBook(id: String, lastUpdate: Date) -> Book {
    Book(
        id: id,
        title: "Book \(id)",
        duration: 600,
        source: .audiobookshelf,
        mediaType: .audiobook,
        currentTime: 0,
        isFinished: false,
        lastUpdate: lastUpdate,
        providerId: progressTestProviderId,
        libraryId: "library"
    )
}

private func makeProgress(for book: Book, currentTime: TimeInterval, at date: Date) -> UserMediaProgress {
    UserMediaProgress(
        id: book.id,
        libraryItemId: book.id,
        providerId: book.providerId,
        episodeId: nil,
        currentTime: currentTime,
        progress: currentTime / 600,
        isFinished: false,
        duration: 600,
        lastUpdate: date,
        ebookProgress: nil
    )
}
