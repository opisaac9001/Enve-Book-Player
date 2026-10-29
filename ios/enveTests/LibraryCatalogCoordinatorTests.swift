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
    func includeNewLibraries(connectionId: UUID, fetchedIds: Set<String>, previouslySeenIds: Set<String>) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[index].includeNewLibraries(fetchedIds: fetchedIds, previouslySeenIds: previouslySeenIds)
        allProviders[connectionId]?.connection = connections[index]
    }
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
private class CatalogProviderStub: @MainActor LibraryProvider {
    var connection: ServerConnection
    var capabilities: ProviderCapabilities = [.collections]
    var libraries: [Library] = []
    var recentBooks: [Book] = []
    var libraryError: (any Error)?
    var bookError: (any Error)?
    var fullCatalogFetchCount = 0
    var libraryFetchCount = 0

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func validateConnection() async throws -> Bool { true }
    func fetchLibraries() async throws -> [Library] {
        libraryFetchCount += 1
        if let libraryError { throw libraryError }
        return libraries
    }
    func fetchBooks(libraryId: String) async throws -> [Book] {
        fullCatalogFetchCount += 1
        if let bookError { throw bookError }
        return recentBooks
    }
    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { recentBooks }
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
private final class CatalogIncrementalProviderStub: CatalogProviderStub, @MainActor IncrementalCatalogProvider {
    var pageError: (any Error)?
    var completeSnapshot = true

    func makeCatalogBatchSource(libraryId: String, resumeAfter: String?, expectedSnapshotIdentifier: String?) async throws -> LibraryCatalogBatchSource {
        if let bookError { throw bookError }
        if let pageError {
            return .paged(firstPage: LibraryCatalogPage(books: recentBooks, totalCount: 2, isLast: false),
                pageSize: 1, pageConcurrency: 1, resumeAfter: nil, expectedSnapshotIdentifier: nil,
                fetchPage: { _ in throw pageError })
        }
        return .snapshot(books: recentBooks, batchSize: 1, isComplete: completeSnapshot,
            resumeAfter: nil, expectedSnapshotIdentifier: nil)
    }
}

@MainActor
private final class RecentCatalogProviderStub: CatalogProviderStub, @MainActor RecentCatalogPagingProvider {
    var pages: [[Book]] = []
    var requestedPages: [Int] = []
    var failingPage: Int?
    var cancelledPage: Int?
    var incompletePage: Int?
    var onFetch: (() async -> Void)?
    var sourceBookIDs: [Int: Set<String>] = [:]

    func fetchRecentCatalogPage(libraryId: String, page: Int, size: Int) async throws -> LibraryCatalogPage {
        requestedPages.append(page)
        await onFetch?()
        if cancelledPage == page { throw CancellationError() }
        if failingPage == page { throw URLError(.cannotConnectToHost) }
        return LibraryCatalogPage(books: pages[page], totalCount: nil,
            isLast: page == pages.count - 1, isComplete: page != incompletePage, sourceBookIDs: sourceBookIDs[page])
    }
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
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
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
    @Test func jellyfinFailurePreservesCacheAndRetryAcceptsAValidEmptyCatalog() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let catalog = fixture.makeCoordinator()
        let provider = CatalogIncrementalProviderStub(connection: ServerConnection(
            name: "Jellyfin fixture", url: "https://fixture.example.invalid", type: .jellyfin))
        let id = provider.connection.id
        let lib = Library(id: "library", name: "Books", type: "book", providerId: id)
        provider.libraries = [lib]
        fixture.connections.connections = [provider.connection]
        fixture.connections.allProviders = [id: provider]
        catalog.libraries = [lib]
        let cached = Book(id: "cached", title: "Saved", source: .jellyfin, mediaType: .audiobook,
            providerId: id, libraryId: lib.id)
        fixture.library.books = [cached]
        await fixture.store.upsertBooks([cached])

        provider.bookError = JellyfinResponseError(statusCode: 400)
        await catalog.refreshConnectionLibraries(providerId: id, forceFullReconciliation: true, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .connection(id))?.statusCode == 400)
        #expect(fixture.library.books.contains { $0.uniqueId == cached.uniqueId })
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)

        provider.bookError = nil
        await catalog.refreshConnectionLibraries(providerId: id, forceFullReconciliation: true, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .connection(id)) == nil)
        #expect(!fixture.library.books.contains { $0.uniqueId == cached.uniqueId })
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) == nil)

        provider.recentBooks = [cached]
        await catalog.refreshConnectionLibraries(providerId: id, forceFullReconciliation: true, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .connection(id)) == nil)
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)

        provider.libraryError = JellyfinResponseError(statusCode: 400)
        await catalog.refreshConnectionLibraries(providerId: id, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .all)?.statusCode == 400)
        #expect(catalog.libraries.contains { $0.id == lib.id })
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)
        provider.libraryError = nil
        provider.libraries = []
        await catalog.refreshConnectionLibraries(providerId: id, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .all) == nil)
        #expect(catalog.libraries.isEmpty)
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) == nil)
    }

    @Test func jellyfinPartialCatalogFailurePreservesUnseenCachedBooksAndRecovers() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let catalog = fixture.makeCoordinator()
        let provider = CatalogIncrementalProviderStub(connection: ServerConnection(
            name: "Jellyfin fixture", url: "https://fixture.example.invalid", type: .jellyfin))
        let id = provider.connection.id
        let lib = Library(id: "library", name: "Books", type: "book", providerId: id)
        provider.libraries = [lib]
        fixture.connections.connections = [provider.connection]
        fixture.connections.allProviders = [id: provider]
        catalog.libraries = [lib]
        let cached = Book(id: "cached", title: "Saved", source: .jellyfin, mediaType: .audiobook,
            providerId: id, libraryId: lib.id)
        let added = Book(id: "added", title: "New", source: .jellyfin, mediaType: .audiobook,
            providerId: id, libraryId: lib.id)
        fixture.library.books = [cached]
        await fixture.store.upsertBooks([cached])
        provider.recentBooks = [added]
        provider.pageError = JellyfinResponseError(statusCode: 400)
        await catalog.refreshConnectionLibraries(providerId: id, forceFullReconciliation: true, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .all)?.statusCode == 400)
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)
        #expect(await fixture.store.book(uniqueId: added.uniqueId) != nil)

        provider.pageError = nil
        provider.completeSnapshot = false
        await catalog.refreshConnectionLibraries(providerId: id, forceFullReconciliation: true, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .all) != nil)
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)

        provider.completeSnapshot = true
        provider.recentBooks = [cached, added]
        await catalog.refreshConnectionLibraries(providerId: id, forceFullReconciliation: true, refreshCollections: false)
        #expect(catalog.refreshFailure(for: .all) == nil)
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)
        #expect(await fixture.store.book(uniqueId: added.uniqueId) != nil)
    }

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

    @Test func refreshDropsLibrariesTheServerNoLongerLists() async throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        let provider = CatalogProviderStub(connection: makeConnection())
        let providerId = provider.connection.id
        let kept = Library(id: "kept", name: "Kept", type: "book", providerId: providerId)
        let removed = Library(id: "removed", name: "Removed", type: "book", providerId: providerId)
        provider.libraries = [kept]
        fixture.connections.connections = [provider.connection]
        fixture.connections.allProviders = [providerId: provider]
        catalog.libraries = [kept, removed]
        let orphan = Book(
            id: "orphan",
            title: "Orphan",
            source: .audiobookshelf,
            mediaType: .audiobook,
            providerId: providerId,
            libraryId: removed.id
        )
        fixture.library.books = [orphan]
        await fixture.store.upsertBooks([orphan])

        await catalog.refreshConnectionLibraries(providerId: providerId, refreshCollections: false)

        #expect(catalog.libraries.map(\.id) == [kept.id])
        #expect(!fixture.library.books.contains { $0.libraryId == removed.id })
        #expect(await fixture.store.book(uniqueId: orphan.uniqueId) == nil)
        fixture.cleanUp()
    }

    @Test func recentRefreshMergesDuplicateCachedRowsWithoutLosingOtherSources() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let catalog = fixture.makeCoordinator()
        let connection = ServerConnection(name: "Fixture", url: "https://bookorbit.example.invalid",
            type: .bookOrbit, isConnected: true)
        let provider = CatalogProviderStub(connection: connection)
        provider.libraries = [Library(id: "library", name: "Books", type: "book", providerId: connection.id)]
        var stale = makeBook(id: "existing", source: .bookOrbit)
        stale.providerId = connection.id
        var refreshed = stale
        refreshed.title = "Updated title"
        let added = Book(id: "added", title: "New book", source: .bookOrbit,
            mediaType: .audiobook, providerId: connection.id, libraryId: "library")
        let other = makeBook(id: "other", source: .audiobookshelf)
        provider.recentBooks = [refreshed, refreshed, added]
        fixture.connections.connections = [connection]
        fixture.connections.allProviders = [connection.id: provider]
        catalog.libraries = provider.libraries
        fixture.library.load([stale, stale, other])
        await fixture.store.upsertBooks([stale, other])

        await catalog.refreshStaleServerMirrorDomains()

        #expect(fixture.library.books.filter { $0.uniqueId == refreshed.uniqueId }.count == 1)
        #expect(fixture.library.books.first { $0.uniqueId == refreshed.uniqueId }?.title == "Updated title")
        #expect(fixture.library.books.contains { $0.uniqueId == added.uniqueId })
        #expect(fixture.library.books.contains { $0.uniqueId == other.uniqueId })
        #expect(await fixture.store.book(uniqueId: refreshed.uniqueId)?.title == "Updated title")
        await catalog.retire()
    }

    @Test func refreshIncludesALibraryAddedAfterTheSelection() async throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()
        var connection = makeConnection()
        connection.selectedLibraryIds = ["first"]
        connection.knownLibraryIds = ["first", "excluded"]
        let provider = CatalogProviderStub(connection: connection)
        let providerId = connection.id
        provider.libraries = ["first", "excluded", "added"].map {
            Library(id: $0, name: $0, type: "book", providerId: providerId)
        }
        fixture.connections.connections = [connection]
        fixture.connections.allProviders = [providerId: provider]

        await catalog.refreshConnectionLibraries(providerId: providerId, refreshCollections: false)

        #expect(fixture.connections.connections.first?.selectedLibraryIds == ["first", "added"])
        #expect(fixture.connections.connections.first?.knownLibraryIds == ["first", "excluded", "added"])
        #expect(provider.connection.selectedLibraryIds == ["first", "added"])
        fixture.cleanUp()
    }

    private func recentFixture(_ fixture: CatalogFixture) async -> (LibraryCatalogCoordinator, RecentCatalogProviderStub, Book) {
        let catalog = fixture.makeCoordinator()
        let connection = ServerConnection(name: "Grimmory", url: "https://fixture.example.invalid",
            type: .booklore, isConnected: true)
        let provider = RecentCatalogProviderStub(connection: connection)
        provider.libraries = [Library(id: "library", name: "Books", type: "book", providerId: connection.id)]
        fixture.connections.connections = [connection]
        fixture.connections.allProviders = [connection.id: provider]
        catalog.libraries = provider.libraries
        let cached = Book(id: "known", title: "Cached", source: .booklore, mediaType: .ebook,
            providerId: connection.id, libraryId: "library")
        fixture.library.books = [cached]
        await fixture.store.upsertBooks([cached])
        return (catalog, provider, cached)
    }

    @Test func hearthFindsMultiplePagesOfAdditionsWithoutFullCatalogOrDeletion() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        let additions = (0..<130).map { index in
            Book(id: "new-\(index)", title: "New \(index)", source: .booklore, mediaType: .ebook,
                providerId: provider.connection.id, libraryId: "library")
        }
        provider.pages = [Array(additions[0..<50]), Array(additions[50..<100]), Array(additions[100..<130]) + [cached], [cached], [cached]]
        let unreturned = Book(id: "not-in-recent-window", title: "Older", source: .booklore,
            mediaType: .ebook, providerId: provider.connection.id, libraryId: "library")
        await fixture.store.upsertBooks([unreturned])

        await catalog.refreshRecentCatalog(force: true)

        #expect(provider.requestedPages == [0, 1, 2, 3])
        #expect(provider.fullCatalogFetchCount == 0)
        #expect(await fixture.store.bookCount(libraryId: "library", providerId: provider.connection.id) == 132)
        #expect(catalog.recentCatalogFailures.isEmpty)
        await catalog.retire()
    }

    @Test func recentCatalogFreshnessDoesNotThrottleManualRefresh() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        provider.pages = [[cached]]
        await catalog.refreshRecentCatalog()
        await catalog.refreshRecentCatalog()
        #expect(provider.requestedPages == [0])
        #expect(provider.libraryFetchCount == 1)
        await catalog.refreshRecentCatalog(force: true)
        #expect(provider.requestedPages == [0, 0])
        let checkpoints = ServerMirrorCheckpointStore(defaults: fixture.defaults)
        let scope = ServerMirrorScope(connectionId: provider.connection.id,
            accountKey: ServerMirrorFingerprint.accountKey(for: provider.connection),
            libraryId: "library", domain: .catalog)
        #expect(checkpoints.checkpoint(for: scope) == nil)
        #expect(provider.fullCatalogFetchCount == 0)
        await catalog.retire()
    }

    @Test func failedLaterAdditionsPagePreservesCacheAndRetryStillFindsAllAdditions() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        let added = Book(id: "new", title: "New", source: .booklore, mediaType: .ebook,
            providerId: provider.connection.id, libraryId: "library")
        provider.pages = [[added], [cached]]
        provider.failingPage = 1
        await catalog.refreshRecentCatalog(force: true)
        #expect(catalog.recentCatalogFailures == [provider.connection.id])
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)
        #expect(await fixture.store.book(uniqueId: added.uniqueId) == nil)
        provider.failingPage = nil
        await catalog.refreshRecentCatalog()
        #expect(provider.requestedPages == [0, 1, 0, 1])
        #expect(await fixture.store.book(uniqueId: added.uniqueId) != nil)
        #expect(catalog.recentCatalogFailures.isEmpty)
        #expect(provider.fullCatalogFetchCount == 0)
        await catalog.retire()
    }

    @Test func overlappingHearthRefreshesShareTheRunningProviderCheck() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        provider.pages = [[cached]]
        provider.onFetch = { try? await Task.sleep(for: .milliseconds(100)) }
        async let first: Void = catalog.refreshRecentCatalog(force: true)
        async let second: Void = catalog.refreshRecentCatalog(force: true)
        _ = await (first, second)
        #expect(provider.requestedPages == [0])
        await catalog.retire()
    }

    @Test func missingDerivedCompanionsDoNotTriggerPagingThroughAnIndexedCatalog() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        let companion = Book(id: "companion", title: "Audio", source: .booklore,
            mediaType: .audiobook, providerId: provider.connection.id, libraryId: "library")
        provider.pages = [[cached, companion], [cached]]
        provider.sourceBookIDs[0] = [cached.uniqueId]
        await catalog.refreshRecentCatalog(force: true)
        #expect(provider.requestedPages == [0])
        #expect(await fixture.store.book(uniqueId: companion.uniqueId) != nil)
        await catalog.retire()
    }

    @Test func cancelledRecentCheckKeepsCacheAndRemainsEligibleForRetry() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        provider.pages = [[cached]]
        provider.cancelledPage = 0
        await catalog.refreshRecentCatalog()
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)
        #expect(catalog.recentCatalogFailures.isEmpty)
        provider.cancelledPage = nil
        await catalog.refreshRecentCatalog()
        #expect(provider.requestedPages == [0, 0])
        await catalog.retire()
    }

    @Test func knownAudiobookMetadataIsNotReplacedByAnAdditionsSummary() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        var audiobook = cached
        audiobook.mediaType = .audiobook
        audiobook.duration = 3600
        fixture.library.books = [audiobook]
        await fixture.store.upsertBooks([audiobook])
        var summary = audiobook
        summary.duration = nil
        provider.pages = [[summary]]
        await catalog.refreshRecentCatalog(force: true)
        #expect(await fixture.store.book(uniqueId: cached.uniqueId)?.duration == 3600)
        #expect(fixture.library.books.first?.duration == 3600)
        await catalog.retire()
    }

    @Test func incompleteAdditionsPageDoesNotAdvanceFreshnessOrRemoveCachedBooks() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let (catalog, provider, cached) = await recentFixture(fixture)
        provider.pages = [[cached]]
        provider.incompletePage = 0
        await catalog.refreshRecentCatalog()
        #expect(catalog.recentCatalogFailures == [provider.connection.id])
        #expect(await fixture.store.book(uniqueId: cached.uniqueId) != nil)
        provider.incompletePage = nil
        await catalog.refreshRecentCatalog()
        #expect(provider.requestedPages == [0, 0])
        #expect(catalog.recentCatalogFailures.isEmpty)
        await catalog.retire()
    }

    /// An OPDS feed can offer a direct audio acquisition, and the provider has already classified it.
    @Test func anOPDSAudiobookIsNotCoercedIntoAnEbook() throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()

        let normalized = catalog.normalizeCachedBookMediaType(
            makeOPDSBook(mediaType: .audiobook, partKey: "https://catalog.example.invalid/opds/narrated.m4b")
        )

        #expect(normalized.mediaType == .audiobook)
        fixture.cleanUp()
    }

    @Test func anOPDSEbookIsStillForcedToTheEbookMediaType() throws {
        let fixture = try CatalogFixture()
        let catalog = fixture.makeCoordinator()

        let normalized = catalog.normalizeCachedBookMediaType(
            makeOPDSBook(mediaType: .audiobook, partKey: "https://catalog.example.invalid/opds/book.epub")
        )

        #expect(normalized.mediaType == .ebook)
        #expect(normalized.currentTime == 0)
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

private func makeOPDSBook(mediaType: AppMediaType, partKey: String) -> Book {
    Book(
        id: "urn:opds:1",
        title: "Narrated",
        duration: 3600,
        partKey: partKey,
        mediaType: mediaType,
        libraryId: "opds-root",
        providerId: UUID(uuidString: "1B1F5F1E-6C5B-4E3E-9C2A-9F52A0F6A124")!,
        source: .opds
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
