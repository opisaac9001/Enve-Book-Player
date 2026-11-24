import Combine
import Foundation
import Logging

enum AudiobookSeparationError: LocalizedError {
    case unsupported
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This chapter is not backed by a separate local audio file."
        case .sourceUnavailable:
            return "The audiobook source is no longer available."
        }
    }
}

struct BookDetailSnapshot: Sendable {
    let book: Book
    let counterpart: Book?
    let inSeries: [Book]
    let workSummary: LibraryWorkSummary?
}

struct LibraryWorkSummary: Sendable {
    let key: String
    let editions: Int
    let sources: Int
}

struct HearthFeedSnapshot: Sendable {
    let listening: [Book]
    let reading: [Book]
    let fresh: [Book]
    let downloaded: [Book]
}

struct LibraryWorkIndexSnapshot: Sendable {
    let hiddenUniqueIds: Set<String>
    let representativeWorkKey: [String: String]
    let representativeCount: [String: Int]
}

enum CatalogLane: Hashable, Sendable {
    case stored
    case remote(providerId: UUID, libraryId: String)
    case grimmorySearch(providerId: UUID)

    var providerId: UUID? {
        switch self {
        case .stored: nil
        case .remote(let providerId, _), .grimmorySearch(let providerId): providerId
        }
    }

    fileprivate var order: String {
        switch self {
        case .stored: "0"
        case .remote(let providerId, let libraryId): "1|\(providerId.uuidString)|\(libraryId)"
        case .grimmorySearch(let providerId): "2|\(providerId.uuidString)"
        }
    }
}

enum CatalogLanePosition: Hashable, Sendable {
    case start
    case offset(Int)
    case token(String)
}

struct RemoteCatalogCursor: Hashable, Sendable {
    fileprivate(set) var lanes: [CatalogLane: CatalogLanePosition] = [:]
    fileprivate(set) var seenTokens: [CatalogLane: Set<String>] = [:]
    fileprivate(set) var offlineProviders: Set<UUID> = []
}

struct CatalogEntry: Sendable {
    let book: Book
    let isSummary: Bool
}

struct CatalogLaneIssue: Equatable, Sendable {
    let providerId: UUID
    let sourceName: String
    /// Nil when the server was unreachable and its downloaded books were shown instead.
    let message: String?
}

private extension RemoteCatalogSort {
    var libraryDescriptor: LibrarySortDescriptor {
        switch self {
        case .title: LibrarySortDescriptor(field: .title, direction: .ascending)
        case .recentlyAdded: LibrarySortDescriptor(field: .recent, direction: .descending)
        }
    }

    var storeDescriptor: BookStoreSortDescriptor {
        switch self {
        case .title: BookStoreSortDescriptor(field: .title, direction: .ascending)
        case .recentlyAdded: BookStoreSortDescriptor(field: .recent, direction: .descending)
        }
    }
}

struct RemoteCatalogResult {
    let entries: [CatalogEntry]
    let books: [Book]
    let next: RemoteCatalogCursor?
    let issues: [CatalogLaneIssue]
    let reachedSource: Bool
}

struct RemoteCatalogScope: Equatable {
    fileprivate struct Source: Equatable {
        let id: UUID
        let url: String
        let username: String?
        let userId: String?
        let selectedLibraryIds: Set<String>?
    }

    fileprivate let sources: [Source]
    fileprivate let libraryKeys: Set<String>
    fileprivate let excludedLibraryKeys: Set<String>
}

struct BookSyncLibrarySnapshot: Sendable {
    let ebookCount: Int
    let ebooks: [Book]
}

struct RecentlyDeletedBookEntry: Identifiable, Sendable {
    let stableId: String
    let title: String
    let deletedAt: Date

    var id: String { stableId }
}

struct LibraryCollectionsOverview {
    let smart: [SmartCollection]
    let mine: [Collection]
    let server: [Collection]
    let smartPreviews: [String: (count: Int, book: Book?)]
    let memberPreviews: [String: Book]
}

struct CollectionEditorValues {
    let name: String
    let details: String
    let iconName: String
    let color: String
    let selectedImageData: Data?
    let rules: [SmartCollectionRule]
    let logicOperator: LogicOperator
}

struct BookOrbitCollectionMembership: Identifiable {
    let collection: Collection
    var containsBook: Bool

    var id: String { collection.id }
}

@MainActor
@Observable
final class LibraryEngine {
    private let appState: AppState
    private let catalog: LibraryCatalogCoordinator
    private let progressStore: UserProgressStore
    private let recovery: LibraryRecoveryCoordinator

    private unowned let profileSession: ProfileSession?

    init(profileSession: ProfileSession? = nil,
        appState: AppState = .shared,
        catalog: LibraryCatalogCoordinator = .shared,
        progressStore: UserProgressStore = .shared,
        recovery: LibraryRecoveryCoordinator = .shared
    ) {
        self.profileSession = profileSession
        self.appState = appState
        self.catalog = catalog
        self.progressStore = progressStore
        self.recovery = recovery
    }

    var isRefreshing: Bool {
        catalog.isRefreshing
    }

    func refreshFailure(for source: LibrarySourceFilter) -> LibraryRefreshFailure? {
        catalog.refreshFailure(for: source)
    }

    func refreshLibrary() async {
        let signpost = PerfSignpost.begin("library-refresh")
        defer { PerfSignpost.end(signpost) }
        await catalog.refreshLibrary()
    }

    func detailSnapshot(for seed: Book, current: Book?) async -> BookDetailSnapshot {
        let shown = current ?? seed
        var fresh =
            await appState.bookStore.book(uniqueId: seed.uniqueId)
            ?? appState.bookInMemory(uniqueId: seed.uniqueId)
            ?? shown
        fresh.language = fresh.language ?? shown.language ?? seed.language

        let counterpart: Book?
        switch fresh.mediaType {
        case .ebook:
            counterpart = await (profileSession?.ebookLinker ?? EbookAudiobookLinker.shared).linkedAudiobookAsync(for: fresh)
        case .audiobook:
            counterpart = await (profileSession?.ebookLinker ?? EbookAudiobookLinker.shared).linkedEbookAsync(for: fresh)
        case .podcast:
            counterpart = nil
        }

        let siblings: [Book]
        if fresh.isComic, let aggregate = Self.seriesIdentity(for: fresh) {
            siblings = await seriesBooksPage(for: aggregate, mediaScope: ["ebook"], offset: 0, limit: 7)
                .filter { $0.uniqueId != fresh.uniqueId }
        } else if let series = fresh.series {
            siblings = await appState.bookStore.books(inSeries: series).filter { $0.stableId != fresh.stableId }
        } else {
            siblings = []
        }

        return BookDetailSnapshot(
            book: fresh,
            counterpart: counterpart,
            inSeries: DetailSeriesOrder.sorted(siblings),
            workSummary: await workSummary(for: fresh)
        )
    }

    func canDownload(_ book: Book) -> Bool {
        guard book.source != .local else { return false }
        guard let provider = appState.getProvider(book.providerId) else { return true }
        return provider.capabilities.contains(.downloads)
    }

    func hasConnection(id: UUID) -> Bool {
        appState.providerConnections.connections.contains { $0.id == id }
    }

    func sourceConnection(for book: Book) -> ServerConnection? {
        appState.providerConnections.connections.first { $0.id == book.providerId }
    }

    func sourceConnection(for collection: Collection) -> ServerConnection? {
        guard let providerId = collection.providerId else { return nil }
        return appState.providerConnections.connections.first { $0.id == providerId }
    }

    func provider(for book: Book) -> LibraryProvider? {
        appState.getProvider(book.providerId)
    }

    func supportsPersonalRating(_ book: Book) -> Bool {
        appState.providerConnections.capability(PersonalRatingProvider.self, for: book)?.supportsPersonalRating == true
    }

    func setPersonalRating(_ rating: Int, for book: Book) async throws -> Book {
        guard let provider = appState.providerConnections.capability(PersonalRatingProvider.self, for: book),
            provider.supportsPersonalRating
        else {
            throw ProviderError.notImplemented
        }

        let normalized = min(max(rating, 1), 5)
        let edits = profileSession?.bookEdits ?? .shared
        guard edits.submit(.rating(normalized), for: book) != nil else { throw ProviderError.notImplemented }

        var updated = book
        if let cached = updateBook(uniqueId: book.uniqueId, { $0.personalRating = Double(normalized) }) {
            updated = cached
        } else {
            updated.personalRating = Double(normalized)
            await appState.bookStore.upsertBooks([updated])
        }
        notifyLibraryChanged()
        await edits.flush()
        return updated
    }

    func isSaved(_ book: Book, in list: SavedBooksStore.List) -> Bool {
        let provider = appState.providerConnections.capability(SavedBooksProvider.self, for: book)
        return (provider?.relatedSavedBookIDs(for: book) ?? [book.uniqueId])
            .contains { (profileSession?.savedBooks ?? SavedBooksStore.shared).contains($0, in: list) }
    }

    func toggleSaved(_ book: Book, in list: SavedBooksStore.List) async {
        let store = (profileSession?.savedBooks ?? SavedBooksStore.shared)
        guard !store.isUpdating(book.uniqueId, in: list) else { return }
        store.setUpdating(true, id: book.uniqueId, in: list)
        defer { store.setUpdating(false, id: book.uniqueId, in: list) }

        let provider = appState.providerConnections.capability(SavedBooksProvider.self, for: book)
        let relatedIDs = provider?.relatedSavedBookIDs(for: book) ?? [book.uniqueId]
        let saved = !relatedIDs.contains { store.contains($0, in: list) }
        for id in relatedIDs where id != book.uniqueId {
            store.set(id, in: list, saved: false, enqueue: false)
        }
        store.set(book.uniqueId, in: list, saved: saved, enqueue: provider != nil)
        store.setSyncError(nil, for: book.uniqueId)
        guard let provider else { return }

        do {
            guard try await provider.canSyncSavedBooks() else {
                store.set(book.uniqueId, in: list, saved: saved, enqueue: false)
                return
            }
            let refreshed = await syncSavedBooks(providerId: book.providerId, provider: provider)
            if !refreshed {
                let source = sourceConnection(for: book)?.name ?? "the server"
                store.setSyncError("Saved on this device, but couldn’t confirm it with \(source).", for: book.uniqueId)
            }
        } catch {
            let source = sourceConnection(for: book)?.name ?? "the server"
            store.setSyncError("Saved on this device, but couldn’t update \(source).", for: book.uniqueId)
        }
    }

    func refreshSavedBooks() async -> [String] {
        var failedSources: [String] = []
        for connection in appState.providerConnections.connections where connection.isConnected && !connection.isArchived {
            guard let provider = appState.providerConnections.provider(for: connection.id) as? SavedBooksProvider else {
                continue
            }
            do {
                guard try await provider.canSyncSavedBooks() else { continue }
                if !(await syncSavedBooks(providerId: connection.id, provider: provider)) {
                    failedSources.append(connection.name)
                }
            } catch {
                failedSources.append(connection.name)
            }
        }
        return failedSources
    }

    private func syncSavedBooks(providerId: UUID, provider: SavedBooksProvider) async -> Bool {
        let store = (profileSession?.savedBooks ?? SavedBooksStore.shared)
        guard store.beginSync(providerId: providerId) else { return true }
        defer { store.endSync(providerId: providerId) }
        store.prepareFirstSync(providerId: providerId)

        var attempted = Set<UUID>()
        var hadWriteFailure = false
        repeat {
            let mutations = store.pendingMutations(for: providerId).filter { !attempted.contains($0.revision) }
            let books = await appState.bookStore.booksByUniqueIds(Set(mutations.map(\.uniqueId)))
            for mutation in mutations {
                attempted.insert(mutation.revision)
                guard let book = books[mutation.uniqueId] else {
                    hadWriteFailure = true
                    continue
                }
                do {
                    try await provider.setSavedBook(book, list: mutation.list, saved: mutation.saved)
                } catch {
                    hadWriteFailure = true
                    let source = sourceConnection(for: book)?.name ?? "the server"
                    store.setSyncError("Saved on this device, but couldn’t update \(source).", for: book.uniqueId)
                }
            }

            do {
                let allBooks = await appState.bookStore.allBooks()
                let libraryIds = Set(allBooks.filter { $0.providerId == providerId }.map(\.libraryId))
                    .union(provider.connection.selectedLibraryIds ?? [])
                let serverSnapshot = try await provider.fetchSavedBookIDs(libraryIds: libraryIds)
                guard !Task.isCancelled else { return false }
                let prefix = "\(providerId)_"
                let availableIDs = Set(allBooks.filter { $0.providerId == providerId }.map(\.id))
                var snapshot: [SavedBookList: Set<String>] = [:]
                for list in SavedBookList.allCases {
                    guard let serverIDs = serverSnapshot[list] else { return false }
                    let existingIDs = Set(store.ids(in: list)
                        .filter { $0.hasPrefix(prefix) }
                        .map { String($0.dropFirst(prefix.count)) })
                        .union(store.pendingMutations(for: providerId)
                            .filter { $0.list == list }
                            .map { String($0.uniqueId.dropFirst(prefix.count)) })
                    snapshot[list] = provider.localSavedBookIDs(
                        serverIDs,
                        existingIDs: existingIDs,
                        availableIDs: availableIDs
                    )
                }
                store.reconcile(providerId: providerId, snapshot: snapshot)
            } catch {
                return false
            }
        } while store.pendingMutations(for: providerId).contains { !attempted.contains($0.revision) }
        return !hadWriteFailure
    }

    func updateBook(uniqueId: String, _ transform: (inout Book) -> Void) -> Book? {
        appState.mutateBook(uniqueId: uniqueId, transform)
    }

    func separateTrackIntoBook(_ track: AudioTrack, from book: Book) async throws {
        guard book.source == .local || book.source == .smb,
            let filePath = track.filePath,
            !filePath.isEmpty,
            let tracks = book.audioTracks,
            tracks.count > 1
        else {
            throw AudiobookSeparationError.unsupported
        }

        let sourceId = book.libraryId
        (profileSession?.groupingOverrides ?? AudiobookGroupingOverrideStore.shared).forceStandalone(
            source: book.source,
            sourceId: sourceId,
            filePath: filePath
        )

        do {
            switch book.source {
            case .local:
                guard let library = (profileSession?.localLibrary ?? LocalLibraryStorageStore.shared).loadLibraries().first(where: { $0.id == sourceId }) else {
                    throw AudiobookSeparationError.sourceUnavailable
                }
                let result = try await (profileSession?.localLibraryService ?? LocalLibraryService.shared).scanLibrary(library)
                (profileSession?.localLibrary ?? LocalLibraryStorageStore.shared).saveScanResult(result)
                catalog.forceNextLocalRefresh = true
                await catalog.refreshLocalLibrariesFromUI()
            case .smb:
                guard profileSession?.isOwner ?? true else { throw AudiobookSeparationError.sourceUnavailable }
                guard let source = await SMBLibraryService.shared.getSources().first(where: { $0.id == sourceId }) else {
                    throw AudiobookSeparationError.sourceUnavailable
                }
                _ = try await SMBLibraryService.shared.scanLibrary(source, mode: .quick)
                let rebuilt = await SMBLibraryService.shared.getBooks(for: sourceId).map { $0.toBook() }
                await appState.bookStore.replaceLibrary(
                    books: rebuilt,
                    libraryId: sourceId,
                    providerId: rebuilt.first?.providerId ?? book.providerId,
                    allowSparseResult: false
                )
                notifyLibraryChanged()
            default:
                throw AudiobookSeparationError.unsupported
            }
        } catch {
            (profileSession?.groupingOverrides ?? AudiobookGroupingOverrideStore.shared).removeForcedStandalone(
                source: book.source,
                sourceId: sourceId,
                filePath: filePath
            )
            throw error
        }
    }

    @discardableResult
    func resolveReadAloudIfUnknown(for book: Book) async -> Book? {
        guard book.mediaType == .ebook, book.epub3Features?.hasMediaOverlay != true,
            profileSession?.isRetired != true else { return nil }
        var features: EPUB3Features?
        #if os(iOS)
        let downloads = profileSession?.downloads ?? UnifiedDownloadService.shared
        if let fileURL = downloads.existingReaderAsset(for: book),
            EbookFormat.from(fileExtension: fileURL.pathExtension) == .epub
        {
            features = await EPUB3SMILParser.detectFeatures(epubFileURL: fileURL)
        }
        #endif
        if features?.hasMediaOverlay != true,
            let provider = appState.getProvider(book.providerId) as? BookloreProvider
        {
            features = await provider.fetchEPUB3Features(bookId: book.id) ?? features
        }
        guard let features, profileSession?.isRetired != true, !Task.isCancelled else { return nil }
        let current = await appState.bookStore.book(uniqueId: book.uniqueId) ?? book
        guard profileSession?.isRetired != true, !Task.isCancelled else { return nil }
        var updated = updateBook(uniqueId: book.uniqueId) { $0.epub3Features = features } ?? current
        updated.epub3Features = features
        await appState.bookStore.upsertBooks([updated])
        notifyLibraryChanged()
        return updated
    }

    func applyCurrentBookChapters(_ chapters: [Chapter], for book: Book) {
        var persistedBook = book
        persistedBook.chapters = chapters

        if let updated = appState.mutateBook(uniqueId: book.uniqueId, { $0.chapters = chapters }) {
            persistedBook = updated
        } else {
            Task(priority: .background) {
                await appState.bookStore.upsertBooks([persistedBook])
            }
        }

        updateActiveChapters(chapters, matching: book)
        catalog.saveMetadataChanges()
    }

    private func updateActiveChapters(_ chapters: [Chapter], matching book: Book) {
        if var active = appState.currentBook, isSameBook(active, book) {
            active.chapters = chapters
            appState.currentBook = active
        }

        ActivePlayback.composition.bookMetadataUpdater.updateChapters(chapters, for: book)

        (profileSession?.playback.player ?? PlayerViewModel.shared).refreshFromCurrentPlayback()
    }

    private func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }

    func notifyLibraryChanged() {
        appState.allBooksChanged.send(())
    }

    func toggleFinished(_ book: Book) -> Book {
        progressStore.toggleFinished(for: book)
        let observedAt = Date()
        var updated = book
        updated.isFinished.toggle()
        updated.currentTime = updated.isFinished ? (updated.duration ?? 0) : 0
        if updated.mediaType == .ebook {
            updated.ebookProgress = updated.isFinished ? 1 : 0
            updated.epubLocator = nil
        }
        updated.lastUpdate = observedAt
        Task {
            await (profileSession?.linkedProgress ?? LinkedBookProgressCoordinator.shared).setPairFinished(
                from: updated,
                finished: updated.isFinished,
                observedAt: observedAt
            )
        }
        return updated
    }

    func resetProgressToBeginning(for book: Book) {
        progressStore.resetToBeginning(for: book)
        Task {
            await (profileSession?.linkedProgress ?? LinkedBookProgressCoordinator.shared).resetPair(from: book)
        }
    }

    private var unreadMarker: BookUnreadMarker {
        let session = profileSession ?? .owner
        return BookUnreadMarker(
            lastOpened: session.lastOpened,
            playerState: session.playerState,
            session: appState,
            playback: session.playback.composition.controller,
            forgetRestoredBook: { session.playback.player.forgetRestoredBook(stableId: $0) },
            pairedStableId: { await session.linkedProgress.pairedStableId(for: $0) },
            resetProgress: { [self] in resetProgressToBeginning(for: $0) }
        )
    }

    func canMarkUnread(_ book: Book) -> Bool {
        unreadMarker.canMarkUnread(book)
    }

    func markUnreadNeedsConfirmation(_ book: Book) -> Bool {
        unreadMarker.needsConfirmation(book)
    }

    func markUnread(_ book: Book) async {
        await unreadMarker.markUnread(book)
    }

    func hide(_ book: Book) async {
        recovery.removeBook(book)
        await appState.bookStore.setHidden(true, stableId: book.stableId)
    }

    func hideFromLibrary(_ books: [Book]) async {
        guard !books.isEmpty else { return }
        recovery.removeBooks(books)

        var preferences = (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences()
        for book in books {
            preferences.hiddenBookIds.insert(book.stableId)
            preferences.hiddenBookNames[book.stableId] = book.title
        }
        (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).savePreferences(preferences)

        for stableId in books.map(\.stableId) {
            await appState.bookStore.setHidden(true, stableId: stableId)
        }
    }

    func restoreHiddenBooks(stableIds: [String]) async {
        for stableId in stableIds {
            recovery.restoreDeletedBook(stableId)
            await appState.bookStore.setHidden(false, stableId: stableId)
            await appState.bookStore.setDeleted(false, stableId: stableId)
        }
    }

    func recentlyDeletedEntries() -> [RecentlyDeletedBookEntry] {
        (profileSession?.deletedBooks ?? DeletedBooksTombstoneStore.shared).allEntries.map {
            RecentlyDeletedBookEntry(stableId: $0.stableId, title: $0.title, deletedAt: $0.deletedAt)
        }
    }

    func restoreDeletedBooks(_ stableIds: [String]) async {
        await recovery.restoreDeletedBooks(stableIds)
    }

    func unlinkAudiobook(from ebook: Book) -> Book {
        if let audiobook = (profileSession?.ebookLinker ?? EbookAudiobookLinker.shared).linkedAudiobook(for: ebook) {
            if profileSession?.isOwner ?? true {
                (profileSession?.storyAlignService ?? StoryAlignService.shared).deleteConversions(involving: ebook)
            }
            #if os(iOS)
            let passages = (profileSession ?? .owner).passageAlignment
            Task { await passages.removePair(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId) }
            #endif
        }
        appState.mutateBook(uniqueId: ebook.uniqueId) {
            $0.linkedAudiobookStableId = nil
            $0.linkedAudiobookChapterOffset = 0
        }
        (profileSession?.ebookLinks ?? EbookLinkStore.shared).saveLinks()
        (profileSession?.ebookLinker ?? EbookAudiobookLinker.shared).invalidateCache()
        (profileSession?.linkedProgress ?? LinkedBookProgressCoordinator.shared).removeMapping(ebookStableId: ebook.stableId)
        Task {
            guard appState.bookInMemory(stableId: ebook.stableId)?.linkedAudiobookStableId == nil else {
                return
            }
            await appState.bookStore.removeLink(ebookStableId: ebook.stableId)
        }
        var updated = ebook
        updated.linkedAudiobookStableId = nil
        updated.linkedAudiobookChapterOffset = 0
        return updated
    }

    func linkAudiobook(_ audiobook: Book, to ebook: Book) async -> Bool {
        let updated = appState.mutateBook(uniqueId: ebook.uniqueId) {
            $0.linkedAudiobookStableId = audiobook.stableId
            $0.linkedAudiobookChapterOffset = 0
        }
        guard updated != nil else { return false }
        (profileSession?.ebookLinks ?? EbookLinkStore.shared).saveLinks()
        await appState.bookStore.upsertLink(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId,
            chapterOffset: 0
        )
        (profileSession?.ebookLinker ?? EbookAudiobookLinker.shared).invalidateCache()
        (profileSession?.linkedProgress ?? LinkedBookProgressCoordinator.shared).removeMapping(ebookStableId: ebook.stableId)

        var linkedAudiobook = audiobook
        if linkedAudiobook.chapters?.isEmpty != false {
            await catalog.refreshBookDetails(for: audiobook)
            linkedAudiobook = appState.bookInMemory(stableId: audiobook.stableId) ?? audiobook
        }

        guard let linkedEbook = appState.bookInMemory(uniqueId: ebook.uniqueId) else { return true }
        if let ebookChapters = await (profileSession?.ebookChapters ?? EbookChapterSyncService.shared).extractEbookChapters(for: linkedEbook) {
            let offset =
                (profileSession?.ebookChapters ?? EbookChapterSyncService.shared).recommendedOffset(
                    ebookChapters: ebookChapters,
                    audiobookChapters: linkedAudiobook.chapters
                ) ?? 0
            if offset != 0 {
                appState.mutateBook(uniqueId: ebook.uniqueId) {
                    $0.linkedAudiobookChapterOffset = offset
                }
                (profileSession?.ebookLinks ?? EbookLinkStore.shared).saveLinks()
                await appState.bookStore.upsertLink(
                    ebookStableId: ebook.stableId,
                    audiobookStableId: audiobook.stableId,
                    chapterOffset: offset
                )
                (profileSession?.ebookLinker ?? EbookAudiobookLinker.shared).invalidateCache()
            }

            if let synced = (profileSession?.ebookChapters ?? EbookChapterSyncService.shared).syncChaptersIfPossible(
                ebookChapters: ebookChapters,
                audiobookChapters: linkedAudiobook.chapters,
                offset: offset
            ) {
                appState.mutateBook(uniqueId: ebook.uniqueId) { $0.chapters = synced }
                (profileSession?.readerArtifacts ?? ReaderArtifactsStore.shared).saveCachedChapters(bookId: linkedEbook.stableId, chapters: synced)
                if linkedEbook.id != linkedEbook.stableId {
                    (profileSession?.readerArtifacts ?? ReaderArtifactsStore.shared).saveCachedChapters(bookId: linkedEbook.id, chapters: synced)
                }
            }
        }

        await (profileSession?.linkedProgress ?? LinkedBookProgressCoordinator.shared).reconcilePair(for: linkedEbook)
        return true
    }

    func permanentlyDelete(_ book: Book) {
        recovery.permanentlyDeleteBook(book)
    }

    func book(uniqueId: String) async -> Book? {
        await appState.bookStore.book(uniqueId: uniqueId)
    }

    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int, sort: [BookStoreSortDescriptor] = []) async -> [Book] {
        await appState.bookStore.comicBooksPage(sourceFilter: sourceFilter, offset: offset, limit: limit, sort: sort)
    }

    func comicBookCount(sourceFilter: LibrarySourceFilter) async -> Int {
        await appState.bookStore.comicBookCount(sourceFilter: sourceFilter)
    }

    func offlineBookIDs(in books: [Book]) async -> Set<String> {
        guard !books.isEmpty else { return [] }
        let availability = await (profileSession?.ebooks ?? LocalEbookImporter.shared).offlineAvailability()
        return Set(await availability.existingBooks(in: books).map(\.uniqueId))
    }

    nonisolated static func seriesIdentity(for book: Book) -> BrowseSeriesAggregate? {
        let series = book.series?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard book.isComic || series?.isEmpty == false else { return nil }
        let name = series?.isEmpty == false ? series! : book.title
        let standalone = book.isComic && book.comicMetadata == nil && series?.isEmpty != false
        return BrowseSeriesAggregate(
            name: book.isComic ? name : NameNormalizer.normalizeSeriesName(name),
            bookCount: 1, representativeThumb: book.thumb, matchingNames: [name],
            isComic: book.isComic, providerId: book.isComic ? book.providerId : nil,
            libraryId: book.isComic ? book.libraryId : nil, comicSeriesID: book.comicMetadata?.seriesID,
            standaloneBookUniqueID: standalone ? book.uniqueId : nil
        )
    }

    func seriesAggregate(for book: Book) async -> BrowseSeriesAggregate? {
        guard let identity = Self.seriesIdentity(for: book) else { return nil }
        return await seriesAggregate(for: identity)
    }

    func seriesAggregate(for identity: BrowseSeriesAggregate) async -> BrowseSeriesAggregate {
        await appState.bookStore.seriesAggregate(for: identity) ?? identity
    }

    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int, slice: ComicSeriesSlice) async -> [Book] {
        await appState.bookStore.seriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: offset, limit: limit, slice: slice)
    }

    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int) async -> [Book] {
        await appState.bookStore.seriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: offset, limit: limit)
    }

    func book(stableId: String) async -> Book? {
        await appState.bookStore.book(stableId: stableId)
    }

    func readAloudSourceBook(stableId: String) async -> Book? {
        await appState.bookStore.book(stableId: stableId)
            ?? appState.bookInMemory(stableId: stableId)
    }

    func totalBookCount() async -> Int {
        await appState.bookStore.bookCount()
    }

    func bookCount(mediaType: String?) async -> Int {
        if let mediaType {
            await appState.bookStore.bookCount(mediaType: mediaType)
        } else {
            await appState.bookStore.bookCount()
        }
    }

    func bookCount(sourceFilter: LibrarySourceFilter, mediaType: String?) async -> Int {
        if mediaType == nil, let remote = remoteBrowse(sourceFilter),
            let count = try? await remote.provider.remoteBookCount(libraryId: remote.libraryId)
        {
            (profileSession?.remoteLibraryBrowse ?? RemoteLibraryBrowseStore.shared).record(
                providerId: remote.provider.connection.id,
                libraryId: remote.libraryId,
                bookCount: count
            )
            return count
        }
        switch sourceFilter {
        case .all, .device:
            return await bookCount(mediaType: mediaType)
        case let .connection(providerId):
            return await appState.bookStore.bookCount(providerId: providerId, mediaType: mediaType)
        case let .library(providerId, libraryId):
            return await appState.bookStore.bookCount(libraryId: libraryId, providerId: providerId)
        }
    }

    func searchBooks(query: String, sourceFilter: LibrarySourceFilter, limit: Int) async -> [Book] {
        if let remote = remoteBrowse(sourceFilter),
            let results = try? await remote.provider.remoteSearchBooks(
                libraryId: remote.libraryId,
                query: query,
                limit: limit
            )
        {
            return await mergingStoredRecords(results)
        }
        var results: [Book]
        switch sourceFilter {
        case let .library(providerId, libraryId):
            return await appState.bookStore.searchBooks(query: query, libraryId: libraryId, providerId: providerId, limit: limit)
        case let .connection(providerId):
            results = await appState.bookStore.searchBooks(query: query, libraryId: nil, providerId: providerId, limit: limit)
        case .all, .device:
            results = await appState.bookStore.searchBooks(query: query, limit: limit)
        }
        guard sourceFilter != .device else { return results }
        let browse = profileSession?.remoteLibraryBrowse ?? RemoteLibraryBrowseStore.shared
        var seen = Set(results.map(\.uniqueId))
        for connection in appState.providerConnections.connections where connection.isConnected && !connection.isArchived {
            if let selected = sourceFilter.providerId, selected != connection.id { continue }
            guard let provider = appState.getProvider(connection.id) as? BookloreProvider,
                provider.supportsRemoteBrowsing else { continue }
            for libraryId in browse.libraryIds(providerId: connection.id) {
                if let selected = connection.selectedLibraryIds, !selected.contains(libraryId) { continue }
                guard !Task.isCancelled else { return [] }
                guard let remote = try? await provider.remoteSearchBooks(libraryId: libraryId, query: query, limit: limit) else { continue }
                for book in await mergingStoredRecords(remote) where seen.insert(book.uniqueId).inserted {
                    results.append(book)
                }
            }
        }
        return Array(results.prefix(limit))
    }

    func usesRemoteBrowsing(sourceFilter: LibrarySourceFilter) -> Bool {
        remoteBrowse(sourceFilter) != nil
    }

    private func remoteBrowse(_ sourceFilter: LibrarySourceFilter) -> (provider: BookloreProvider, libraryId: String)? {
        guard case let .library(providerId, libraryId) = sourceFilter,
            (profileSession?.remoteLibraryBrowse ?? RemoteLibraryBrowseStore.shared).isRemoteBrowsed(providerId: providerId, libraryId: libraryId),
            let provider = appState.getProvider(providerId) as? BookloreProvider,
            provider.supportsRemoteBrowsing
        else { return nil }
        return (provider, libraryId)
    }

    private func mergingStoredRecords(_ remote: [Book]) async -> [Book] {
        guard !remote.isEmpty else { return [] }
        let suppressed = (profileSession?.deletedBooks ?? DeletedBooksTombstoneStore.shared).allDeleted
            .union((profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences().hiddenBookIds)
        let stored = await appState.bookStore.booksByUniqueIds(Set(remote.map(\.uniqueId)))
        return remote.compactMap { book in
            guard !suppressed.contains(book.stableId) else { return nil }
            return stored[book.uniqueId] ?? book
        }
    }

    static let remoteCatalogPageSize = 50
    private static let remoteCatalogRounds = 3
    @ObservationIgnored private var unreachableCatalogProviders = Set<UUID>()

    func supportsRemoteCatalog(_ sourceFilter: LibrarySourceFilter) -> Bool {
        switch sourceFilter {
        case .connection(let providerId), .library(let providerId, _):
            remoteCatalogProvider(providerId) != nil
        case .all:
            !remoteCatalogProviderIds.isEmpty
        case .device:
            false
        }
    }

    /// Remote-catalog providers in scope whose cached rows must be limited to files on this device.
    func unreachableCatalogProviderIds(for sourceFilter: LibrarySourceFilter) -> Set<UUID> {
        let scoped: Set<UUID>
        switch sourceFilter {
        case .all:
            scoped = Set(remoteCatalogProviderIds)
        case .connection(let providerId), .library(let providerId, _):
            scoped = remoteCatalogProvider(providerId) == nil ? [] : [providerId]
        case .device:
            scoped = []
        }
        guard !scoped.isEmpty else { return [] }
        return NetworkPolicyService.shared.isConnected ? scoped.intersection(unreachableCatalogProviders) : scoped
    }

    func isOnDevice(_ book: Book) -> Bool {
        (profileSession?.engine ?? EnveEngine.shared).downloads.isLibraryDownloaded(book)
    }

    func remoteCatalogFilterOptions(
        sourceFilter: LibrarySourceFilter, mediaType: AppMediaType?, search: String
    ) async -> (options: RemoteCatalogFilterOptions, issues: [CatalogLaneIssue]) {
        let request = RemoteCatalogRequest(search: nil, mediaType: mediaType, sort: .title)
        if !NetworkPolicyService.shared.isConnected {
            let entries = await onDeviceCatalogEntries(providerIds: nil, sourceFilter: sourceFilter, request: request)
            let local = LibraryAdvancedFilterPolicy.options(from: entries.map(\.book))
            return (RemoteCatalogFilterOptions(
                genres: local.genres.filter { search.isEmpty || $0.localizedStandardContains(search) },
                languages: local.languages.filter { search.isEmpty || $0.localizedStandardContains(search) }
            ), (sourceFilter.providerId.map { [$0] } ?? remoteCatalogProviderIds).map {
                catalogIssue($0, message: "Offline. Filters show files on this device.")
            })
        }
        let ids = sourceFilter.providerId.map { [$0] } ?? remoteCatalogProviderIds
        var options = RemoteCatalogFilterOptions()
        var issues: [CatalogLaneIssue] = []
        await withTaskGroup(of: (RemoteCatalogFilterOptions, [CatalogLaneIssue]).self) { group in
            for id in ids {
                group.addTask {
                    await self.remoteCatalogFilterOptions(providerId: id, sourceFilter: sourceFilter, request: request, search: search)
                }
            }
            for await (values, failures) in group {
                options.genres.append(contentsOf: values.genres)
                options.languages.append(contentsOf: values.languages)
                options.hasMore = options.hasMore || values.hasMore
                issues.append(contentsOf: failures)
            }
        }
        if sourceFilter == .all {
            let rows = await appState.bookStore.catalogPage(
                excludingProviderIds: Set(remoteCatalogProviderIds), mediaType: mediaType?.rawValue,
                search: nil, sort: [RemoteCatalogSort.title.storeDescriptor], offset: 0, limit: 1200
            )
            let excluded = (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences().excludedLibraryIds
            let local = LibraryAdvancedFilterPolicy.options(from: rows.filter {
                !excluded.contains("\($0.providerId.uuidString)_\($0.libraryId)")
            })
            options.genres.append(contentsOf: local.genres.filter { search.isEmpty || $0.localizedStandardContains(search) })
            options.languages.append(contentsOf: local.languages.filter { search.isEmpty || $0.localizedStandardContains(search) })
        }
        options.genres = LibraryAdvancedFilterPolicy.uniqueSorted(options.genres)
        options.languages = LibraryAdvancedFilterPolicy.uniqueSorted(options.languages)
        return (options, issues)
    }

    private func remoteCatalogFilterOptions(
        providerId: UUID, sourceFilter: LibrarySourceFilter, request: RemoteCatalogRequest, search: String
    ) async -> (RemoteCatalogFilterOptions, [CatalogLaneIssue]) {
        guard let provider = remoteCatalogProvider(providerId) else { return (.init(), []) }
        var result = RemoteCatalogFilterOptions()
        var failures: [CatalogLaneIssue] = []
        do {
            let scope: LibrarySourceFilter = sourceFilter == .all ? .connection(providerId) : sourceFilter
            let libraries = try await remoteCatalogLibraryIds(scope, provider: provider)
            for libraryId in libraries {
                try Task.checkCancellation()
                do {
                    let page = try await provider.fetchRemoteCatalogFilterOptions(
                        libraryId: libraryId, mediaType: request.mediaType, search: search
                    )
                    result.genres.append(contentsOf: page.genres)
                    result.languages.append(contentsOf: page.languages)
                    result.hasMore = result.hasMore || page.hasMore
                } catch {
                    if Self.isCancellation(error) { throw error }
                    failures.append(catalogIssue(providerId, message: error.localizedDescription))
                }
            }
        } catch {
            if !Self.isCancellation(error) {
                failures.append(catalogIssue(providerId, message: error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            let local = await onDeviceCatalogEntries(providerIds: [providerId], sourceFilter: sourceFilter, request: request)
            let values = LibraryAdvancedFilterPolicy.options(from: local.map(\.book))
            result.genres.append(contentsOf: values.genres.filter { search.isEmpty || $0.localizedStandardContains(search) })
            result.languages.append(contentsOf: values.languages.filter { search.isEmpty || $0.localizedStandardContains(search) })
        }
        return (result, failures)
    }

    // Each open lane advances once per round, so local rows and every server progress independently and one failure hides nothing else.
    func remoteCatalogPage(
        sourceFilter: LibrarySourceFilter,
        request: RemoteCatalogRequest,
        after cursor: RemoteCatalogCursor?,
        onPartial: (@MainActor ([CatalogEntry]) async -> Void)? = nil
    ) async -> RemoteCatalogResult {
        if !NetworkPolicyService.shared.isConnected {
            let entries = await onDeviceCatalogEntries(providerIds: nil, sourceFilter: sourceFilter, request: request)
            let providerIds = sourceFilter.providerId.map { [$0] } ?? remoteCatalogProviderIds
            return RemoteCatalogResult(
                entries: entries, books: await presentableBooks(for: entries), next: nil,
                issues: providerIds.map { catalogIssue($0, message: nil) }, reachedSource: false
            )
        }
        var issues: [CatalogLaneIssue] = []
        var state: RemoteCatalogCursor
        var newlyOffline = Set<UUID>()
        if let cursor {
            state = cursor
        } else {
            let initial = await initialCatalogCursor(sourceFilter: sourceFilter, request: request)
            state = initial.cursor
            issues = initial.issues
            newlyOffline = state.offlineProviders
        }
        let excluded = Set(remoteCatalogProviderIds)
        var entries: [CatalogEntry] = []
        var contributingLanes = Set<CatalogLane>()
        var reachedSource = false

        for _ in 0..<Self.remoteCatalogRounds where !state.lanes.isEmpty {
            let outcomes = await fetchCatalogLanes(state.lanes, request: request, excluding: excluded, onPartial: onPartial)
            guard !Task.isCancelled, profileSession?.isRetired != true else { break }
            var open: [CatalogLane: CatalogLanePosition] = [:]
            for (lane, outcome) in outcomes {
                switch outcome {
                case let .page(rows, next):
                    reachedSource = true
                    if !rows.isEmpty { contributingLanes.insert(lane) }
                    entries.append(contentsOf: rows)
                    if let providerId = lane.providerId { unreachableCatalogProviders.remove(providerId) }
                    guard let next else { continue }
                    if case .token(let token) = next, !state.seenTokens[lane, default: []].insert(token).inserted {
                        if let providerId = lane.providerId {
                            issues.append(catalogIssue(providerId, message: "The server repeated a page of results."))
                        }
                        continue
                    }
                    open[lane] = next
                case let .failed(error):
                    guard !Self.isCancellation(error), let providerId = lane.providerId else { continue }
                    if RemoteCatalogConnectivity.isUnavailable(error) {
                        unreachableCatalogProviders.insert(providerId)
                        if state.offlineProviders.insert(providerId).inserted {
                            newlyOffline.insert(providerId)
                            issues.append(catalogIssue(providerId, message: nil))
                        }
                    } else {
                        issues.append(catalogIssue(providerId, message: error.localizedDescription))
                    }
                }
            }
            let offline = state.offlineProviders
            state.lanes = open.filter { lane, _ in lane.providerId.map { !offline.contains($0) } ?? true }
            if !entries.isEmpty { break }
        }

        entries.append(contentsOf: await onDeviceCatalogEntries(
            providerIds: newlyOffline, sourceFilter: sourceFilter, request: request
        ))
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.book.uniqueId).inserted }
        if contributingLanes.count + (newlyOffline.isEmpty ? 0 : 1) > 1 {
            let order = applySort(entries.map(\.book), descriptors: [request.sort.libraryDescriptor]).map(\.uniqueId)
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            entries.sort { rank[$0.book.uniqueId, default: 0] < rank[$1.book.uniqueId, default: 0] }
        }
        return RemoteCatalogResult(
            entries: entries,
            books: await presentableBooks(for: entries),
            next: state.lanes.isEmpty ? nil : state,
            issues: issues,
            reachedSource: reachedSource
        )
    }

    // Summaries take stored local state and user metadata; stored rows are re-read so downloads and progress stay current.
    func presentableBooks(for entries: [CatalogEntry]) async -> [Book] {
        guard !entries.isEmpty else { return [] }
        let suppressed = (profileSession?.deletedBooks ?? DeletedBooksTombstoneStore.shared).allDeleted
            .union((profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences().hiddenBookIds)
        let overlaid = await overlayStoredRecords(onto: entries.filter(\.isSummary).map(\.book))
        let summaries = Dictionary(overlaid.map { ($0.uniqueId, $0) }, uniquingKeysWith: { first, _ in first })
        let storedIds = Set(entries.filter { !$0.isSummary }.map(\.book.uniqueId))
        let stored = storedIds.isEmpty ? [:] : await appState.bookStore.booksByUniqueIds(storedIds)
        return entries.compactMap { entry in
            let book = entry.isSummary ? summaries[entry.book.uniqueId] : (stored[entry.book.uniqueId] ?? entry.book)
            guard let book, !suppressed.contains(book.stableId) else { return nil }
            return book
        }
    }

    // Stored rows keep local progress, links, and resolved details; the fresh card supplies presentation metadata.
    private func overlayStoredRecords(onto summaries: [Book]) async -> [Book] {
        guard !summaries.isEmpty else { return [] }
        let enriched = await (profileSession?.metadataManager ?? MetadataManager.shared).enrichBooksWithStoredMetadata(summaries)
        let stored = await appState.bookStore.booksByUniqueIds(Set(summaries.map(\.uniqueId)))
        let progress = profileSession?.bookProgress ?? BookProgressStore.shared
        return enriched.map { summary in
            guard var book = stored[summary.uniqueId] else {
                var summary = summary
                if summary.mediaType == .audiobook, let local = progress.loadProgress(for: summary), local.progress > 0 {
                    summary.currentTime = local.progress
                    summary.lastUpdate = Date(timeIntervalSince1970: local.lastUpdated)
                }
                return summary
            }
            book.title = summary.title
            book.thumb = summary.thumb ?? book.thumb
            book.description = summary.description ?? book.description
            book.duration = book.duration ?? summary.duration
            book.language = book.language ?? summary.language
            return book
        }
    }

    private enum CatalogLaneOutcome: Sendable {
        case page([CatalogEntry], next: CatalogLanePosition?)
        case failed(any Error)
    }

    private func initialCatalogCursor(
        sourceFilter: LibrarySourceFilter,
        request: RemoteCatalogRequest
    ) async -> (cursor: RemoteCatalogCursor, issues: [CatalogLaneIssue]) {
        var cursor = RemoteCatalogCursor()
        var issues: [CatalogLaneIssue] = []
        let providerIds: [UUID]
        switch sourceFilter {
        case .all:
            cursor.lanes[.stored] = .offset(0)
            providerIds = remoteCatalogProviderIds
            if request.search != nil {
                for providerId in grimmorySearchProviderIds {
                    cursor.lanes[.grimmorySearch(providerId: providerId)] = .start
                }
            }
        case .connection(let providerId), .library(let providerId, _):
            providerIds = [providerId]
        case .device:
            providerIds = []
        }
        let isConnected = NetworkPolicyService.shared.isConnected
        for providerId in providerIds {
            guard let provider = remoteCatalogProvider(providerId) else { continue }
            guard isConnected else {
                unreachableCatalogProviders.insert(providerId)
                cursor.offlineProviders.insert(providerId)
                issues.append(catalogIssue(providerId, message: nil))
                continue
            }
            do {
                let scope: LibrarySourceFilter = sourceFilter == .all ? .connection(providerId) : sourceFilter
                for libraryId in try await remoteCatalogLibraryIds(scope, provider: provider) {
                    cursor.lanes[.remote(providerId: providerId, libraryId: libraryId)] = .start
                }
            } catch let error where RemoteCatalogConnectivity.isUnavailable(error) {
                unreachableCatalogProviders.insert(providerId)
                cursor.offlineProviders.insert(providerId)
                issues.append(catalogIssue(providerId, message: nil))
            } catch {
                guard !Self.isCancellation(error) else { continue }
                issues.append(catalogIssue(providerId, message: error.localizedDescription))
            }
        }
        return (cursor, issues)
    }

    private func fetchCatalogLanes(
        _ lanes: [CatalogLane: CatalogLanePosition],
        request: RemoteCatalogRequest,
        excluding excluded: Set<UUID>,
        onPartial: (@MainActor ([CatalogEntry]) async -> Void)?
    ) async -> [(CatalogLane, CatalogLaneOutcome)] {
        let outcomes = await withTaskGroup(of: (CatalogLane, CatalogLaneOutcome).self) { group in
            for (lane, position) in lanes {
                group.addTask {
                    (lane, await self.fetchCatalogLane(lane, at: position, request: request, excluding: excluded))
                }
            }
            var outcomes: [(CatalogLane, CatalogLaneOutcome)] = []
            var partial: [CatalogEntry] = []
            for await outcome in group {
                outcomes.append(outcome)
                if case .page(let rows, _) = outcome.1, !rows.isEmpty, !Task.isCancelled {
                    partial.append(contentsOf: rows)
                    await onPartial?(partial)
                }
            }
            return outcomes
        }
        return outcomes.sorted { $0.0.order < $1.0.order }
    }

    private func fetchCatalogLane(
        _ lane: CatalogLane,
        at position: CatalogLanePosition,
        request: RemoteCatalogRequest,
        excluding excluded: Set<UUID>
    ) async -> CatalogLaneOutcome {
        do {
            switch lane {
            case .stored:
                let offset = if case .offset(let offset) = position { offset } else { 0 }
                let rows = await appState.bookStore.catalogPage(
                    excludingProviderIds: excluded,
                    mediaType: request.mediaType?.rawValue,
                    search: request.search,
                    sort: [request.sort.storeDescriptor],
                    offset: offset,
                    limit: Self.remoteCatalogPageSize
                )
                try Task.checkCancellation()
                return .page(
                    rows.filter { request.matchesAdvancedFilters($0) }.map { CatalogEntry(book: $0, isSummary: false) },
                    next: rows.count < Self.remoteCatalogPageSize ? nil : .offset(offset + rows.count)
                )
            case let .remote(providerId, libraryId):
                guard let provider = remoteCatalogProvider(providerId) else { throw ProviderError.notImplemented }
                let token: String? = if case .token(let token) = position { token } else { nil }
                let page = try await provider.fetchRemoteCatalogPage(
                    libraryId: libraryId,
                    request: request,
                    cursor: token,
                    limit: Self.remoteCatalogPageSize
                )
                return .page(
                    page.books.map { CatalogEntry(book: $0, isSummary: true) },
                    next: page.nextCursor.map(CatalogLanePosition.token)
                )
            case .grimmorySearch(let providerId):
                let rows = await grimmorySearchBooks(providerId: providerId, query: request.search ?? "")
                try Task.checkCancellation()
                return .page(
                    rows.filter { (request.mediaType == nil || $0.mediaType == request.mediaType) && request.matchesAdvancedFilters($0) }
                        .map { CatalogEntry(book: $0, isSummary: false) },
                    next: nil
                )
            }
        } catch {
            return .failed(error)
        }
    }

    // Mirrors the scoped Grimmory remote search in searchBooks; each remote-browsed library is searched once and failures are skipped.
    private func grimmorySearchBooks(providerId: UUID, query: String) async -> [Book] {
        guard let provider = appState.getProvider(providerId) as? BookloreProvider,
            let connection = appState.providerConnections.connections.first(where: { $0.id == providerId })
        else { return [] }
        var books: [Book] = []
        for libraryId in (profileSession?.remoteLibraryBrowse ?? RemoteLibraryBrowseStore.shared).libraryIds(providerId: providerId) {
            if let selected = connection.selectedLibraryIds, !selected.contains(libraryId) { continue }
            guard !Task.isCancelled else { return [] }
            guard let remote = try? await provider.remoteSearchBooks(
                libraryId: libraryId, query: query, limit: Self.remoteCatalogPageSize
            ) else { continue }
            books.append(contentsOf: await mergingStoredRecords(remote))
        }
        return books
    }

    // Every download row is narrowed by scope and query before matching, so no on-device match is cut off by a cap.
    private func onDeviceCatalogEntries(
        providerIds: Set<UUID>?,
        sourceFilter: LibrarySourceFilter,
        request: RemoteCatalogRequest
    ) async -> [CatalogEntry] {
        guard providerIds?.isEmpty != true else { return [] }
        let ebooks = request.mediaType == .audiobook ? [] : await appState.bookStore.downloadedEbooks(limit: .max)
        let audiobooks: [Book]
        if request.mediaType == .ebook {
            audiobooks = []
        } else {
            let storage = profileSession?.localStorage ?? LocalStorageManager.shared
            audiobooks = await downloadedAudiobooks(storageKeys: Set(storage.downloadedAudiobookIds()))
        }
        let candidates = (ebooks + audiobooks).filter { providerIds?.contains($0.providerId) ?? true }
        return request.onDeviceBooks(
            from: candidates, providerId: sourceFilter.providerId, libraryId: sourceFilter.libraryId,
            isOnDevice: { isOnDevice($0) }
        ).map { CatalogEntry(book: $0, isSummary: false) }
    }

    private func catalogIssue(_ providerId: UUID, message: String?) -> CatalogLaneIssue {
        let name = appState.providerConnections.connections.first { $0.id == providerId }?.name
            ?? remoteCatalogProvider(providerId)?.connection.name
            ?? "A server"
        return CatalogLaneIssue(providerId: providerId, sourceName: name, message: message)
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func remoteCatalogScope(for sourceFilter: LibrarySourceFilter) -> RemoteCatalogScope {
        let ids = sourceFilter.providerId.map { [$0] } ?? remoteCatalogProviderIds
        let sources = ids.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> RemoteCatalogScope.Source? in
            guard let connection = remoteCatalogProvider(id)?.connection else { return nil }
            return RemoteCatalogScope.Source(
                id: id, url: connection.url, username: connection.username, userId: connection.userId,
                selectedLibraryIds: connection.selectedLibraryIds
            )
        }
        let providerIds = Set(sources.map(\.id))
        return RemoteCatalogScope(
            sources: sources,
            libraryKeys: Set(catalog.libraries.filter { providerIds.contains($0.providerId) }.map {
                "\($0.providerId.uuidString)_\($0.id)"
            }),
            excludedLibraryKeys: (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared)
                .loadPreferences().excludedLibraryIds
        )
    }

    private func remoteCatalogProvider(_ providerId: UUID) -> (any RemoteCatalogBrowsingProvider)? {
        guard appState.providerConnections.connections.first(where: { $0.id == providerId })?.isArchived != true else { return nil }
        return appState.getProvider(providerId) as? any RemoteCatalogBrowsingProvider
    }

    // Includes providers known only through catalog libraries, so a source is browsable before its connection list reloads.
    private var remoteCatalogProviderIds: [UUID] {
        var seen = Set<UUID>()
        let candidates = appState.providerConnections.connections.map(\.id) + catalog.libraries.map(\.providerId)
        return candidates.filter { seen.insert($0).inserted && remoteCatalogProvider($0) != nil }
    }

    private var grimmorySearchProviderIds: [UUID] {
        appState.providerConnections.connections.compactMap { connection in
            guard connection.isConnected, !connection.isArchived,
                let provider = appState.getProvider(connection.id) as? BookloreProvider,
                provider.supportsRemoteBrowsing
            else { return nil }
            return connection.id
        }
    }

    private func remoteCatalogLibraryIds(
        _ sourceFilter: LibrarySourceFilter,
        provider: any RemoteCatalogBrowsingProvider
    ) async throws -> [String] {
        let providerId = provider.connection.id
        let excluded = (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences().excludedLibraryIds
        let selected = provider.connection.selectedLibraryIds ?? []
        let candidates: [String]
        if let libraryId = sourceFilter.libraryId {
            candidates = [libraryId]
        } else {
            let known = catalog.libraries.filter { $0.providerId == providerId }.map(\.id)
            candidates = known.isEmpty ? try await provider.fetchLibraries().map(\.id) : known
        }
        return candidates.filter {
            (selected.isEmpty || selected.contains($0)) && !excluded.contains("\(providerId.uuidString)_\($0)")
        }
    }

    func savedBooks(withUniqueIds ids: [String]) async -> [Book] {
        let stored = await appState.bookStore.booksByUniqueIds(Set(ids))
        return ids.compactMap { stored[$0] }
    }

    private static func remoteSort(for sort: [BookStoreSortDescriptor]) -> (field: GrimmoryRemoteSort, descending: Bool)? {
        guard sort.count == 1, let descriptor = sort.first else { return nil }
        let field: GrimmoryRemoteSort
        switch descriptor.field {
        case .recent: field = .addedOn
        case .recentlyRead: field = .lastReadTime
        case .title: field = .title
        default: return nil
        }
        return (field, descriptor.direction == .descending)
    }

    func matchesStatus(_ book: Book, status: LibraryStatusFilter) -> Bool {
        switch status {
        case .all:
            return true
        case .listening:
            return !book.isFinished && book.currentTime > 0
                && statusAllowsContinue(book)
                && (book.mediaType != .ebook || book.readAloudSourceStableId != nil)
        case .reading:
            return !book.isFinished
                && statusAllowsContinue(book)
                && book.mediaType == .ebook
                && book.canonicalEbookProgress > 0.001
        case .finished:
            return book.isFinished
        case .downloaded:
            if book.mediaType == .ebook {
                return (profileSession?.engine ?? EnveEngine.shared).downloads.hasPermanentEbookDownload(book)
            }
            return (profileSession?.engine ?? EnveEngine.shared).downloads.isAudiobookDownloaded(book)
        }
    }

    private func statusAllowsContinue(_ book: Book) -> Bool {
        guard book.source == .booklore, let status = book.serverReadStatus else { return true }
        return status == "READING" || status == "RE_READING" || status == "IN_PROGRESS"
    }

    func filterStatus(_ books: [Book], status: LibraryStatusFilter) -> [Book] {
        books.filter { matchesStatus($0, status: status) }
    }

    nonisolated func applySort(_ books: [Book], descriptors: [LibrarySortDescriptor]) -> [Book] {
        let descriptors =
            descriptors.isEmpty
            ? [LibrarySortDescriptor(field: .recent, direction: .descending)]
            : descriptors
        return books.sorted { lhs, rhs in
            for descriptor in descriptors {
                let lhsMissing = missingSortValue(lhs, sort: descriptor.field)
                let rhsMissing = missingSortValue(rhs, sort: descriptor.field)
                if lhsMissing != rhsMissing {
                    return !lhsMissing
                }
                let comparison = sortComparison(lhs, rhs, sort: descriptor.field)
                if comparison != .orderedSame {
                    return descriptor.direction == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private nonisolated func missingSortValue(_ book: Book, sort: LibrarySort) -> Bool {
        switch sort {
        case .recent:
            return book.addedAt == nil
        case .recentlyRead:
            return book.currentTime <= 0 && book.canonicalEbookProgress <= 0.001
        case .title:
            return book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .author, .authorSurname:
            return book.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .narrator, .narratorSurname:
            return book.narrator?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .series:
            return book.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .progress:
            return false
        case .duration:
            return book.duration == nil
        case .year:
            return book.publishedYear == nil
        case .goodreadsRating:
            return book.personalRating == nil && book.goodreadsRating == nil
        }
    }

    private nonisolated func sortComparison(_ lhs: Book, _ rhs: Book, sort: LibrarySort) -> ComparisonResult {
        switch sort {
        case .recent:
            return compare(lhs.addedAt ?? .distantPast, rhs.addedAt ?? .distantPast)
        case .recentlyRead:
            return compare(lhs.lastUpdate, rhs.lastUpdate)
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .author:
            return compareName(lhs.author, rhs.author, style: .given)
        case .authorSurname:
            return compareName(lhs.author, rhs.author, style: .surname)
        case .narrator:
            return compareName(lhs.narrator, rhs.narrator, style: .given)
        case .narratorSurname:
            return compareName(lhs.narrator, rhs.narrator, style: .surname)
        case .series:
            let series = compareText(lhs.series, rhs.series)
            if series != .orderedSame { return series }
            return compare(BookSortKeys.seriesNumber(lhs.seriesSequence), BookSortKeys.seriesNumber(rhs.seriesSequence))
        case .progress:
            return compare(lhs.progressPercentage, rhs.progressPercentage)
        case .duration:
            return compare(lhs.duration ?? 0, rhs.duration ?? 0)
        case .year:
            return compare(lhs.publishedYear ?? 0, rhs.publishedYear ?? 0)
        case .goodreadsRating:
            return compare(
                max(lhs.personalRating ?? 0, lhs.goodreadsRating ?? 0),
                max(rhs.personalRating ?? 0, rhs.goodreadsRating ?? 0)
            )
        }
    }

    private nonisolated func compareText(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return compare(BookSortKeys.text(left), BookSortKeys.text(right))
    }

    private enum NameSortStyle {
        case given, surname
    }

    private nonisolated func compareName(
        _ lhs: String?,
        _ rhs: String?,
        style: NameSortStyle
    ) -> ComparisonResult {
        let keyStyle: BookSortKeys.NameStyle =
            switch style {
            case .given: .given
            case .surname: .surname
            }
        return compare(BookSortKeys.name(lhs, style: keyStyle), BookSortKeys.name(rhs, style: keyStyle))
    }

    private nonisolated func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    func pagedBooks(sourceFilter: LibrarySourceFilter, mediaType: String?, offset: Int, limit: Int) async -> [Book] {
        switch sourceFilter {
        case let .library(providerId, libraryId):
            await appState.bookStore.pagedBooks(libraryId: libraryId, providerId: providerId, offset: offset, limit: limit)
        case .all, .device, .connection:
            await appState.bookStore.pagedBooks(offset: offset, limit: limit, mediaType: mediaType)
        }
    }

    func pagedBooks(sourceFilter: LibrarySourceFilter, mediaType: String?, after cursor: Book?, limit: Int) async -> [Book] {
        switch sourceFilter {
        case let .library(providerId, libraryId):
            await appState.bookStore.pagedBooks(libraryId: libraryId, providerId: providerId, after: cursor, limit: limit)
        case let .connection(providerId):
            await appState.bookStore.pagedBooks(providerId: providerId, after: cursor, limit: limit, mediaType: mediaType)
        case .all, .device:
            await appState.bookStore.pagedBooks(after: cursor, limit: limit, mediaType: mediaType)
        }
    }

    func sortedPagedBooks(
        sourceFilter: LibrarySourceFilter,
        mediaType: String?,
        offset: Int,
        limit: Int,
        sort: [BookStoreSortDescriptor]
    ) async -> [Book] {
        if mediaType == nil, let remote = remoteBrowse(sourceFilter),
            let remoteSort = Self.remoteSort(for: sort),
            let page = try? await remote.provider.remoteBooksPage(
                libraryId: remote.libraryId,
                offset: offset,
                limit: limit,
                sort: remoteSort.field,
                descending: remoteSort.descending
            )
        {
            return await mergingStoredRecords(page.books)
        }
        switch sourceFilter {
        case let .library(providerId, libraryId):
            return await appState.bookStore.sortedPagedBooks(
                libraryId: libraryId,
                providerId: providerId,
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                sort: sort
            )
        case let .connection(providerId):
            return await appState.bookStore.sortedPagedBooks(
                providerId: providerId,
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                sort: sort
            )
        case .all, .device:
            return await appState.bookStore.sortedPagedBooks(offset: offset, limit: limit, mediaType: mediaType, sort: sort)
        }
    }

    func largeSourceCount(sourceFilter: LibrarySourceFilter, mediaType: String?, threshold: Int) async -> Int? {
        let count = await bookCount(sourceFilter: sourceFilter, mediaType: mediaType)
        return count > threshold ? count : nil
    }

    func sourceScopedBooks(sourceFilter: LibrarySourceFilter, mediaTypes: [String], limitPerMediaType: Int? = nil) async -> [Book] {
        var result: [Book] = []
        switch sourceFilter {
        case .all:
            for raw in mediaTypes {
                let count = await appState.bookStore.bookCount(mediaType: raw)
                result.append(
                    contentsOf: await appState.bookStore.pagedBooks(
                        offset: 0,
                        limit: limitPerMediaType ?? max(count, 1),
                        mediaType: raw
                    )
                )
            }
        case .device:
            for raw in mediaTypes {
                result.append(
                    contentsOf: await appState.bookStore.firstBooks(
                        source: Book.BookSource.local.rawValue,
                        mediaType: raw,
                        limit: limitPerMediaType ?? 10000
                    )
                )
                result.append(
                    contentsOf: await appState.bookStore.firstBooks(
                        source: Book.BookSource.smb.rawValue,
                        mediaType: raw,
                        limit: limitPerMediaType ?? 10000
                    )
                )
            }
        case let .connection(providerId):
            for raw in mediaTypes {
                let count = await appState.bookStore.bookCount(providerId: providerId, mediaType: raw)
                result.append(
                    contentsOf: await appState.bookStore.pagedBooks(
                        providerId: providerId,
                        after: nil,
                        limit: limitPerMediaType ?? max(count, 1),
                        mediaType: raw
                    )
                )
            }
        case let .library(providerId, libraryId):
            let count = await appState.bookStore.bookCount(libraryId: libraryId, providerId: providerId)
            result.append(
                contentsOf: await appState.bookStore.pagedBooks(
                    libraryId: libraryId,
                    providerId: providerId,
                    offset: 0,
                    limit: limitPerMediaType ?? max(count, 1)
                )
            )
        }

        var seen = Set<String>()
        let allowedMedia = Set(mediaTypes)
        return result.filter { book in
            seen.insert(book.uniqueId).inserted && allowedMedia.contains(book.mediaType.rawValue)
        }
    }

    func continueListeningBooks(limit: Int) async -> [Book] {
        let persisted = await appState.bookStore.continueListeningBooks(limit: limit)
        let recentStableIds = Set(
            (profileSession?.bookProgress ?? BookProgressStore.shared).loadSnapshots()
                .filter { $0.book.mediaType == .audiobook }
                .map(\.stableId)
        )
        guard !recentStableIds.isEmpty else { return persisted }

        let recentBooks = await appState.bookStore.booksByStableIds(recentStableIds).values.compactMap { book -> Book? in
            guard !book.isFinished, !book.hideFromContinue,
                let progress = (profileSession?.bookProgress ?? BookProgressStore.shared).loadProgress(for: book),
                progress.progress > 0,
                book.duration.map({ progress.progress < $0 * Book.finishedProgressThreshold }) ?? true
            else {
                return nil
            }
            var updated = book
            updated.currentTime = progress.progress
            updated.lastUpdate = Date(timeIntervalSince1970: progress.lastUpdated)
            return updated
        }

        var seen = Set<String>()
        return Array(
            (persisted + recentBooks)
                .sorted { $0.lastUpdate > $1.lastUpdate }
                .filter { seen.insert($0.stableId).inserted }
                .prefix(limit)
        )
    }

    func continueReadingBooks(limit: Int) async -> [Book] {
        await appState.bookStore.continueReadingBooks(limit: limit)
    }

    func recentBooks(limit: Int) async -> [Book] {
        await appState.bookStore.recentBooks(limit: limit)
    }

    func recentHearthBooks(limit: Int) async -> [Book] {
        let audiobooks = await appState.bookStore.recentBooks(limit: limit)
        let ebooks = await appState.bookStore.recentEbooks(limit: limit)
        var seen = Set<String>()
        return Array(
            (audiobooks + ebooks)
                .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
                .filter { seen.insert($0.stableId).inserted }
                .prefix(limit)
        )
    }

    func hearthFeed(dismissedStableIds: Set<String>, currentStableId: String?) async -> HearthFeedSnapshot {
        let listening = deduplicatedHomeBooks(
            await continueListeningBooks(limit: 16),
            dismissedStableIds: dismissedStableIds,
            currentStableId: currentStableId
        )
        let reading = deduplicatedHomeBooks(
            await continueReadingBooks(limit: 16),
            dismissedStableIds: dismissedStableIds,
            currentStableId: currentStableId
        )
        return HearthFeedSnapshot(
            listening: listening,
            reading: reading,
            fresh: await recentHearthBooks(limit: 12),
            downloaded: await homeDownloadedBooks(limit: 16)
        )
    }

    func firstBooks(mediaType: String, limit: Int) async -> [Book] {
        await appState.bookStore.firstBooks(mediaType: mediaType, limit: limit)
    }

    func firstBooks(source: String, mediaType: String, limit: Int) async -> [Book] {
        await appState.bookStore.firstBooks(source: source, mediaType: mediaType, limit: limit)
    }

    func firstBooks(mediaTypes: [String], limitPerMediaType: Int) async -> [Book] {
        var books: [Book] = []
        for mediaType in mediaTypes {
            books += await firstBooks(mediaType: mediaType, limit: limitPerMediaType)
        }
        return books
    }

    func firstBooks(source: String, mediaTypes: [String], limitPerMediaType: Int) async -> [Book] {
        var books: [Book] = []
        for mediaType in mediaTypes {
            books += await firstBooks(source: source, mediaType: mediaType, limit: limitPerMediaType)
        }
        return books
    }

    func booksMatching(_ collection: SmartCollection, limit: Int?) async -> [Book] {
        await appState.bookStore.booksMatching(collection, limit: limit)
    }

    func currentCollection(for seed: Collection) -> Collection {
        (profileSession?.userCollections ?? UserCollectionStore.shared).collections.first { $0.id == seed.id }
            ?? catalog.collections.first { $0.id == seed.id && $0.providerId == seed.providerId }
            ?? seed
    }

    @discardableResult
    func addBooks(_ books: [Book], to collection: Collection) -> Int {
        let current = currentCollection(for: collection)
        guard current.isUserGenerated else { return 0 }

        var memberIDs = current.books
        var seen = Set(memberIDs)
        let additions = books.map(\.id).filter { seen.insert($0).inserted }
        guard !additions.isEmpty else { return 0 }
        memberIDs.append(contentsOf: additions)

        (profileSession?.userCollections ?? UserCollectionStore.shared).save(
            Collection(
                id: current.id,
                name: current.name,
                description: current.description,
                books: memberIDs,
                bookCount: memberIDs.count,
                iconName: current.iconName,
                color: current.color,
                providerId: current.providerId,
                parentID: current.parentID,
                customCoverPath: current.customCoverPath,
                isSystem: current.isSystem,
                isUserGenerated: true,
                remoteId: current.remoteId,
                serverIcon: current.serverIcon,
                syncToKobo: current.syncToKobo,
                displayOrder: current.displayOrder,
                isServerEditable: current.isServerEditable
            )
        )
        return additions.count
    }

    func createCollection(named name: String, books: [Book]) -> Collection? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var seen = Set<String>()
        let memberIDs = books.map(\.id).filter { seen.insert($0).inserted }
        let collection = Collection(
            id: UUID().uuidString,
            name: name,
            description: nil,
            books: memberIDs,
            bookCount: memberIDs.count,
            iconName: "books.vertical.fill",
            color: "orange",
            providerId: nil,
            isUserGenerated: true
        )
        (profileSession?.userCollections ?? UserCollectionStore.shared).save(collection)
        return collection
    }

    func currentSmartCollection(for seed: SmartCollection) -> SmartCollection {
        (profileSession?.smartCollections ?? SmartCollectionStore.shared).merged.first { $0.id == seed.id } ?? seed
    }

    func collectionsOverview() async -> LibraryCollectionsOverview {
        let smart = (profileSession?.smartCollections ?? SmartCollectionStore.shared).merged
        let mine = (profileSession?.userCollections ?? UserCollectionStore.shared).collections
        let server = catalog.collections.filter { !$0.isUserGenerated }

        var smartPreviews: [String: (count: Int, book: Book?)] = [:]
        for collection in smart {
            let count = await appState.bookStore.bookCountMatching(collection)
            let book = await appState.bookStore.booksMatching(collection, limit: 1).first
            smartPreviews[collection.id] = (count, book)
        }

        var memberPreviews: [String: Book] = [:]
        for collection in mine + server where !collection.books.isEmpty {
            if let first = await mirroredCollectionBooks(collection, limit: 5).first {
                memberPreviews[collection.scopedID] = first
            }
        }

        return LibraryCollectionsOverview(
            smart: smart,
            mine: mine,
            server: server,
            smartPreviews: smartPreviews,
            memberPreviews: memberPreviews
        )
    }

    private func saveCollectionCover(id: String, data: Data) -> String? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let filename = "collection_cover_\(id).jpg"
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            AppLogger.general.error("Error saving collection cover: \(error)")
            return nil
        }
    }

    func saveCollection(collection: Collection?, smartCollection: SmartCollection?, isSmart: Bool, values: CollectionEditorValues) {
        let id = collection?.id ?? smartCollection?.id ?? UUID().uuidString
        var coverPath = collection?.customCoverPath ?? smartCollection?.customCoverPath
        if let data = values.selectedImageData {
            coverPath = saveCollectionCover(id: id, data: data)
        }

        let trimmedName = values.name.trimmingCharacters(in: .whitespaces)
        let trimmedDetails = values.details.trimmingCharacters(in: .whitespaces)

        if isSmart {
            let updated = SmartCollection(
                id: id,
                name: trimmedName,
                description: trimmedDetails.isEmpty ? nil : trimmedDetails,
                rules: SmartCollectionRuleGroup(logicOperator: values.logicOperator, rules: values.rules),
                iconName: values.iconName,
                color: values.color,
                isSystem: smartCollection?.isSystem ?? false,
                sortOrder: smartCollection?.sortOrder ?? 100,
                parentID: smartCollection?.parentID,
                customCoverPath: coverPath
            )
            (profileSession?.smartCollections ?? SmartCollectionStore.shared).save(updated)
        } else {
            let updated = Collection(
                id: id,
                name: trimmedName,
                description: trimmedDetails.isEmpty ? nil : trimmedDetails,
                books: collection?.books ?? [],
                bookCount: collection?.bookCount ?? 0,
                iconName: values.iconName,
                color: values.color,
                providerId: collection?.providerId,
                parentID: collection?.parentID,
                customCoverPath: coverPath,
                isSystem: collection?.isSystem ?? false,
                isUserGenerated: true
            )
            (profileSession?.userCollections ?? UserCollectionStore.shared).save(updated)
        }
    }

    func deleteCollection(collection: Collection?, smartCollection: SmartCollection?) {
        if let smartCollection {
            (profileSession?.smartCollections ?? SmartCollectionStore.shared).delete(smartCollection)
        } else if let collection {
            (profileSession?.userCollections ?? UserCollectionStore.shared).delete(collection)
        }
    }

    func books(in collection: Collection) async throws -> [Book] {
        if let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId {
            return (try? await provider.fetchCollectionBooks(collectionId: remoteId, page: 0, size: 100).books) ?? []
        }
        let stored = await mirroredCollectionBooks(collection)
        guard let providerId = collection.providerId,
            let provider = appState.getProvider(providerId) as? BookloreProvider,
            provider.supportsRemoteBrowsing
        else { return stored }
        let storedIds = Set(stored.map(\.id))
        let missingIds = collection.books.filter { !storedIds.contains($0) }
        guard !missingIds.isEmpty else { return stored }
        let fetched = try await provider.fetchShelfBooks(ids: missingIds)
        let visible = await mergingStoredRecords(fetched)
        let byId = Dictionary(uniqueKeysWithValues: (stored + visible).map { ($0.id, $0) })
        return collection.books.compactMap { byId[$0] }
    }

    private func mirroredCollectionBooks(_ collection: Collection, limit: Int? = nil) async -> [Book] {
        let ids = limit.map { Array(collection.books.prefix($0)) } ?? collection.books
        guard !ids.isEmpty else { return [] }

        guard let providerId = collection.providerId else {
            let map = await appState.bookStore.booksByIds(Set(ids))
            return ids.compactMap { map[$0] }
        }

        let uniqueIds = ids.map { "\(providerId)_\($0)" }
        let map = await appState.bookStore.booksByAnyIds(Set(uniqueIds))
        return zip(ids, uniqueIds).compactMap { id, uniqueId in
            guard let book = map[uniqueId], book.providerId == providerId, book.id == id else {
                return nil
            }
            return book
        }
    }

    func bookOrbitCollectionPage(
        _ collection: Collection,
        page: Int,
        size: Int = 60,
        query: String? = nil
    ) async throws -> BookOrbitProvider.CollectionPage {
        guard let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId else {
            throw ProviderError.invalidResponse
        }
        return try await provider.fetchCollectionBooks(collectionId: remoteId, page: page, size: size, query: query)
    }

    func bookOrbitCollectionConnections() async -> [ServerConnection] {
        var result: [ServerConnection] = []
        for connection in appState.providerConnections.connections where connection.type == .bookOrbit && connection.isConnected && !connection.isArchived {
            if let provider = appState.getProvider(connection.id) as? BookOrbitProvider,
                (try? await provider.validateConnection()) == true
            {
                result.append(connection)
            }
        }
        return result
    }

    func saveBookOrbitCollection(
        connectionId: UUID,
        collection: Collection?,
        edit: BookOrbitProvider.CollectionEdit
    ) async throws {
        guard let provider = appState.getProvider(connectionId) as? BookOrbitProvider else {
            throw ProviderError.invalidResponse
        }
        if let remoteId = collection?.remoteId {
            _ = try await provider.updateCollection(id: remoteId, edit: edit)
        } else {
            _ = try await provider.createCollection(edit)
        }
        try await refreshBookOrbitCollections(providerId: connectionId)
    }

    func deleteBookOrbitCollection(_ collection: Collection) async throws {
        guard let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId else {
            throw ProviderError.invalidResponse
        }
        try await provider.deleteCollection(id: remoteId)
        try await refreshBookOrbitCollections(providerId: provider.connection.id)
    }

    func reorderBookOrbitCollections(_ collections: [Collection]) async throws {
        guard let first = collections.first, let provider = bookOrbitProvider(for: first) else { return }
        try await provider.reorderCollections(collections.compactMap(\.remoteId))
        try await refreshBookOrbitCollections(providerId: provider.connection.id)
    }

    func bookOrbitMemberships(for book: Book) async throws -> [BookOrbitCollectionMembership] {
        guard let provider = appState.getProvider(book.providerId) as? BookOrbitProvider else { return [] }
        return try await provider.collectionsContaining(bookId: book.id).filter { $0.collection.isServerEditable }.map {
            BookOrbitCollectionMembership(collection: $0.collection, containsBook: $0.containsBook)
        }
    }

    func canManageBookOrbitCollections(for book: Book) async -> Bool {
        guard let provider = appState.getProvider(book.providerId) as? BookOrbitProvider else { return false }
        return (try? await provider.validateConnection()) == true
    }

    func setBookOrbitMembership(_ containsBook: Bool, book: Book, collection: Collection) async throws {
        guard let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId else {
            throw ProviderError.invalidResponse
        }
        if containsBook {
            try await provider.addBooks([book.id], toCollection: remoteId)
        } else {
            try await provider.removeBooks([book.id], fromCollection: remoteId)
        }
        try await refreshBookOrbitCollections(providerId: provider.connection.id)
    }

    func removeBookOrbitBook(_ book: Book, from collection: Collection) async throws {
        try await setBookOrbitMembership(false, book: book, collection: collection)
    }

    private func bookOrbitProvider(for collection: Collection) -> BookOrbitProvider? {
        guard let providerId = collection.providerId else { return nil }
        return appState.getProvider(providerId) as? BookOrbitProvider
    }

    private func refreshBookOrbitCollections(providerId: UUID) async throws {
        guard let provider = appState.getProvider(providerId) as? BookOrbitProvider else { return }
        let refreshed = try await provider.fetchCollections(libraryId: nil)
        catalog.commitServerCollectionSnapshot(refreshed, from: provider)
    }

    func observedBooks(matching collection: SmartCollection) -> AsyncStream<[Book]> {
        let store = appState.bookStore
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await books in store.observe(.matching(collectionId: collection.id, payload: collection)) {
                    continuation.yield(books)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func searchBooks(query: String, limit: Int) async -> [Book] {
        await searchBooks(query: query, sourceFilter: .all, limit: limit)
    }

    func titleAuthorPairs() async -> [(title: String, author: String)] {
        await appState.bookStore.titleAuthorPairs()
    }

    func detailBooks(author name: String) async -> [Book] {
        var seen = Set<String>()
        var merged: [Book] = []
        for mediaType in ["audiobook", "ebook", "podcast"] {
            for book in await appState.bookStore.books(byAuthor: name, mediaType: mediaType, limit: 500)
            where seen.insert(book.stableId).inserted {
                merged.append(book)
            }
        }
        return DetailSeriesOrder.sorted(merged)
    }

    func detailBooks(series name: String) async -> [Book] {
        DetailSeriesOrder.sorted(await appState.bookStore.books(inSeries: name))
    }

    func libraryChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .bookStoreDidChange).map({ _ in () }) {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func downloadedEbooks(limit: Int) async -> [Book] {
        await appState.bookStore.downloadedEbooks(limit: limit)
    }

    func bookSyncSnapshots(limit: Int) -> AsyncStream<BookSyncLibrarySnapshot> {
        let store = appState.bookStore
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await (count, books) in store.observe({
                    async let count = store.bookCount(mediaType: "ebook")
                    async let books = store.firstBooks(mediaType: "ebook", limit: limit)
                    return await (count, books)
                }) {
                    continuation.yield(BookSyncLibrarySnapshot(ebookCount: count, ebooks: books))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func observedBooks(mediaType: String) -> AsyncStream<[Book]> {
        let store = appState.bookStore
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await books in store.observe(.mediaType(mediaType)) {
                    continuation.yield(books)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func books(source: String, providerId: UUID) async -> [Book] {
        await appState.bookStore.books(source: source, providerId: providerId)
    }

    func refreshDetails(for book: Book) async -> Book {
        await catalog.refreshBookDetails(for: book)
        return appState.bookInMemory(uniqueId: book.uniqueId) ?? book
    }

    func removeLocalEbookDebugImports(limit: Int) async {
        let ids = Set(
            (await firstBooks(mediaType: "ebook", limit: limit))
                .filter { $0.source == .local }
                .map(\.uniqueId)
        )
        guard !ids.isEmpty else { return }
        await appState.bookStore.deleteBooks(uniqueIds: ids)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func downloadedAudiobooks(storageKeys: Set<String>) async -> [Book] {
        let storage = profileSession?.localStorage ?? LocalStorageManager.shared
        let downloads = (profileSession?.engine ?? EnveEngine.shared).downloads
        let stored = await appState.bookStore.downloadedAudiobooks(storageKeys: storageKeys)
        let storedIds = Set(stored.map(\.stableId))
        let matchedKeys = Set(storedIds.map { LocalStorageManager.sanitizedId(for: $0) })
        let legacyIds = storageKeys.subtracting(matchedKeys).compactMap {
            (try? storage.loadMetadataOverride(OfflineBookMetadata.self, for: $0))?.stableId
        }
        let otherIds = downloads.completedDownloadBookIds.union(legacyIds).subtracting(storedIds)
        let otherBooks = await appState.bookStore.booksByStableIds(otherIds)
        return (stored + Array(otherBooks.values))
            .filter { $0.mediaType != .ebook && downloads.isAudiobookDownloaded($0) }
    }

    func homeDownloadedBooks(limit: Int) async -> [Book] {
        let ebooks = await appState.bookStore.downloadedEbooks(limit: limit)
        let storage = (profileSession?.localStorage ?? LocalStorageManager.shared)
        let downloadedIds = await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
        let audiobooks = appState.allBooks.filter {
            $0.mediaType == .audiobook && storage.isAudiobookDownloaded($0, downloadedIds: downloadedIds)
        }
        var seen = Set<String>()
        return Array(
            (ebooks + audiobooks)
                .sorted { $0.lastUpdate > $1.lastUpdate }
                .filter { seen.insert($0.stableId).inserted }
                .prefix(limit)
        )
    }

    private func deduplicatedHomeBooks(
        _ books: [Book],
        dismissedStableIds: Set<String>,
        currentStableId: String?
    ) -> [Book] {
        var seen = Set<String>()
        var results: [Book] = []
        for book in books {
            guard !dismissedStableIds.contains(book.stableId) || book.stableId == currentStableId else { continue }
            if seen.insert(book.stableId).inserted {
                results.append(book)
            }
        }
        return results
    }

    func workSlices() async -> [WorkSlice] {
        await appState.bookStore.workSlices()
    }

    func workIndex() async -> LibraryWorkIndexSnapshot {
        let index = WorkGrouping.index(await workSlices())
        return LibraryWorkIndexSnapshot(
            hiddenUniqueIds: index.hiddenUniqueIds,
            representativeWorkKey: index.representativeWorkKey,
            representativeCount: index.representativeCount
        )
    }

    func workView(workKey key: String) async -> WorkView? {
        let overrides = (profileSession?.workOverrides ?? WorkOverrideStore.shared)
        var members = await appState.bookStore.books(workKey: key)
        for id in overrides.stableIdsMerged(into: key) {
            if let extra = await appState.bookStore.book(stableId: id) {
                members.append(extra)
            }
        }

        var seen = Set<String>()
        let resolved = members.filter { member in
            guard seen.insert(member.uniqueId).inserted else { return false }
            return overrides.effectiveWorkKey(stableId: member.stableId, computed: WorkIdentity.workKey(for: member)) == key
        }
        return WorkGrouping.makeWorkView(workKey: key, members: resolved)
    }

    func splitWorkSource(stableId: String) {
        (profileSession?.workOverrides ?? WorkOverrideStore.shared).split(stableId: stableId)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func workMergeSuggestions(limit: Int) async -> [WorkMergeSuggestion] {
        let books = await appState.bookStore.booksWithIdentifiers(limit: limit)
        return WorkSuggestions.identifierSuggestions(from: books)
    }

    func confirmWorkMergeSuggestion(_ suggestion: WorkMergeSuggestion) {
        (profileSession?.workOverrides ?? WorkOverrideStore.shared).merge(stableIds: suggestion.stableIds, intoComputedWorkKey: suggestion.targetWorkKey)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func dismissWorkMergeSuggestion(_ suggestion: WorkMergeSuggestion) {
        (profileSession?.workOverrides ?? WorkOverrideStore.shared).dismissSuggestion(id: suggestion.id)
    }

    func seriesAggregates(mediaScope: [String], providerId: UUID? = nil, libraryId: String? = nil) async -> [BrowseSeriesAggregate] {
        var bucket: [String: BrowseSeriesAggregate] = [:]
        for raw in mediaScope {
            let aggregates =
                if let providerId {
                    await appState.bookStore.browseSeriesAggregates(mediaType: raw, providerId: providerId, libraryId: libraryId)
                } else {
                    await appState.bookStore.browseSeriesAggregates(mediaType: raw)
                }
            for aggregate in aggregates {
                bucket[aggregate.id] = mergingSeriesAggregate(bucket[aggregate.id], with: aggregate)
            }
        }
        return bucket.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func seriesAggregates(from books: [Book]) -> [BrowseSeriesAggregate] {
        var groups: [String: (seed: BrowseSeriesAggregate, books: [Book])] = [:]
        for book in books {
            guard let seed = Self.seriesIdentity(for: book) else { continue }
            if groups[seed.id] == nil { groups[seed.id] = (seed, []) }
            groups[seed.id]?.books.append(book)
        }
        return groups.values.map { group in
            let seed = group.seed
            let unread = group.books.filter { !$0.isCompleted }
            let started = unread.filter { $0.progressPercentage > 0 }.max { $0.lastUpdate < $1.lastUpdate }
            let first = unread.min { lhs, rhs in
                let l = lhs.comicMetadata
                let r = rhs.comicMetadata
                if l?.section.sortOrder != r?.section.sortOrder { return (l?.section.sortOrder ?? 0) < (r?.section.sortOrder ?? 0) }
                if l?.volumeOrder != r?.volumeOrder { return (l?.volumeOrder ?? 0) < (r?.volumeOrder ?? 0) }
                if l?.issueOrder != r?.issueOrder { return (l?.issueOrder ?? 0) < (r?.issueOrder ?? 0) }
                if lhs.seriesSequence != rhs.seriesSequence { return BookSortKeys.seriesNumber(lhs.seriesSequence) < BookSortKeys.seriesNumber(rhs.seriesSequence) }
                return lhs.uniqueId < rhs.uniqueId
            }
            return BrowseSeriesAggregate(
                name: seed.name,
                bookCount: group.books.count,
                completedBookCount: group.books.count - unread.count,
                representativeThumb: group.books.first(where: { $0.thumb != nil })?.thumb,
                matchingNames: Array(Set(group.books.compactMap(\.series))).sorted(),
                isComic: seed.isComic, providerId: seed.providerId, libraryId: seed.libraryId,
                comicSeriesID: seed.comicSeriesID, resumeBookUniqueID: (started ?? first)?.uniqueId,
                resumeBookLastUpdate: (started ?? first)?.lastUpdate,
                sections: ComicSection.allCases.compactMap { section in
                    let count = group.books.count { $0.isComic && ($0.comicMetadata?.section ?? .issues) == section }
                    return count > 0 ? ComicSeriesSectionSummary(section: section, count: count) : nil
                },
                volumes: ComicVolumeSummary.grouped(group.books.compactMap(\.comicMetadata)),
                standaloneBookUniqueID: seed.standaloneBookUniqueID
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func mergingSeriesAggregate(_ previous: BrowseSeriesAggregate?, with next: BrowseSeriesAggregate) -> BrowseSeriesAggregate {
        guard let previous else { return next }
        return BrowseSeriesAggregate(
            name: previous.name,
            bookCount: previous.bookCount + next.bookCount,
            completedBookCount: previous.completedBookCount + next.completedBookCount,
            representativeThumb: previous.representativeThumb ?? next.representativeThumb,
            matchingNames: Array(Set(previous.matchingNames + next.matchingNames)).sorted(),
            isComic: previous.isComic, providerId: previous.providerId, libraryId: previous.libraryId,
            comicSeriesID: previous.comicSeriesID,
            resumeBookUniqueID: previous.resumeBookUniqueID ?? next.resumeBookUniqueID,
            resumeBookLastUpdate: previous.resumeBookUniqueID == nil ? next.resumeBookLastUpdate : previous.resumeBookLastUpdate,
            sections: ComicSection.allCases.compactMap { section in
                let count = (previous.sections + next.sections).filter { $0.section == section }.reduce(0) { $0 + $1.count }
                return count > 0 ? ComicSeriesSectionSummary(section: section, count: count) : nil
            },
            volumes: previous.volumes + next.volumes,
            standaloneBookUniqueID: previous.standaloneBookUniqueID
        )
    }

    func genreAggregates(mediaScope: [String]) async -> [BrowseGenreAggregate] {
        struct Acc {
            var name: String
            var count = 0
            var matchingGenres = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for raw in mediaScope {
            for slice in await appState.bookStore.browseSlices(mediaType: raw) {
                for genre in normalizedGenres(slice.genres) {
                    let key = genreLookupKey(genre)
                    var acc = bucket[key] ?? Acc(name: genre)
                    acc.count += 1
                    acc.matchingGenres.insert(genre)
                    bucket[key] = acc
                }
            }
        }
        return bucket.values
            .map {
                BrowseGenreAggregate(
                    name: $0.name,
                    bookCount: $0.count,
                    matchingGenres: $0.matchingGenres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func genreAggregates(from books: [Book]) -> [BrowseGenreAggregate] {
        struct Acc {
            var name: String
            var count = 0
            var matchingGenres = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for book in books {
            for genre in normalizedGenres(book.genres) {
                let key = genreLookupKey(genre)
                var acc = bucket[key] ?? Acc(name: genre)
                acc.count += 1
                acc.matchingGenres.insert(genre)
                bucket[key] = acc
            }
        }
        return bucket.values
            .map {
                BrowseGenreAggregate(
                    name: $0.name,
                    bookCount: $0.count,
                    matchingGenres: $0.matchingGenres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func authorAggregates(mediaScope: [String]) async -> [BrowseAuthorAggregate] {
        var aggregatesByMedia: [[BrowseAuthorAggregate]] = []
        for raw in mediaScope {
            guard !Task.isCancelled else { return [] }
            aggregatesByMedia.append(await appState.bookStore.browseAuthorAggregates(mediaType: raw))
        }
        let merge = Task.detached(priority: .userInitiated) { [aggregatesByMedia] in
            Self.mergedAuthorAggregates(aggregatesByMedia)
        }
        return await withTaskCancellationHandler {
            await merge.value
        } onCancel: {
            merge.cancel()
        }
    }

    nonisolated static func mergedAuthorAggregates(_ aggregatesByMedia: [[BrowseAuthorAggregate]]) -> [BrowseAuthorAggregate] {
        struct Acc {
            var count = 0
            var thumb: String?
            var bookUniqueID: String
            var matchingNames = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for aggregates in aggregatesByMedia {
            guard !Task.isCancelled else { return [] }
            for aggregate in aggregates {
                var acc = bucket[aggregate.name]
                    ?? Acc(thumb: aggregate.representativeThumb, bookUniqueID: aggregate.representativeBookUniqueID)
                acc.count += aggregate.bookCount
                if acc.thumb == nil, let thumb = aggregate.representativeThumb {
                    acc.thumb = thumb
                    acc.bookUniqueID = aggregate.representativeBookUniqueID
                }
                acc.matchingNames.formUnion(aggregate.matchingNames)
                bucket[aggregate.name] = acc
            }
        }
        guard !Task.isCancelled else { return [] }

        return
            bucket
            .map {
                BrowseAuthorAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    representativeThumb: $0.value.thumb,
                    representativeBookUniqueID: $0.value.bookUniqueID,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted(by: authorOrder)
    }

    func authorAggregates(from books: [Book]) -> [BrowseAuthorAggregate] {
        let namesByBook = books.map { book in
            (book, normalizedAuthorNames(for: book))
        }
        let canonicalMap = NameNormalizer.buildCanonicalMap(from: namesByBook.flatMap(\.1))

        struct Acc {
            var count = 0
            var thumb: String?
            var bookUniqueID: String
            var matchingNames = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for (book, authors) in namesByBook where !authors.isEmpty {
            let rawLookupName = book.author?.trimmingCharacters(in: .whitespacesAndNewlines)
            let thumb = book.thumb?.isEmpty == false ? book.thumb : nil
            for author in Set(authors) {
                let displayName = NameNormalizer.canonicalName(for: author, using: canonicalMap)
                var acc = bucket[displayName] ?? Acc(thumb: thumb, bookUniqueID: book.uniqueId)
                acc.count += 1
                if let rawLookupName, !rawLookupName.isEmpty { acc.matchingNames.insert(rawLookupName) }
                acc.matchingNames.insert(author)
                if acc.thumb == nil, let thumb {
                    acc.thumb = thumb
                    acc.bookUniqueID = book.uniqueId
                }
                bucket[displayName] = acc
            }
        }

        return
            bucket
            .map {
                BrowseAuthorAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    representativeThumb: $0.value.thumb,
                    representativeBookUniqueID: $0.value.bookUniqueID,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted(by: Self.authorOrder)
    }

    private nonisolated static func authorOrder(_ lhs: BrowseAuthorAggregate, _ rhs: BrowseAuthorAggregate) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.name < rhs.name
        }
    }

    func narratorAggregates(mediaScope: [String]) async -> [BrowseNarratorAggregate] {
        var bucket: [String: (count: Int, thumb: String?)] = [:]
        for raw in mediaScope {
            for aggregate in await appState.bookStore.browseNarratorAggregates(mediaType: raw) {
                var entry = bucket[aggregate.name] ?? (0, nil)
                entry.count += aggregate.bookCount
                if entry.thumb == nil { entry.thumb = aggregate.representativeThumb }
                bucket[aggregate.name] = entry
            }
        }
        return
            bucket
            .map { BrowseNarratorAggregate(name: $0.key, bookCount: $0.value.count, representativeThumb: $0.value.thumb) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func narratorAggregates(from books: [Book]) -> [BrowseNarratorAggregate] {
        struct Acc {
            var count = 0
            var thumb: String?
        }

        var bucket: [String: Acc] = [:]
        for book in books {
            guard let raw = book.narrator?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            var acc = bucket[raw, default: Acc()]
            acc.count += 1
            if acc.thumb == nil { acc.thumb = book.thumb }
            bucket[raw] = acc
        }

        return
            bucket
            .map { BrowseNarratorAggregate(name: $0.key, bookCount: $0.value.count, representativeThumb: $0.value.thumb) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func normalizedAuthorNames(for book: Book) -> [String] {
        let explicit = book.authors ?? []
        let names = explicit.isEmpty ? (book.author ?? "").split(separator: ",").map(String.init) : explicit
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
    }

    private nonisolated func normalizedGenres(_ genres: [String]?) -> [String] {
        var seen = Set<String>()
        return (genres ?? []).compactMap {
            let genre = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !genre.isEmpty, seen.insert(genreLookupKey(genre)).inserted else { return nil }
            return genre
        }
    }

    private nonisolated func genreLookupKey(_ genre: String) -> String {
        genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func seriesFan(for aggregate: BrowseSeriesAggregate, mediaScope: [String]) async -> [Book] {
        await seriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: 0, limit: 3)
    }

    func books(forSeries aggregate: BrowseSeriesAggregate, mediaScope: [String]) async -> [Book] {
        var books: [Book] = []
        while !Task.isCancelled {
            let page = await seriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: books.count, limit: 200)
            books += page
            if page.count < 200 { break }
        }
        return books
    }

    func books(forGenre aggregate: BrowseGenreAggregate, mediaScope: [String]) async -> [Book] {
        let matchingKeys = Set(aggregate.matchingGenres.map { genreLookupKey($0) })
        var ids: [String] = []
        var seenIds = Set<String>()

        for raw in mediaScope {
            let slices = await appState.bookStore.browseSlices(mediaType: raw)
            for slice in slices where normalizedGenres(slice.genres).contains(where: { matchingKeys.contains(genreLookupKey($0)) }) {
                if seenIds.insert(slice.id).inserted {
                    ids.append(slice.id)
                    if ids.count == 500 { break }
                }
            }
            if ids.count == 500 { break }
        }

        return await appState.bookStore.books(withIds: ids)
            .filter { normalizedGenres($0.genres).contains(where: { matchingKeys.contains(genreLookupKey($0)) }) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func coverBook(forAuthor aggregate: BrowseAuthorAggregate, mediaScope: [String]) async -> Book? {
        let id = aggregate.representativeBookUniqueID
        let book: Book?
        if let cached = appState.bookInMemory(uniqueId: id) {
            book = cached
        } else {
            book = await appState.bookStore.book(uniqueId: id)
        }
        guard let book, mediaScope.contains(book.mediaType.rawValue) else { return nil }
        return book
    }

    func books(forAuthor aggregate: BrowseAuthorAggregate, mediaScope: [String]) async -> [Book] {
        var collected: [Book] = []
        var seen = Set<String>()
        for raw in mediaScope {
            let page = await appState.bookStore.books(byAuthorNames: aggregate.matchingNames, mediaType: raw, limit: 400)
            collected += page.filter { seen.insert($0.uniqueId).inserted }
        }
        return collected
    }

    func coverBook(forNarrator aggregate: BrowseNarratorAggregate, mediaScope: [String]) async -> Book? {
        for raw in mediaScope {
            if let first = await appState.bookStore.books(
                byNarrator: aggregate.name,
                mediaType: raw,
                limit: 1
            ).first {
                return first
            }
        }
        return nil
    }

    func books(forNarrator aggregate: BrowseNarratorAggregate, mediaScope: [String]) async -> [Book] {
        var collected: [Book] = []
        var seen = Set<String>()
        for raw in mediaScope {
            let page = await appState.bookStore.books(byNarrator: aggregate.name, mediaType: raw, limit: 400)
            collected += page.filter { seen.insert($0.uniqueId).inserted }
        }
        return collected
    }

    private func workSummary(for book: Book) async -> LibraryWorkSummary? {
        let key = WorkIdentity.workKey(for: book)
        guard !key.isEmpty else { return nil }

        guard let view = await workView(workKey: key), view.isConsolidated else {
            return nil
        }
        return LibraryWorkSummary(key: key, editions: view.editionCount, sources: view.sourceCount)
    }
}
