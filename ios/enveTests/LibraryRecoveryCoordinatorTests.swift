import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
private final class RecoverySessionStub: CurrentBookSession {
    var currentBook: Book?
}

@MainActor
private final class RecoveryStartupStub: LibraryStartupGating {
    var isStartupCacheLoaded = true
}

@MainActor
private final class RecoveryConnectionStub: ProviderConnectionEditing, ProviderConnectionResolving, ProviderConnectionAccessing {
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
private final class RecoveryNoopWriter: BookWriting {
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

/// Captures the global-cache purges the coordinator delegates instead of performing them.
@MainActor
private final class RecoveryPurgeRecorder {
    private(set) var purgedBookIds: [String] = []
    private(set) var purgedDiskIds: [String] = []
    private(set) var alignmentCleanups = 0

    func recordBook(_ book: Book) { purgedBookIds.append(book.uniqueId) }
    func recordDisk(_ diskId: String) { purgedDiskIds.append(diskId) }
    func recordAlignmentCleanup() { alignmentCleanups += 1 }
}

@MainActor
private final class RecoveryFixture {
    let library = LibraryBookCache(writer: RecoveryNoopWriter())
    let session = RecoverySessionStub()
    let presentation = AppPresentationState()
    let startup = RecoveryStartupStub()
    let connections = RecoveryConnectionStub()
    let purges = RecoveryPurgeRecorder()
    let store: SwiftDataBookStore
    let catalog: LibraryCatalogCoordinator
    let progress: UserProgressStore

    private let defaultsSuiteName: String
    let defaults: UserDefaults
    private let metadataFileURL: URL
    private let progressFileURL: URL

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
            "LibraryRecoveryCoordinatorTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        store = SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
        defaultsSuiteName = "LibraryRecoveryCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        metadataFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRecoveryCoordinatorTests-meta-\(UUID().uuidString).json")
        progressFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRecoveryCoordinatorTests-progress-\(UUID().uuidString).json")

        progress = UserProgressStore(
            library: library,
            session: session,
            bookStore: store,
            providerConnections: connections,
            progressFileURL: progressFileURL,
            progressCache: BookProgressStore(defaults: defaults),
            defaults: defaults
        )
        catalog = LibraryCatalogCoordinator(
            library: library,
            session: session,
            presentation: presentation,
            bookStore: store,
            providerConnections: connections,
            progress: progress,
            mirrorCheckpoints: ServerMirrorCheckpointStore(defaults: defaults),
            metadataFileURL: metadataFileURL
        )
    }

    func makeCoordinator() -> LibraryRecoveryCoordinator {
        let recorder = purges
        return LibraryRecoveryCoordinator(
            library: library,
            session: session,
            presentation: presentation,
            startup: startup,
            catalog: catalog,
            progress: progress,
            bookStore: store,
            providerConnections: connections,
            stores: LibraryRecoveryStores(
                mirrorCheckpoints: ServerMirrorCheckpointStore(defaults: defaults),
                userCollections: UserCollectionStore(defaults: defaults),
                smartCollections: SmartCollectionStore(defaults: defaults),
                pendingSync: PendingSyncQueueStore(defaults: defaults),
                purgeCachedArtifacts: { recorder.recordBook($0) },
                purgeDownloadArtifacts: { recorder.recordDisk($0) },
                cleanupAlignmentCaches: { _ in recorder.recordAlignmentCleanup() }
            ),
            defaults: defaults
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: metadataFileURL)
        try? FileManager.default.removeItem(at: progressFileURL)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}

@MainActor
struct LibraryRecoveryCoordinatorTests {
    @Test func removingBooksClearsMirrorSessionAndCollectionMembership() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let removed = makeBook(id: "removed")
        let kept = makeBook(id: "kept")
        fixture.library.load([removed, kept])
        fixture.session.currentBook = removed
        fixture.catalog.collections = [
            makeCollection(id: "collection", books: [removed.id, kept.id], providerId: removed.providerId)
        ]

        recovery.removeBooks([removed])

        #expect(fixture.library.books.map(\.id) == ["kept"])
        #expect(fixture.library.hot.book(uniqueId: removed.uniqueId) == nil)
        #expect(fixture.session.currentBook == nil)
        #expect(fixture.catalog.collections[0].books == [kept.id])
        #expect(fixture.purges.purgedBookIds == [removed.uniqueId])
        #expect(fixture.purges.alignmentCleanups == 1)
        fixture.cleanUp()
    }

    @Test func removingAnUnselectedBookLeavesTheSessionSelection() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let removed = makeBook(id: "removed")
        let selected = makeBook(id: "selected")
        fixture.library.load([removed, selected])
        fixture.session.currentBook = selected

        recovery.removeBooks([removed])

        #expect(fixture.session.currentBook?.id == "selected")
        fixture.cleanUp()
    }

    @Test func dismissingAnOrphanRemovesItFromThePresentedList() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let orphan = makeBook(id: "orphan", libraryId: "rescued-downloads")
        fixture.presentation.orphanedBooks = [orphan]

        recovery.dismissOrphanedBook(orphan)

        #expect(fixture.presentation.orphanedBooks.isEmpty)
        #expect(
            fixture.defaults.stringArray(forKey: LibraryRecoveryCoordinator.acknowledgedRescuedDownloadsKey)
                == [orphan.downloadKey]
        )
        fixture.cleanUp()
    }

    @Test func deletingAnOrphanDropsItAndRetiresTheEmptyRescueLibrary() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let orphan = makeBook(id: "orphan", libraryId: "rescued-downloads")
        fixture.library.load([orphan])
        fixture.presentation.orphanedBooks = [orphan]
        fixture.catalog.libraries = [
            Library(id: "rescued-downloads", name: "Rescued Downloads", type: "local", providerId: orphan.providerId)
        ]

        recovery.deleteOrphanedBook(orphan)

        #expect(fixture.library.books.isEmpty)
        #expect(fixture.library.hot.book(uniqueId: orphan.uniqueId) == nil)
        #expect(fixture.presentation.orphanedBooks.isEmpty)
        #expect(fixture.catalog.libraries.isEmpty)
        #expect(fixture.purges.purgedDiskIds == [orphan.downloadKey])
        fixture.cleanUp()
    }

    @Test func earlyPruneDropsBooksFromUnknownProvidersAndQueuesDeletion() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let active = ServerConnection(name: "Active", url: "http://example.invalid", type: .audiobookshelf)
        fixture.connections.connections = [active]
        let kept = makeBook(id: "kept", providerId: active.id)
        let orphaned = makeBook(id: "orphaned", providerId: UUID())
        let localBook = makeBook(id: "local", providerId: UUID(), source: .local)
        fixture.library.load([kept, orphaned, localBook])

        recovery.pruneStaleBooksCacheEarly()

        #expect(fixture.library.books.map(\.id).sorted() == ["kept", "local"])
        #expect(recovery.pendingBookStoreDeletions == [orphaned.uniqueId])
        fixture.cleanUp()
    }

    @Test func earlyPruneHonoursTheSelectedLibraryAllowList() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        var active = ServerConnection(name: "Active", url: "http://example.invalid", type: .audiobookshelf)
        active.selectedLibraryIds = ["allowed"]
        fixture.connections.connections = [active]
        let kept = makeBook(id: "kept", providerId: active.id, libraryId: "allowed")
        let dropped = makeBook(id: "dropped", providerId: active.id, libraryId: "disabled")
        fixture.library.load([kept, dropped])

        recovery.pruneStaleBooksCacheEarly()

        #expect(fixture.library.books.map(\.id) == ["kept"])
        fixture.cleanUp()
    }

    @Test func pruneIsSkippedUntilTheStartupCacheHasLoaded() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        fixture.startup.isStartupCacheLoaded = false
        let orphaned = makeBook(id: "orphaned", providerId: UUID())
        fixture.library.load([orphaned])

        recovery.pruneDisconnectedProviderData()

        #expect(fixture.library.books.map(\.id) == ["orphaned"])
        fixture.cleanUp()
    }

    @Test func pruneDropsDisconnectedProviderLibrariesAndCollections() throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let staleProviderId = UUID()
        let orphaned = makeBook(id: "orphaned", providerId: staleProviderId)
        fixture.library.load([orphaned])
        fixture.catalog.libraries = [Library(id: "lib", name: "Library", type: "book", providerId: staleProviderId)]
        fixture.catalog.collections = [makeCollection(id: "collection", books: [], providerId: staleProviderId)]

        recovery.pruneDisconnectedProviderData()

        #expect(fixture.library.books.isEmpty)
        #expect(fixture.catalog.libraries.isEmpty)
        #expect(fixture.catalog.collections.isEmpty)
        #expect(recovery.pendingBookStoreDeletions == [orphaned.uniqueId])
        fixture.cleanUp()
    }

    @Test func resettingBookDataClearsTheMirrorAndCatalog() async throws {
        let fixture = try RecoveryFixture()
        let recovery = fixture.makeCoordinator()
        let book = makeBook(id: "one")
        fixture.library.load([book])
        fixture.session.currentBook = book
        fixture.catalog.libraries = [Library(id: "lib", name: "Library", type: "book", providerId: book.providerId)]
        fixture.catalog.collections = [makeCollection(id: "collection", books: [], providerId: book.providerId)]

        await recovery.resetBookDataState()

        #expect(fixture.library.books.isEmpty)
        #expect(fixture.catalog.libraries.isEmpty)
        #expect(fixture.catalog.collections.isEmpty)
        #expect(fixture.session.currentBook == nil)
        #expect(fixture.progress.entries.isEmpty)
        fixture.cleanUp()
    }
}

private func makeBook(
    id: String,
    providerId: UUID = UUID(uuidString: "2C1F5F1E-6C5B-4E3E-9C2A-9F52A0F6A222")!,
    libraryId: String = "library",
    source: Book.BookSource = .audiobookshelf
) -> Book {
    Book(
        id: id,
        title: "Book \(id)",
        source: source,
        mediaType: .audiobook,
        providerId: providerId,
        libraryId: libraryId
    )
}

private func makeCollection(id: String, books: [String], providerId: UUID) -> Collection {
    Collection(
        id: id,
        name: "Collection \(id)",
        description: nil,
        books: books,
        bookCount: books.count,
        iconName: "books.vertical",
        color: "blue",
        providerId: providerId
    )
}
