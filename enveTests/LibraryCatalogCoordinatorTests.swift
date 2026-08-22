import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
private final class CatalogSessionStub: CurrentBookSession {
    var currentBook: Book?
}

@MainActor
private final class CatalogConnectionStub: ProviderConnectionResolving, ProviderConnectionAccessing {
    var connections: [ServerConnection] = []
    var connectionsNeedingReauth: [ServerConnection] = []
    var allProviders: [UUID: LibraryProvider] = [:]
    var providerCount: Int { allProviders.count }

    subscript(providerId: UUID) -> LibraryProvider? { allProviders[providerId] }

    func markNeedsReauthentication(providerId: UUID, error: Error) {}
    func clearReauthentication(connectionId: UUID) {}
    func backend(id: String) -> BackendConfig? { nil }
    func allBackends() -> [BackendConfig] { [] }
    func provider(for providerId: UUID) -> LibraryProvider? { allProviders[providerId] }
    func provider(for book: Book) -> LibraryProvider? { allProviders[book.providerId] }
}

@MainActor
private final class CatalogNoopWriter: BookWriting {
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
private final class CatalogProviderStub: @MainActor LibraryProvider {
    var connection: ServerConnection
    var capabilities: ProviderCapabilities = [.collections]

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func validateConnection() async throws -> Bool { true }
    func fetchLibraries() async throws -> [Library] { [] }
    func fetchBooks(libraryId: String) async throws -> [Book] { [] }
    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
    func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        throw ProviderError.notImplemented
    }
    func getAudioURL(for book: Book) -> URL? { nil }
    func getStreamingHeaders() -> [String: String] { [:] }
    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        throw ProviderError.notImplemented
    }
    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {}
}

@MainActor
private struct CatalogFixture {
    let library = LibraryBookCache(writer: CatalogNoopWriter())
    let session = CatalogSessionStub()
    let presentation = AppPresentationState()
    let connections = CatalogConnectionStub()
    let store: SwiftDataBookStore
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let metadataFileURL: URL
    let progressFileURL: URL

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
            "LibraryCatalogCoordinatorTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        store = SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
        defaultsSuiteName = "LibraryCatalogCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        metadataFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCatalogCoordinatorTests-meta-\(UUID().uuidString).json")
        progressFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCatalogCoordinatorTests-progress-\(UUID().uuidString).json")
    }

    func makeCoordinator() -> LibraryCatalogCoordinator {
        LibraryCatalogCoordinator(
            library: library,
            session: session,
            presentation: presentation,
            bookStore: store,
            providerConnections: connections,
            progress: UserProgressStore(
                library: library,
                session: session,
                bookStore: store,
                providerConnections: connections,
                progressFileURL: progressFileURL,
                progressCache: BookProgressStore(defaults: defaults),
                defaults: defaults
            ),
            mirrorCheckpoints: ServerMirrorCheckpointStore(defaults: defaults),
            metadataFileURL: metadataFileURL
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: metadataFileURL)
        try? FileManager.default.removeItem(at: progressFileURL)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}

@MainActor
struct LibraryCatalogCoordinatorTests {
    @Test func commitReplacesTheProviderSliceAndReportsAChange() throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        let provider = CatalogProviderStub(connection: makeConnection())
        let otherProviderId = UUID()
        catalog.collections = [
            makeCollection(id: "stale", providerId: provider.connection.id),
            makeCollection(id: "other", providerId: otherProviderId),
        ]

        let changed = catalog.commitServerCollectionSnapshot(
            [makeCollection(id: "fresh", providerId: provider.connection.id)],
            from: provider
        )

        #expect(changed)
        #expect(catalog.collections.contains { $0.id == "fresh" })
        #expect(!catalog.collections.contains { $0.id == "stale" })
        #expect(catalog.collections.contains { $0.providerId == otherProviderId })
        fixture.cleanUp()
    }

    @Test func commitOfAnIdenticalSnapshotReportsNoChange() throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        let provider = CatalogProviderStub(connection: makeConnection())
        let snapshot = [makeCollection(id: "one", providerId: provider.connection.id)]

        #expect(catalog.commitServerCollectionSnapshot(snapshot, from: provider))
        #expect(!catalog.commitServerCollectionSnapshot(snapshot, from: provider))
        #expect(catalog.collections.count == 1)
        fixture.cleanUp()
    }

    @Test func commitDeduplicatesRepeatedCollectionIdentifiers() throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        let provider = CatalogProviderStub(connection: makeConnection())

        catalog.commitServerCollectionSnapshot(
            [
                makeCollection(id: "one", providerId: provider.connection.id),
                makeCollection(id: "one", providerId: provider.connection.id),
            ],
            from: provider
        )

        #expect(catalog.collections.count == 1)
        fixture.cleanUp()
    }

    @Test func metadataSnapshotRoundTripsLibrariesCollectionsAndSeries() async throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        let providerId = UUID()
        catalog.libraries = [Library(id: "lib", name: "Library", type: "book", providerId: providerId)]
        catalog.collections = [makeCollection(id: "one", providerId: providerId)]
        catalog.series = [
            Series(
                id: "series",
                name: "Series",
                description: nil,
                books: ["a"],
                bookSequences: [:],
                bookCount: 1,
                libraryId: "lib",
                providerId: providerId
            )
        ]

        catalog.saveMetadata(immediate: true)

        let reloaded = fixture.makeCoordinator()
        #expect(await reloaded.loadCachedMetadata())
        #expect(reloaded.libraries.map(\.id) == ["lib"])
        #expect(reloaded.collections.map(\.id) == ["one"])
        #expect(reloaded.series.map(\.id) == ["series"])
        fixture.cleanUp()
    }

    @Test func flushingLocalBooksPersistsOnlyLocalSources() async throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        let local = makeBook(id: "local", source: .local)
        let remote = makeBook(id: "remote", source: .audiobookshelf)
        fixture.library.books = [local, remote]

        await catalog.flushLocalBooksToCache()?.value

        #expect(await fixture.store.book(uniqueId: local.uniqueId) != nil)
        #expect(await fixture.store.book(uniqueId: remote.uniqueId) == nil)
        fixture.cleanUp()
    }
}

private func makeConnection() -> ServerConnection {
    ServerConnection(name: "Test", url: "http://example.invalid", type: .audiobookshelf)
}

private func makeCollection(id: String, providerId: UUID) -> Collection {
    Collection(
        id: id,
        name: "Collection \(id)",
        description: nil,
        books: [],
        bookCount: 0,
        iconName: "books.vertical",
        color: "blue",
        providerId: providerId
    )
}

private func makeBook(id: String, source: Book.BookSource) -> Book {
    Book(
        id: id,
        title: "Book \(id)",
        source: source,
        mediaType: .audiobook,
        providerId: UUID(uuidString: "1B1F5F1E-6C5B-4E3E-9C2A-9F52A0F6A123")!,
        libraryId: "library"
    )
}
