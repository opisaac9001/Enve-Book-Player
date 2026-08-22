import Combine
import CryptoKit
import Logging
import Network
import SwiftUI

@Observable
@MainActor
public class AppState {
    public static let shared = AppState()

    let presentation = AppPresentationState()
    let providerConnections = ProviderConnectionStore()

    private var catalog: LibraryCatalogCoordinator { .shared }
    private var progress: UserProgressStore { .shared }
    private var recovery: LibraryRecoveryCoordinator { .shared }

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "NetworkMonitor")
    private var networkWasEverUnsatisfied = false
    var currentBook: Book? {
        didSet {
            if let old = oldValue?.uniqueId { hotCache.unpin(uniqueId: old) }
            if let new = currentBook {
                hotCache.insert(new)
                hotCache.pin(uniqueId: new.uniqueId)
            }
        }
    }

    private var hasScheduledReadAloudLibrarySync = false
    @ObservationIgnored let libraryCache = LibraryBookCache()
    private var memoryDiagTimer: Timer?

    let bookStore: BookStoreRepository = BookStoreManager.shared.repository

    var hotCache: BookHotCache { libraryCache.hot }

    @discardableResult
    func mutateBook(uniqueId: String, _ transform: (inout Book) -> Void) -> Book? {
        libraryCache.mutateBook(uniqueId: uniqueId, transform)
    }

    @discardableResult
    func mutateBook(stableId: String, _ transform: (inout Book) -> Void) -> Book? {
        libraryCache.mutateBook(stableId: stableId, transform)
    }

    @discardableResult
    func mutateBooks(_ updates: [(uniqueId: String, transform: (inout Book) -> Void)]) -> [Book] {
        libraryCache.mutateBooks(updates)
    }

    @discardableResult
    func mutateBooksByStableId(_ updates: [(stableId: String, transform: (inout Book) -> Void)]) -> [Book] {
        libraryCache.mutateBooksByStableId(updates)
    }

    func performAllBooksBatch(_ body: () -> Void) {
        libraryCache.performBatch(body)
    }

    func withAllBooksTransaction(_ body: () async -> Void) async {
        await libraryCache.performTransaction(body)
    }

    func currentStableIdIndex() -> [String: Int] {
        libraryCache.currentStableIdIndex()
    }

    func indexInMemory(uniqueId: String) -> Int? { libraryCache.indexInMemory(uniqueId: uniqueId) }
    func indexInMemory(stableId: String) -> Int? { libraryCache.indexInMemory(stableId: stableId) }

    func bookInMemory(uniqueId: String) -> Book? { libraryCache.bookInMemory(uniqueId: uniqueId) }
    func bookInMemory(stableId: String) -> Book? { libraryCache.bookInMemory(stableId: stableId) }

    var allBooks: [Book] {
        get { libraryCache.books }
        set { libraryCache.books = newValue }
    }

    var allBooksChanged: PassthroughSubject<Void, Never> { libraryCache.changes }

    private var cancellables = Set<AnyCancellable>()

    private var startupCacheLoaded = false
    var isStartupCacheLoaded: Bool { startupCacheLoaded }

    private var bootstrapComplete = false
    var isBootstrapComplete: Bool { bootstrapComplete }

    init() {
        libraryCache.session = self
        allBooksChanged
            .sink { _ in BookStoreChangeNotifier.notify() }
            .store(in: &cancellables)

        providerConnections.configurationDidChange = {
            LibraryRecoveryCoordinator.shared.pruneDisconnectedProviderData()
        }

        Task {
            await self.migrateJellyfinEmbyConnectionTypesIfNeeded()
            await self.migrateTokensFromOldBackends()
        }

        UserCollectionStore.shared.refresh()

        setupNetworkMonitor()

        SmartCollectionStore.shared.refresh()

        NotificationCenter.default.addObserver(forName: .metadataUpdated, object: nil, queue: .main) { [weak self] notification in
            guard let self, let bookId = notification.object as? String else { return }
            Task { @MainActor in
                await self.refreshBookAfterMetadataUpdate(bookId: bookId)
            }
        }

        Task {
            MetadataStorage.shared.recoverMisplacedMetadataDirectory()

            libraryCache.suppressNotifications = true

            let startupBegin = Date()
            await loadCachedBooks()
            AppLogger.general.info(
                "📊 [Startup] loadCachedBooks done: \(self.allBooks.count) books, elapsed=\(String(format: "%.1f", Date().timeIntervalSince(startupBegin)))s"
            )

            await progress.migrateLegacyProgressFileIfNeeded()
            await recovery.runStartupMigrations()

            libraryCache.suppressNotifications = false
            self.startupCacheLoaded = true
            if !self.allBooks.isEmpty {
                self.allBooksChanged.send(())
            }
            await Task.yield()

            libraryCache.suppressNotifications = true
            self.recovery.pruneStaleBooksCacheEarly()
            await Task.yield()

            let hasCache = await catalog.loadCachedMetadata()
            await Task.yield()

            let needsLegacyImport = BookStoreManager.shared.needsLegacyImport
            if needsLegacyImport && !self.allBooks.isEmpty {
                await BookStoreManager.shared.runLegacyImportIfNeeded(
                    allBooks: self.allBooks,
                    hiddenStableIds: [],
                    deletedStableIds: DeletedBooksTombstoneStore.shared.allDeleted
                )
            }

            await ReaderArtifactsStore.shared.migrateToBookStoreIfNeeded(bookStore: self.bookStore)

            let hasLocalBooks = self.allBooks.contains { $0.source == .local }
            if !hasCache || !hasLocalBooks {
                await catalog.refreshLocalLibraries()
            }

            await EbookLinkStore.shared.reapplyLinks()
            await Task.yield()

            if needsLegacyImport {
                let links = self.allBooks
                    .filter { $0.mediaType == .ebook && $0.linkedAudiobookStableId != nil && !$0.linkedAudiobookStableId!.isEmpty }
                    .map {
                        (
                            ebookStableId: $0.stableId, audiobookStableId: $0.linkedAudiobookStableId!,
                            chapterOffset: $0.linkedAudiobookChapterOffset
                        )
                    }
                if !links.isEmpty {
                    await self.bookStore.importLegacyLinks(links)
                }
                let progressEntries = self.progress.allProgress.map {
                    (
                        bookUniqueId: $0.uniqueId, stableId: $0.libraryItemId,
                        currentTime: $0.currentTime, duration: $0.duration,
                        isFinished: $0.isFinished, lastUpdate: $0.lastUpdate
                    )
                }
                if !progressEntries.isEmpty {
                    await self.bookStore.importLegacyProgress(progressEntries)
                }
                let bookSnapshotsForImport = self.allBooks.map { (stableId: $0.stableId, id: $0.id, isEbook: $0.mediaType == .ebook) }
                let bookStoreRef = self.bookStore
                Task.detached(priority: .utility) {
                    for book in bookSnapshotsForImport {
                        let (bookmarks, annotations) = await MainActor.run {
                            let bm =
                                ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
                                + (book.stableId != book.id ? ReaderArtifactsStore.shared.loadBookmarks(bookId: book.id) : [])
                            let ann: [ReaderAnnotation] =
                                book.isEbook
                                ? ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
                                    + (book.stableId != book.id ? ReaderArtifactsStore.shared.loadAnnotations(bookId: book.id) : [])
                                : []
                            return (bm, ann)
                        }
                        if !bookmarks.isEmpty {
                            await bookStoreRef.importLegacyBookmarks(bookmarks, bookStableId: book.stableId)
                        }
                        if !annotations.isEmpty {
                            await bookStoreRef.importLegacyAnnotations(annotations, bookStableId: book.stableId)
                        }
                    }
                }
            }

            libraryCache.suppressNotifications = false
            if !self.allBooks.isEmpty {
                self.allBooksChanged.send(())
            }

            self.recovery.pruneDisconnectedProviderData()

            self.bootstrapComplete = true

            await self.catalog.resumeStartupCatalogWork()

            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self.reEnrichCachedBooksIfNeeded()
            }

            AppLogger.general.info(
                "📊 [Startup] Complete: \(self.allBooks.count) books in memory, elapsed=\(String(format: "%.1f", Date().timeIntervalSince(startupBegin)))s"
            )

            let store = self.bookStore
            Task.detached(priority: .background) {
                let counts = await store.bookCountsBySource()
                let total = counts.reduce(0) { $0 + $1.count }
                AppLogger.general.info(
                    "📊 [bookStore] \(total) total cached books - by source: \(counts.map { "\($0.source)=\($0.count)" }.joined(separator: ", "))"
                )
                if let plex = counts.first(where: { $0.source == "plex" }), plex.count > 1000 {
                    let sections = await store.bookCountsBySection(source: "plex")
                    for s in sections.prefix(10) {
                        AppLogger.general.info(
                            "📊 [bookStore] plex section provider=\(s.providerId.prefix(8)) library=\(s.libraryId): \(s.count) books"
                        )
                    }
                }
            }

            self.recovery.flushPendingBookStoreDeletions(delaySeconds: 25)

            let validProviderIds: Set<String> = Set(
                self.providerConnections.connections
                    .filter { !$0.isArchived }
                    .map { $0.id.uuidString }
            )
            Task(priority: .background) {
                let removed = await store.deleteBooksFromUnknownProviders(validProviderIds: validProviderIds)
                if removed > 0 {
                    AppLogger.general.info("📊 [BookStore] Purged \(removed) orphan books from disconnected providers")
                }
            }

            self.startMemoryDiagnostics()

            await recovery.rescueOrphanedDownloads()
            self.scheduleReadAloudLibrarySyncIfNeeded()

            Task(priority: .utility) {

                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if PlatformRuntime.cloudKitEnabled {
                    _ = await SyncCoordinator.shared.runRecentlyPlayedSync(trigger: .appLaunch)
                }
                await self.catalog.refreshStaleServerMirrorDomains()
            }
        }
    }

    nonisolated static func currentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }

    private func startMemoryDiagnostics() {
        memoryDiagTimer?.invalidate()
        memoryDiagTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mem = Self.currentMemoryMB()
                AppLogger.general.debug("📊 [MEM] \(mem)MB | allBooks=\(self.allBooks.count) | mutations=\(self.libraryCache.mutationCount)")
            }
        }
    }

    private func scheduleReadAloudLibrarySyncIfNeeded() {
        guard #available(iOS 26.0, *) else { return }
        guard !hasScheduledReadAloudLibrarySync else { return }

        hasScheduledReadAloudLibrarySync = true

        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await StoryAlignService.shared.syncReadAloudLibraryOnLaunch()
        }
    }

    func validateConnection(_ connection: ServerConnection) async throws -> (Bool, ServerConnection) {
        var corrected = connection
        if corrected.type == .emby || corrected.type == .jellyfin {
            if let detected = await detectJellyfinEmbyType(serverURL: corrected.url), detected != corrected.type {
                AppLogger.general.info(
                    "[AppState] Correcting connection type \(corrected.name): \(String(describing: corrected.type)) -> \(String(describing: detected))"
                )
                corrected.type = detected
            }
        }

        guard let provider = ProviderFactory.create(for: corrected) else {
            throw ProviderError.notImplemented
        }

        let result = try await provider.validateConnection()
        return (result, provider.connection)
    }

    private struct PublicSystemInfo: Decodable {
        let ProductName: String?
        let ServerName: String?
    }

    private func detectJellyfinEmbyType(serverURL: String) async -> ProviderType? {
        let base = EmbyProvider.normalizeServerURL(serverURL)
        guard let url = URL(string: "\(base)/System/Info/Public") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            if let decoded = try? JSONDecoder().decode(PublicSystemInfo.self, from: data) {
                let product = (decoded.ProductName ?? "").lowercased()
                if product.contains("jellyfin") { return .jellyfin }
                if product.contains("emby") { return .emby }
            }

            if let text = String(data: data, encoding: .utf8)?.lowercased() {
                if text.contains("jellyfin") { return .jellyfin }
                if text.contains("emby") { return .emby }
            }
        } catch {
            return nil
        }

        return nil
    }

    @MainActor
    private func migrateJellyfinEmbyConnectionTypesIfNeeded() async {
        guard !providerConnections.connections.isEmpty else { return }

        var updated = providerConnections.connections
        var didChange = false

        for index in updated.indices {
            let type = updated[index].type
            guard type == .emby || type == .jellyfin else { continue }

            if let detected = await detectJellyfinEmbyType(serverURL: updated[index].url), detected != type {
                AppLogger.general.info(
                    "[AppState] Migrating saved connection type for \(updated[index].name): \(String(describing: type)) -> \(String(describing: detected))"
                )
                updated[index].type = detected
                didChange = true
            }
        }

        if didChange {
            providerConnections.connections = updated
        }
    }

    func ensureBookInMemory(_ book: Book) {
        libraryCache.ensureBookInMemory(book)
    }

    func persistStartupCachesImmediately() {

        catalog.saveMetadata(immediate: true)
        progress.persist(immediate: true)
    }

    @MainActor
    private func loadCachedBooks() async {
        let totalCount = await bookStore.bookCount()
        guard totalCount > 0 else {
            AppLogger.general.info("[AppState] No indexed books in BookStore at startup; waiting for source refresh")
            return
        }

        let firstPage = await bookStore.pagedBooks(offset: 0, limit: 2000, mediaType: nil)
        guard !firstPage.isEmpty else { return }
        libraryCache.load(firstPage)
        AppLogger.general.info(
            "[AppState] Loaded \(firstPage.count) of \(totalCount) cached books into in-memory mirror; remaining served via paged bookStore queries"
        )
    }

    private func reEnrichCachedBooksIfNeeded() async {
        let books = await MainActor.run { self.allBooks }
        guard !books.isEmpty else { return }

        let storedIds = await MetadataStorage.shared.bookIdsWithStoredMetadata()
        guard !storedIds.isEmpty else {
            AppLogger.general.warning("[AppState] No stored metadata files found - skipping startup re-enrichment")
            return
        }

        let booksToEnrich = books.filter { storedIds.contains($0.id) }
        guard !booksToEnrich.isEmpty else {
            AppLogger.general.warning("[AppState] No cached books have stored metadata - skipping startup re-enrichment")
            return
        }

        AppLogger.general.info("[AppState] Re-enriching \(booksToEnrich.count) book(s) with stored metadata on startup...")
        let enrichedSubset = await MetadataManager.shared.enrichBooksWithStoredMetadata(booksToEnrich)

        let enrichedById: [String: Book] = Dictionary(enrichedSubset.map { ($0.uniqueId, $0) }, uniquingKeysWith: { _, new in new })
        var changedCount = 0
        await MainActor.run {
            let merged = self.allBooks.map { book -> Book in
                guard let enriched = enrichedById[book.uniqueId] else { return book }
                let changed =
                    enriched.title != book.title || enriched.author != book.author || enriched.narrator != book.narrator
                    || enriched.series != book.series || enriched.thumb != book.thumb || enriched.description != book.description
                if changed { changedCount += 1 }
                return enriched
            }
            if changedCount > 0 {
                self.allBooks = merged
                AppLogger.general.info("[AppState] Re-enriched \(changedCount) book(s) with stored metadata layers on startup")
            } else {
                AppLogger.general.info("[AppState] All cached books already up-to-date with metadata layers")
            }
        }
        if changedCount > 0 {
            let changed = Array(enrichedById.values)
            let store = bookStore
            Task(priority: .utility) { await store.upsertBooks(changed) }
        }
    }

    private func setupNetworkMonitor() {
        NotificationCenter.default.addObserver(
            forName: .localLibraryUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.catalog.refreshLocalLibraries()
            }
        }

        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status != .satisfied {
                    self.networkWasEverUnsatisfied = true
                } else if self.networkWasEverUnsatisfied {
                    AppLogger.general.info("Network connection restored, retrying syncs...")
                    await self.progress.retryPendingSyncs()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    @MainActor func updateBookWithMetadata(_ updatedBook: Book) {
        if libraryCache.replaceExisting(updatedBook) {
            AppLogger.general.debug(
                "Updated library cache bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: updatedBook.stableId))"
            )
        } else {
            AppLogger.general.warning(
                "Book not found in library cache bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: updatedBook.stableId))"
            )
        }

        catalog.saveMetadata()
        let b = updatedBook
        let store = bookStore
        Task(priority: .utility) { await store.upsertBooks([b]) }
    }

    @MainActor func refreshBookAfterMetadataUpdate(bookId: String) async {
        guard
            let book = allBooks.first(where: {
                $0.id == bookId || $0.stableId == bookId || $0.uniqueId == bookId
            })
        else {
            AppLogger.general.warning(
                "Book not found for metadata refresh bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookId))"
            )
            return
        }

        let enrichedBook = await MetadataManager.shared.enrichBookWithStoredMetadata(book)

        updateBookWithMetadata(enrichedBook)

        if currentBook?.id == bookId {
            currentBook = enrichedBook
        }
    }

    func getProvider(_ providerId: UUID) -> LibraryProvider? {
        return providerConnections[providerId]
    }

    @MainActor
    func opdsConnection(for url: URL) -> ServerConnection? {
        let urlString = url.absoluteString
        return providerConnections.connections.first {
            $0.type == .opds && !$0.isArchived && !$0.url.isEmpty && urlString.hasPrefix($0.url)
        }
    }

    func migrateTokensFromOldBackends() async {
        AppLogger.general.info("Starting token migration from old backends...")

        let oldBackends = ServerConfigStore.shared.loadBackends()
        var needsSave = false

        await MainActor.run {
            for backend in oldBackends {
                if let index = providerConnections.connections.firstIndex(where: { $0.id.uuidString == backend.id }) {
                    var connection = providerConnections.connections[index]

                    let oldToken = connection.token ?? ""
                    let newToken = backend.token ?? ""

                    if oldToken != newToken, !newToken.isEmpty {
                        AppLogger.general.info("Migrating token for \(connection.name)")

                        connection.token = newToken
                        providerConnections.connections[index] = connection
                        needsSave = true
                    }
                }
            }

            if !needsSave {
                AppLogger.general.info("No token migration needed")
            }
        }
    }
}

extension AppState: CurrentBookSession {}

extension AppState: LibraryStartupGating {}
