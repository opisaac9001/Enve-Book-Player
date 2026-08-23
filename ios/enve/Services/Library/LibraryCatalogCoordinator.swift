import Combine
import Foundation
import Logging

@MainActor
@Observable
final class LibraryCatalogCoordinator {
    static let shared = LibraryCatalogCoordinator()

    var libraries: [Library] = []
    var collections: [Collection] = []
    var series: [Series] = []

    var isRefreshing = false
    var forceNextLocalRefresh = false

    private let library: LibraryBookCache
    private let session: any CurrentBookSession
    private let presentation: AppPresentationState
    private let bookStore: BookStoreRepository
    private let providerConnections: any ProviderConnectionResolving
    private let progress: UserProgressStore
    private let mirrorCheckpoints: ServerMirrorCheckpointStore

    private var isFullRefreshInProgress = false
    private var hasPerformedInitialCloudSync = false
    private var metadataSaveTask: Task<Void, Never>?
    private let metadataFileURL: URL?

    private static let startupMirrorRefreshInterval: TimeInterval = 15 * 60
    private static let fullCatalogReconciliationInterval: TimeInterval = 7 * 24 * 3600
    private static let startupRecentBooksPerLibrary = 12

    init(
        library: LibraryBookCache = AppState.shared.libraryCache,
        session: any CurrentBookSession = AppState.shared,
        presentation: AppPresentationState = AppState.shared.presentation,
        bookStore: BookStoreRepository = AppState.shared.bookStore,
        providerConnections: any ProviderConnectionResolving = AppState.shared.providerConnections,
        progress: UserProgressStore = .shared,
        mirrorCheckpoints: ServerMirrorCheckpointStore = .shared,
        metadataFileURL: URL? = nil
    ) {
        self.library = library
        self.session = session
        self.presentation = presentation
        self.bookStore = bookStore
        self.providerConnections = providerConnections
        self.progress = progress
        self.mirrorCheckpoints = mirrorCheckpoints
        self.metadataFileURL = metadataFileURL ?? Self.defaultMetadataFileURL()
    }

    private func performInitialCloudSyncIfNeeded() {
        guard PlatformRuntime.cloudKitEnabled else { return }
        guard !hasPerformedInitialCloudSync else { return }
        guard !library.books.isEmpty else { return }

        hasPerformedInitialCloudSync = true
        let launchSyncDelayNanoseconds: UInt64 = 5_000_000_000
        let launchSyncBookLimit = 1200
        let launchSyncBooks = prioritizedBooksForInitialCloudSync(from: library.books, limit: launchSyncBookLimit)

        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: launchSyncDelayNanoseconds)
            await SyncCoordinator.shared.syncOnAppLaunch(books: launchSyncBooks)
        }
    }

    private func prioritizedBooksForInitialCloudSync(from books: [Book], limit: Int) -> [Book] {
        guard books.count > limit else { return books }

        let sorted = books.sorted { lhs, rhs in
            let lhsScore = (lhs.currentTime > 0 ? 2 : 0) + (lhs.lastUpdate == .distantPast ? 0 : 1)
            let rhsScore = (rhs.currentTime > 0 ? 2 : 0) + (rhs.lastUpdate == .distantPast ? 0 : 1)

            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            return lhs.lastUpdate > rhs.lastUpdate
        }

        return Array(sorted.prefix(limit))
    }

    func refreshLibrary(forceFullReconciliation: Bool = false) async {
        guard !isFullRefreshInProgress else {
            AppLogger.general.warning("Refresh already in progress - skipping")
            return
        }

        let backgroundTask = BackgroundTaskAssertion.begin(name: "Library Refresh")
        defer { backgroundTask.end() }

        isFullRefreshInProgress = true
        defer { isFullRefreshInProgress = false }

        await MainActor.run {
            isRefreshing = true
            library.suppressNotifications = true
        }

        AppLogger.general.info("Starting library refresh. Providers: \(providerConnections.providerCount)")

        for (providerId, provider) in providerConnections.allProviders {
            await refreshProvider(
                provider,
                providerId: providerId,
                forceFullReconciliation: forceFullReconciliation
            )
            await MainActor.run {
                presentation.libraryImportProgress = nil
            }
        }

        await refreshLocalLibraries()

        await MainActor.run {
            library.suppressNotifications = false
            self.isRefreshing = false
            presentation.libraryImportProgress = nil
            SmartCollectionStore.shared.refresh()
            AppLogger.general.info("Refresh complete. Total books: \(library.books.count)")
            library.changes.send(())
            NotificationCenter.default.post(name: .collectionsDidChange, object: nil)
            NotificationCenter.default.post(name: .libraryDidFinishSync, object: nil)
        }

        await saveMetadataAsync()

        await EbookLinkStore.shared.reapplyLinks()

        if #available(iOS 26.0, *) {
            await MainActor.run { StoryAlignService.shared.syncReadAloudLibrary() }
        }

        await MainActor.run { _ = flushLocalBooksToCache() }

        performInitialCloudSyncIfNeeded()
    }

    func refreshServerCollections() async {
        for (providerId, provider) in providerConnections.allProviders where provider.capabilities.contains(.collections) {
            guard await CatalogRefreshGate.shared.begin(providerId: providerId) else {
                AppLogger.general.info("Coalesced duplicate collection refresh for \(provider.connection.name)")
                continue
            }

            let providerLibraries = libraries.filter { $0.providerId == providerId }
            await refreshProviderCollections(
                provider: provider,
                providerId: providerId,
                libraries: selectedLibraries(from: providerLibraries, for: provider)
            )
            CatalogRefreshGate.shared.end(providerId: providerId)
        }
    }

    func refreshLocalLibrariesFromUI() async {
        guard !isRefreshing else { return }

        await MainActor.run { isRefreshing = true }
        await refreshLocalLibraries()
        await MainActor.run {
            self.isRefreshing = false
            presentation.libraryImportProgress = nil
            library.changes.send(())
        }
    }

    @discardableResult
    func flushLocalBooksToCache() -> Task<Void, Never>? {
        let localBooks = library.books.filter { $0.source == .local }
        guard !localBooks.isEmpty else { return nil }
        let store = bookStore
        return Task.detached(priority: .utility) {
            await store.upsertBooks(localBooks)
        }
    }

    func refreshLocalLibraries() async {
        AppLogger.general.info("Refreshing local libraries...")

        let localLibraries = LocalLibraryStorageStore.shared.loadLibraries()
        let existingLocalBooks = await MainActor.run {
            library.books.filter { $0.source == .local }
        }

        let localProviderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        await MainActor.run {
            for localLib in localLibraries {
                if !self.libraries.contains(where: { $0.id == localLib.id }) {
                    let library = Library(
                        id: localLib.id,
                        name: localLib.name,
                        type: "local",
                        providerId: localProviderId
                    )
                    self.libraries.append(library)
                }
            }
        }

        var allLocalBooks: [Book] = []
        var libraryIdSet: Set<String> = []

        for localLib in localLibraries {
            libraryIdSet.insert(localLib.id)
            let libraryBooks = LocalLibraryStorageStore.shared.loadBooks(libraryId: localLib.id)
            AppLogger.general.info("Found \(libraryBooks.count) books for local library: \(localLib.name)")
            let books = libraryBooks.map { $0.toBook(libraryId: localLib.id) }

            if !books.isEmpty {
                let enriched = await MetadataManager.shared.enrichBooksWithStoredMetadata(books)
                let progressAdjusted = applyLocalProgressOverrides(
                    enriched,
                    preloadedStoredProgress: await preloadStoredProgressMap(for: enriched)
                )
                let existingForLibrary = existingLocalBooks.filter { $0.libraryId == localLib.id }
                let merged = applyLocalRelationshipOverrides(progressAdjusted, existingBooks: existingForLibrary)
                allLocalBooks.append(contentsOf: merged)
            }
        }

        let rebuiltStableIds = Set(allLocalBooks.map(\.stableId))
        let rebuiltPaths = Set(allLocalBooks.compactMap { resolvedLocalBookPath(for: $0) })
        let preservedLocalEbooks = existingLocalBooks.filter { book in
            guard book.mediaType == .ebook,
                libraryIdSet.contains(book.libraryId),
                localBookExistsOnDisk(book)
            else {
                return false
            }

            if let path = resolvedLocalBookPath(for: book) {
                let serverRoot = LocalEbookImporter.shared.serverEbooksRoot.standardizedFileURL.path
                let localRoot = LocalEbookImporter.shared.localEbooksRoot.standardizedFileURL.path
                if path.hasPrefix(serverRoot), !path.hasPrefix(localRoot) {
                    return false
                }
            }

            if rebuiltStableIds.contains(book.stableId) {
                return false
            }

            if let path = resolvedLocalBookPath(for: book), rebuiltPaths.contains(path) {
                return false
            }

            return true
        }
        if !preservedLocalEbooks.isEmpty {
            AppLogger.general.warning("Preserving \(preservedLocalEbooks.count) cached local ebook(s) missing from stored scan results")
            allLocalBooks.append(contentsOf: preservedLocalEbooks)
        }

        let rebuiltUniqueIds = Set(allLocalBooks.map(\.uniqueId))
        let removedLocalUniqueIds = Set(existingLocalBooks.map(\.uniqueId)).subtracting(rebuiltUniqueIds)

        let existingLocalStableIds = Set(existingLocalBooks.map(\.stableId))
        let rebuiltStableIdsForCompare = Set(allLocalBooks.map(\.stableId))
        let existingLocalMediaTypes = Dictionary(
            existingLocalBooks.map { ($0.stableId, $0.mediaType) },
            uniquingKeysWith: { _, new in new }
        )
        let rebuiltLocalMediaTypes = Dictionary(allLocalBooks.map { ($0.stableId, $0.mediaType) }, uniquingKeysWith: { _, new in new })
        let localLibrarySetUnchanged =
            existingLocalStableIds == rebuiltStableIdsForCompare
            && existingLocalBooks.count == allLocalBooks.count
            && existingLocalMediaTypes == rebuiltLocalMediaTypes

        if localLibrarySetUnchanged, !forceNextLocalRefresh {
            AppLogger.general.warning("Local libraries unchanged (\(allLocalBooks.count) books) - skipping cache write")
            await EbookLinkStore.shared.reapplyLinks()
            performInitialCloudSyncIfNeeded()
            return
        }
        forceNextLocalRefresh = false

        await MainActor.run {
            let beforeCount = library.books.count
            var updatedBooks = library.books.filter { !($0.source == .local && libraryIdSet.contains($0.libraryId)) }
            let removedCount = beforeCount - updatedBooks.count
            updatedBooks.append(contentsOf: allLocalBooks)
            library.books = updatedBooks
            LibraryRecoveryCoordinator.shared.pendingBookStoreDeletions.formUnion(removedLocalUniqueIds)
            AppLogger.general.info(
                "Batch updated local libraries: removed \(removedCount), added \(allLocalBooks.count) books. Total: \(library.books.count)"
            )
        }

        flushLocalBooksToCache()
        LibraryRecoveryCoordinator.shared.flushPendingBookStoreDeletions()

        await EbookLinkStore.shared.reapplyLinks()

        performInitialCloudSyncIfNeeded()
    }

    func resumeStartupCatalogWork() async {
        await resumeInterruptedGrimmoryCatalogSyncs()
        await refreshMissingRemoteCatalogIfNeeded()
    }

    private func refreshMissingRemoteCatalogIfNeeded() async {
        guard !isRefreshing, !isFullRefreshInProgress else { return }

        let targets = providerConnections.connections.filter {
            !$0.isArchived
                && providerConnections[$0.id] != nil
                && !$0.url.lowercased().contains("example.com")
                && !AuthenticationFailureStore.shared.isBlocked(connectionId: $0.id)
        }
        guard !targets.isEmpty else { return }

        var missingCatalogTargets: [ServerConnection] = []
        for connection in targets {
            let cachedCount = await bookStore.bookCount(providerId: connection.id, mediaType: nil)
            if cachedCount == 0 {
                missingCatalogTargets.append(connection)
            }
        }
        guard !missingCatalogTargets.isEmpty else { return }

        AppLogger.general.info("[Startup] Refreshing \(missingCatalogTargets.count) active source(s) with no cached catalog rows")
        for connection in missingCatalogTargets {
            await refreshConnectionLibraries(providerId: connection.id)
        }
    }

    private func resumeInterruptedGrimmoryCatalogSyncs() async {
        let pendingConnectionIds = BookloreProvider.pendingCatalogSyncConnectionIds
            .union(CatalogImportCheckpointStore.pendingConnectionIds)
        let targets = providerConnections.connections.filter {
            pendingConnectionIds.contains($0.id)
                && !$0.isArchived
                && providerConnections[$0.id] != nil
                && !AuthenticationFailureStore.shared.isBlocked(connectionId: $0.id)
        }
        guard !targets.isEmpty else { return }

        AppLogger.general.info("[Startup] Resuming \(targets.count) interrupted catalog sync(s)")
        for connection in targets {
            await refreshConnectionLibraries(
                providerId: connection.id,
                forceFullReconciliation: true,
                refreshCollections: false
            )
        }
    }

    func refreshStaleServerMirrorDomains() async {
        let mirrorConnections = providerConnections.connections.filter { connection in
            guard connection.isConnected,
                !connection.isArchived,
                providerConnections[connection.id] != nil
            else { return false }
            switch connection.type {
            case .booklore, .bookOrbit, .silo, .storyteller:
                return true
            default:
                return false
            }
        }
        guard !mirrorConnections.isEmpty else { return }

        let now = Date()
        for connection in mirrorConnections {
            guard let provider = providerConnections[connection.id],
                provider.capabilities.contains(.collections)
            else { continue }
            let scope = ServerMirrorScope(
                connectionId: connection.id,
                accountKey: ServerMirrorFingerprint.accountKey(for: connection),
                libraryId: nil,
                domain: .collections
            )
            guard
                mirrorCheckpoints.needsRefresh(
                    scope: scope,
                    after: Self.startupMirrorRefreshInterval,
                    now: now
                )
            else { continue }
            guard await CatalogRefreshGate.shared.begin(providerId: connection.id) else { continue }
            let providerLibraries = libraries.filter { $0.providerId == connection.id }
            await refreshProviderCollections(
                provider: provider,
                providerId: connection.id,
                libraries: selectedLibraries(from: providerLibraries, for: provider)
            )
            CatalogRefreshGate.shared.end(providerId: connection.id)
        }

        await refreshRecentCatalogWindows(for: mirrorConnections, now: now)

        for connection in mirrorConnections {
            guard await catalogNeedsReconciliation(for: connection, now: now) else { continue }
            AppLogger.general.info("[Startup] Reconciling stale catalog for \(connection.name)")
            await refreshConnectionLibraries(
                providerId: connection.id,
                refreshCollections: false
            )
        }
    }

    private func refreshRecentCatalogWindows(
        for inputConnections: [ServerConnection],
        now: Date
    ) async {
        for connection in inputConnections {
            guard connection.type != .storyteller else { continue }
            guard let provider = providerConnections[connection.id] else { continue }
            let scope = ServerMirrorScope(
                connectionId: connection.id,
                accountKey: ServerMirrorFingerprint.accountKey(for: connection),
                libraryId: nil,
                domain: .catalog
            )
            guard
                mirrorCheckpoints.needsRefresh(
                    scope: scope,
                    after: Self.startupMirrorRefreshInterval,
                    now: now
                )
            else { continue }
            guard await CatalogRefreshGate.shared.begin(providerId: connection.id) else { continue }

            do {
                defer { CatalogRefreshGate.shared.end(providerId: connection.id) }
                let fetchedLibraries = try await provider.fetchLibraries()
                let targets = selectedLibraries(from: fetchedLibraries, for: provider)
                guard !targets.isEmpty else { continue }

                for library in fetchedLibraries
                where !libraries.contains(where: {
                    $0.id == library.id && $0.providerId == library.providerId
                }) {
                    libraries.append(library)
                }

                var recentBooks: [Book] = []
                for library in targets {
                    let fetched = try await provider.fetchRecentBooks(
                        libraryId: library.id,
                        limit: Self.startupRecentBooksPerLibrary
                    )
                    let normalized = normalizeFetchedBooks(fetched, for: library, provider: provider)
                    let enriched = await MetadataManager.shared.enrichBooksWithStoredMetadata(normalized)
                    let progress = applyLocalProgressOverrides(
                        enriched,
                        preloadedStoredProgress: await preloadStoredProgressMap(for: enriched)
                    )
                    let existing = await bookStore.booksByAnyIds(Set(progress.map(\.uniqueId)))
                    recentBooks.append(
                        contentsOf: applyLocalRelationshipOverrides(
                            progress,
                            existingBooks: Array(existing.values)
                        )
                    )
                }

                var seen = Set<String>()
                let deduplicated = recentBooks.filter { seen.insert($0.uniqueId).inserted }
                if !deduplicated.isEmpty {
                    let deletedIds = DeletedBooksTombstoneStore.shared.allDeleted
                    library.performBatch {
                        var indices = Dictionary(
                            uniqueKeysWithValues: library.books.enumerated().map { ($0.element.uniqueId, $0.offset) }
                        )
                        for book in deduplicated where !deletedIds.contains(book.stableId) {
                            if let index = indices[book.uniqueId] {
                                library.books[index] = book
                            } else {
                                indices[book.uniqueId] = library.books.count
                                library.books.append(book)
                            }
                        }
                    }
                    await bookStore.upsertBooks(deduplicated)
                }

                mirrorCheckpoints.commit(
                    scope: scope,
                    syncLevel: .boundedWindow,
                    fingerprint: ServerMirrorFingerprint.catalogWindow(deduplicated),
                    itemCount: deduplicated.count
                )
                saveMetadata()
                AppLogger.general.info(
                    "[Startup] Refreshed bounded catalog window for \(connection.name): \(deduplicated.count) books"
                )
            } catch {
                providerConnections.markNeedsReauthentication(providerId: connection.id, error: error)
                AppLogger.general.error(
                    "[Startup] Bounded catalog refresh failed for \(connection.name): \(error.localizedDescription)"
                )
            }
        }
    }

    private func catalogNeedsReconciliation(
        for connection: ServerConnection,
        now: Date
    ) async -> Bool {
        guard let provider = providerConnections[connection.id] else { return false }
        let providerLibraries = libraries.filter { $0.providerId == connection.id }
        let targets = selectedLibraries(from: providerLibraries, for: provider)
        guard !targets.isEmpty else { return true }

        for library in targets {
            guard
                let cursor = await bookStore.loadCursor(
                    providerId: connection.id,
                    libraryId: library.id
                )
            else { return true }
            if now.timeIntervalSince(cursor.lastFullReconciledAt) >= Self.fullCatalogReconciliationInterval {
                return true
            }
        }
        return false
    }

    private func resolvedLocalBookPath(for book: Book) -> String? {
        if let filePath = book.filePath, !filePath.isEmpty {
            return filePath
        }
        return book.ebookFileURL?.path
    }

    private func localBookExistsOnDisk(_ book: Book) -> Bool {
        guard let path = resolvedLocalBookPath(for: book) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func normalizeCachedBookMediaType(_ book: Book) -> Book {
        var normalized = book

        if normalized.source == .local, normalized.readAloudSourceStableId == nil {
            let localProviderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            normalized.providerId = localProviderId

            if normalized.libraryId.isEmpty {
                normalized.libraryId = normalized.backendId ?? LocalLibraryService.fileSharingLibraryId
            }

            if normalized.libraryName?.isEmpty != false {
                normalized.libraryName = normalized.libraryId
            }

            if normalized.backendName?.isEmpty != false {
                normalized.backendName = "local"
            }
        }

        func ebookFormat(for path: String?) -> EbookFormat? {
            guard let path, !path.isEmpty else { return nil }
            return EbookFormat.from(fileExtension: URL(fileURLWithPath: path).pathExtension.lowercased())
        }

        let filePathFormat = ebookFormat(for: normalized.filePath)
        let ebookURLFormat = normalized.ebookFileURL.flatMap { EbookFormat.from(fileExtension: $0.pathExtension.lowercased()) }
        let partKeyFormat: EbookFormat? = {
            guard let partKey = normalized.partKey, !partKey.isEmpty else { return nil }
            if let url = URL(string: partKey), let ext = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased() {
                return EbookFormat.from(fileExtension: ext)
            }
            return EbookFormat.from(fileExtension: URL(fileURLWithPath: partKey).pathExtension.lowercased())
        }()

        let shouldForceEbook =
            normalized.source == .local && filePathFormat != nil
            || ebookURLFormat != nil
            || partKeyFormat != nil
            || normalized.source == .opds
            || normalized.source == .kavita

        guard shouldForceEbook, normalized.source != .storyteller else { return normalized }

        normalized.mediaType = .ebook
        normalized.currentTime = 0
        if normalized.ebookFileURL == nil,
            let path = normalized.filePath,
            filePathFormat != nil
        {
            normalized.ebookFileURL = URL(fileURLWithPath: path)
        }
        return normalized
    }

    private func normalizeFetchedBooks(_ books: [Book], for library: Library, provider: LibraryProvider) -> [Book] {
        guard !books.isEmpty else { return books }

        var normalized = books.map(normalizeCachedBookMediaType(_:))

        if provider.connection.type == .booklore, library.type == "ebook" {
            normalized = normalized.map { book in
                var updated = book
                updated.mediaType = .ebook
                updated.currentTime = 0
                return updated
            }
        }

        return normalized
    }

    func refreshLibrary(
        providerId: UUID,
        libraryId: String,
        forceFullReconciliation: Bool = false
    ) async {
        guard let provider = providerConnections[providerId] else {
            AppLogger.general.info(
                "[Sync] No provider found diagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString))"
            )
            return
        }

        guard await CatalogRefreshGate.shared.begin(providerId: providerId) else {
            AppLogger.general.info("Coalesced duplicate catalog refresh for \(provider.connection.name)")
            return
        }
        defer { CatalogRefreshGate.shared.end(providerId: providerId) }

        let backgroundTask = BackgroundTaskAssertion.begin(name: "Library Refresh")
        defer { backgroundTask.end() }

        await MainActor.run { isRefreshing = true }

        do {
            let libs = try await provider.fetchLibraries()
            await MainActor.run {
                for lib in libs where !self.libraries.contains(where: { $0.id == lib.id && $0.providerId == lib.providerId }) {
                    self.libraries.append(lib)
                }
                self.pruneMissingLibrariesForProvider(providerId: providerId, validLibraries: libs)
            }
            await purgeMissingLibraryBooks(providerId: providerId, validLibraries: libs)

            guard let lib = libs.first(where: { $0.id == libraryId }) else {
                AppLogger.general.info("[Sync] Library \(libraryId) not found on server")
                await MainActor.run {
                    self.isRefreshing = false; presentation.libraryImportProgress = nil; library.changes.send(())
                }
                return
            }

            await refreshSingleLibrary(
                lib,
                provider: provider,
                providerId: providerId,
                providerName: provider.connection.name,
                forceFullReconciliation: forceFullReconciliation
            )
            let collectionLibraries = selectedLibraries(from: libs, for: provider)
            await refreshProviderCollections(
                provider: provider,
                providerId: providerId,
                libraries: collectionLibraries
            )

            await MainActor.run {
                self.isRefreshing = false
                presentation.libraryImportProgress = nil
                library.changes.send(())
            }
            await saveMetadataAsync()
            await MainActor.run { _ = flushLocalBooksToCache() }
        } catch {
            AppLogger.general.error("[Sync] Failed to refresh library \(libraryId): \(error.localizedDescription)")
            await MainActor.run {
                self.isRefreshing = false; presentation.libraryImportProgress = nil; library.changes.send(())
            }
        }
    }

    func refreshConnectionLibraries(
        providerId: UUID,
        forceFullReconciliation: Bool = false,
        refreshCollections: Bool = true
    ) async {
        guard let provider = providerConnections[providerId] else {
            AppLogger.general.info(
                "[Catalog] No provider found diagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString))"
            )
            return
        }

        if providerConnections.connectionsNeedingReauth.contains(where: { $0.id == providerId })
            || AuthenticationFailureStore.shared.isBlocked(connectionId: providerId)
        {
            AppLogger.general.warning("[Catalog] Skipping refresh for provider requiring reauth: \(provider.connection.name)")
            return
        }

        guard await CatalogRefreshGate.shared.begin(providerId: providerId) else {
            AppLogger.general.info("Coalesced duplicate catalog refresh for \(provider.connection.name)")
            return
        }
        defer { CatalogRefreshGate.shared.end(providerId: providerId) }

        let backgroundTask = BackgroundTaskAssertion.begin(name: "Library Refresh")
        defer { backgroundTask.end() }

        await MainActor.run {
            self.isRefreshing = true
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: "",
                libraryName: "",
                providerName: provider.connection.name,
                loadedCount: 0,
                isComplete: false,
                phase: .connecting
            )
        }

        defer {
            Task { @MainActor in
                self.isRefreshing = false
                presentation.libraryImportProgress = nil
                library.changes.send(())
            }
        }

        do {
            let libraries = try await provider.fetchLibraries()

            providerConnections.clearReauthentication(connectionId: providerId)

            await MainActor.run {
                for lib in libraries where !self.libraries.contains(where: { $0.id == lib.id && $0.providerId == lib.providerId }) {
                    self.libraries.append(lib)
                }
            }

            await MainActor.run {
                self.pruneMissingLibrariesForProvider(providerId: providerId, validLibraries: libraries)
            }
            await purgeMissingLibraryBooks(providerId: providerId, validLibraries: libraries)

            let selectedIds = provider.connection.selectedLibraryIds
            let targets = libraries.filter { library in
                guard let selectedIds, !selectedIds.isEmpty else { return true }
                return selectedIds.contains(library.id)
            }

            guard !targets.isEmpty else {
                await saveMetadataAsync()
                return
            }

            for library in targets {
                await refreshSingleLibrary(
                    library,
                    provider: provider,
                    providerId: providerId,
                    providerName: provider.connection.name,
                    forceFullReconciliation: forceFullReconciliation
                )
            }

            if refreshCollections {
                await refreshProviderCollections(
                    provider: provider,
                    providerId: providerId,
                    libraries: targets
                )
            }
            await saveMetadataAsync()
            await MainActor.run { _ = flushLocalBooksToCache() }
        } catch {
            providerConnections.markNeedsReauthentication(providerId: providerId, error: error)
            AppLogger.general.error(
                "[Catalog] Failed to refresh provider libraries for \(provider.connection.name): \(error.localizedDescription)"
            )
        }
    }

    private func refreshProvider(
        _ provider: LibraryProvider,
        providerId: UUID,
        forceFullReconciliation: Bool
    ) async {
        let name = provider.connection.name
        guard await CatalogRefreshGate.shared.begin(providerId: providerId) else {
            AppLogger.general.info("Coalesced duplicate catalog refresh for \(name)")
            return
        }
        defer { CatalogRefreshGate.shared.end(providerId: providerId) }

        AppLogger.general.info("Starting: \(name)")

        await MainActor.run {
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: "",
                libraryName: "",
                providerName: name,
                loadedCount: 0,
                isComplete: false,
                phase: .connecting
            )
        }

        let libs: [Library]
        do {
            libs = try await provider.fetchLibraries()
        } catch {
            AppLogger.general.error("Failed to fetch libraries from \(name): \(error)")
            await MainActor.run { presentation.libraryImportProgress = nil }
            return
        }

        await MainActor.run {
            for lib in libs where !self.libraries.contains(where: { $0.id == lib.id && $0.providerId == lib.providerId }) {
                self.libraries.append(lib)
            }
            self.pruneMissingLibrariesForProvider(providerId: providerId, validLibraries: libs)
        }
        await purgeMissingLibraryBooks(providerId: providerId, validLibraries: libs)

        for lib in libs {
            if let selectedIds = provider.connection.selectedLibraryIds,
                !selectedIds.isEmpty,
                !selectedIds.contains(lib.id)
            {
                AppLogger.general.warning("Skipping disabled library: \(lib.name)")
                continue
            }

            await refreshSingleLibrary(
                lib,
                provider: provider,
                providerId: providerId,
                providerName: name,
                forceFullReconciliation: forceFullReconciliation
            )
        }

        await refreshProviderCollections(
            provider: provider,
            providerId: providerId,
            libraries: selectedLibraries(from: libs, for: provider)
        )
        AppLogger.general.info("Finished: \(name)")
    }

    private func selectedLibraries(from libraries: [Library], for provider: LibraryProvider) -> [Library] {
        guard let selectedIds = provider.connection.selectedLibraryIds,
            !selectedIds.isEmpty
        else {
            return libraries
        }
        return libraries.filter { selectedIds.contains($0.id) }
    }

    private func refreshProviderCollections(
        provider: LibraryProvider,
        providerId: UUID,
        libraries: [Library]
    ) async {
        guard provider.capabilities.contains(.collections) else { return }

        let libraryIds: [String?]
        switch provider.connection.type {
        case .booklore, .bookOrbit, .silo:
            libraryIds = [nil]
        default:
            libraryIds = libraries.map(\.id)
        }
        guard !libraryIds.isEmpty else { return }

        AppLogger.general.info("\(provider.connection.name): fetching collections...")

        var fetchedCollections: [Collection] = []
        for libraryId in libraryIds {
            do {
                fetchedCollections.append(contentsOf: try await provider.fetchCollections(libraryId: libraryId))
            } catch {
                providerConnections.markNeedsReauthentication(providerId: providerId, error: error)
                AppLogger.general.error("\(provider.connection.name): collection refresh failed: \(error.localizedDescription)")
                return
            }
        }

        let changed = commitServerCollectionSnapshot(fetchedCollections, from: provider)
        AppLogger.general.info(
            "\(provider.connection.name): refreshed \(fetchedCollections.count) collections\(changed ? "" : " (unchanged)")"
        )
    }

    @discardableResult
    func commitServerCollectionSnapshot(
        _ snapshot: [Collection],
        from provider: LibraryProvider
    ) -> Bool {
        let providerId = provider.connection.id
        var seen = Set<String>()
        let completeSnapshot = snapshot.filter {
            seen.insert("\($0.providerId?.uuidString ?? "")-\($0.id)").inserted
        }
        let existingSnapshot = collections.filter { $0.providerId == providerId }
        let fingerprint = ServerMirrorFingerprint.collections(completeSnapshot)
        let changed = ServerMirrorFingerprint.collections(existingSnapshot) != fingerprint

        if changed {
            collections.removeAll { $0.providerId == providerId }
            collections.append(contentsOf: completeSnapshot)
            saveMetadata()
            NotificationCenter.default.post(name: .collectionsDidChange, object: nil)
        }

        mirrorCheckpoints.commitCompleteSnapshot(
            scope: ServerMirrorScope(
                connectionId: providerId,
                accountKey: ServerMirrorFingerprint.accountKey(for: provider.connection),
                libraryId: nil,
                domain: .collections
            ),
            syncLevel: .fullSnapshot,
            fingerprint: fingerprint,
            itemCount: completeSnapshot.count
        )
        return changed
    }

    private func refreshSingleLibrary(
        _ lib: Library,
        provider: LibraryProvider,
        providerId: UUID,
        providerName: String,
        forceFullReconciliation: Bool = false
    ) async {
        defer { LibraryRecoveryCoordinator.shared.reconcileRescuedDownloads() }

        let startTime = Date()
        let existingLibraryBooks = await MainActor.run {
            library.books.filter { $0.libraryId == lib.id && $0.providerId == providerId }
        }

        if let bookloreProvider = provider as? BookloreProvider,
            bookloreProvider.supportsRemoteBrowsing,
            let remoteCount = try? await bookloreProvider.remoteBookCount(libraryId: lib.id)
        {
            RemoteLibraryBrowseStore.shared.record(providerId: providerId, libraryId: lib.id, bookCount: remoteCount)
            if RemoteLibraryBrowseStore.shared.isRemoteBrowsed(providerId: providerId, libraryId: lib.id) {
                await importRemoteBrowsedRecents(
                    lib: lib,
                    provider: bookloreProvider,
                    existingLibraryBooks: existingLibraryBooks
                )
                await bookStore.markFullReconciled(providerId: providerId, libraryId: lib.id, at: Date())
                bookloreProvider.completeCatalogSync(libraryId: lib.id)
                AppLogger.general.info(
                    "\(lib.name): \(remoteCount) books on server - skipping catalog reconciliation and browsing Grimmory remotely"
                )
                return
            }
        }

        await MainActor.run {
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: lib.id,
                libraryName: lib.name,
                providerName: providerName,
                loadedCount: 0,
                totalCount: nil,
                isComplete: false,
                phase: .indexing,
                startTime: startTime
            )
        }

        let streamBatch: (LibraryFetchBatchResult) -> Void = { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                presentation.libraryImportProgress = LibraryImportProgress(
                    libraryId: lib.id,
                    libraryName: lib.name,
                    providerName: providerName,
                    loadedCount: result.loadedSoFar,
                    totalCount: result.totalCount,
                    isComplete: false,
                    phase: .indexing,
                    startTime: startTime
                )
            }
        }

        let cursorSnapshot = await bookStore.loadCursor(providerId: providerId, libraryId: lib.id)
        let needsFullReconciliation =
            forceFullReconciliation || cursorSnapshot == nil
            || Date().timeIntervalSince(cursorSnapshot!.lastFullReconciledAt) > Self.fullCatalogReconciliationInterval

        if !needsFullReconciliation, let cursor = cursorSnapshot {
            var deltaResult: (books: [Book], cursor: Date)? = nil
            do {
                deltaResult = try await provider.fetchBooksDelta(libraryId: lib.id, since: cursor.lastSyncedAt)
            } catch {
                AppLogger.general.warning("\(lib.name): delta fetch failed (\(error.localizedDescription)) - falling back to full sync")
            }

            if let (deltaBooks, newCursor) = deltaResult {
                if deltaBooks.isEmpty {
                    AppLogger.general.info("\(lib.name): delta - no changes since \(cursor.lastSyncedAt)")
                    await bookStore.applyDelta(books: [], libraryId: lib.id, providerId: providerId, cursor: newCursor)
                    return
                }

                await MainActor.run {
                    presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: lib.id,
                        libraryName: lib.name,
                        providerName: providerName,
                        loadedCount: deltaBooks.count,
                        totalCount: deltaBooks.count,
                        isComplete: false,
                        phase: .enrichingMetadata,
                        startTime: startTime
                    )
                }

                let normalizedDelta = normalizeFetchedBooks(deltaBooks, for: lib, provider: provider)
                let batchSize = 500
                var enriched: [Book] = []
                enriched.reserveCapacity(normalizedDelta.count)
                for batchStart in stride(from: 0, to: normalizedDelta.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, normalizedDelta.count)
                    let batch = Array(normalizedDelta[batchStart..<batchEnd])
                    let enrichedBatch = await MetadataManager.shared.enrichBooksWithStoredMetadata(batch)
                    let progressBatch = applyLocalProgressOverrides(
                        enrichedBatch,
                        preloadedStoredProgress: await preloadStoredProgressMap(for: enrichedBatch)
                    )
                    let mergedBatch = applyLocalRelationshipOverrides(progressBatch, existingBooks: existingLibraryBooks)
                    enriched.append(contentsOf: mergedBatch)
                }

                await MainActor.run {
                    let deletedIds = DeletedBooksTombstoneStore.shared.allDeleted
                    library.performBatch {
                        var byUniqueId = [String: Int](minimumCapacity: library.books.count)
                        for (i, book) in library.books.enumerated() {
                            byUniqueId[book.uniqueId] = i
                        }
                        for book in enriched where !deletedIds.contains(book.stableId) {
                            if let idx = byUniqueId[book.uniqueId] {
                                library.books[idx] = book
                            } else {
                                library.books.append(book)
                                byUniqueId[book.uniqueId] = library.books.count - 1
                            }
                        }
                    }
                }

                await bookStore.applyDelta(books: enriched, libraryId: lib.id, providerId: providerId, cursor: newCursor)
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
                AppLogger.general.info(
                    "\(lib.name): delta synced \(enriched.count) changed books in \(elapsed)s (skipping series/collections - refreshed only on full reconciliation)"
                )
                return
            }
        }

        if let bookloreProvider = provider as? BookloreProvider,
            bookloreProvider.supportsTransactionalCatalogImport
        {
            let handled = await refreshSingleLibraryViaGrimmoryCatalog(
                lib: lib,
                provider: bookloreProvider,
                providerId: providerId,
                providerName: providerName,
                existingLibraryBooks: existingLibraryBooks,
                startTime: startTime
            )
            if handled { return }
        }

        if let incrementalProvider = provider as? IncrementalCatalogProvider {
            let handled = await refreshSingleLibraryViaIncrementalCatalog(
                lib: lib,
                provider: incrementalProvider,
                providerId: providerId,
                providerName: providerName,
                existingLibraryBooks: existingLibraryBooks,
                startTime: startTime
            )
            if handled { return }
        }

        if provider.capabilities.contains(.streamingImport) {
            await refreshSingleLibraryViaStreaming(
                lib: lib,
                provider: provider,
                providerId: providerId,
                providerName: providerName,
                startTime: startTime
            )
            return
        }

        let fetchedBooks: [Book]
        do {
            if let bookloreProvider = provider as? BookloreProvider {
                fetchedBooks = try await bookloreProvider.fetchBooks(libraryId: lib.id, onBatch: streamBatch)
            } else {
                fetchedBooks = try await provider.fetchBooks(libraryId: lib.id)
            }
        } catch {
            await MainActor.run {
                providerConnections.markNeedsReauthentication(providerId: providerId, error: error)
            }
            AppLogger.general.error("Failed to fetch books for \(lib.name): \(error)")
            return
        }

        let totalFetched = fetchedBooks.count

        if totalFetched == 0 {
            if provider.connection.type == .webdav || provider.connection.type == .torbox {
                let cachedCount = await MainActor.run {
                    library.books.filter { $0.libraryId == lib.id && $0.providerId == providerId }.count
                }
                if cachedCount > 0 {
                    AppLogger.general.info("Server returned 0 books for \(lib.name) but cache has \(cachedCount) - keeping cache")
                    return
                }
            }
            AppLogger.general.info("\(lib.name): 0 books")
        }

        await MainActor.run {
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: lib.id,
                libraryName: lib.name,
                providerName: providerName,
                loadedCount: totalFetched,
                totalCount: totalFetched,
                isComplete: false,
                phase: .enrichingMetadata,
                startTime: startTime
            )
        }

        let normalizedFetchedBooks = normalizeFetchedBooks(fetchedBooks, for: lib, provider: provider)
        let batchSize = 500
        var allEnriched: [Book] = []
        allEnriched.reserveCapacity(normalizedFetchedBooks.count)

        for batchStart in stride(from: 0, to: normalizedFetchedBooks.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, normalizedFetchedBooks.count)
            let batch = Array(normalizedFetchedBooks[batchStart..<batchEnd])
            let enrichedBatch = await MetadataManager.shared.enrichBooksWithStoredMetadata(batch)
            let progressBatch = applyLocalProgressOverrides(
                enrichedBatch,
                preloadedStoredProgress: await preloadStoredProgressMap(for: enrichedBatch)
            )
            let mergedBatch = applyLocalRelationshipOverrides(progressBatch, existingBooks: existingLibraryBooks)
            allEnriched.append(contentsOf: mergedBatch)
        }

        await MainActor.run {
            let deletedIds = DeletedBooksTombstoneStore.shared.allDeleted
            let refreshedIds = Set(allEnriched.map(\.uniqueId))
            if let current = session.currentBook,
                current.providerId == providerId,
                current.libraryId == lib.id,
                !refreshedIds.contains(current.uniqueId)
            {
                session.currentBook = nil
                presentation.isPlayerPresented = false
            }
            if let selected = presentation.selectedEbookForDetail,
                selected.providerId == providerId,
                selected.libraryId == lib.id,
                !refreshedIds.contains(selected.uniqueId)
            {
                presentation.selectedEbookForDetail = nil
            }
            var merged = library.books.filter { !($0.libraryId == lib.id && $0.providerId == providerId) }
            var seen = Set<String>(merged.map { $0.uniqueId })
            merged.reserveCapacity(merged.count + allEnriched.count)
            for book in allEnriched where !deletedIds.contains(book.stableId) && seen.insert(book.uniqueId).inserted {
                merged.append(book)
            }
            let priorSkip = library.skipsDeduplication
            library.skipsDeduplication = true
            library.books = merged
            library.skipsDeduplication = priorSkip
        }

        await bookStore.replaceLibrary(
            books: allEnriched,
            libraryId: lib.id,
            providerId: providerId,
            allowSparseResult: forceFullReconciliation
        )

        await bookStore.markFullReconciled(providerId: providerId, libraryId: lib.id, at: Date())

        if let bookloreProvider = provider as? BookloreProvider {
            bookloreProvider.completeCatalogSync(libraryId: lib.id)
        }

        AppLogger.general.info("\(lib.name): \(allEnriched.count) books synced to BookStore (full reconciliation)")

        await MainActor.run {
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: lib.id,
                libraryName: lib.name,
                providerName: providerName,
                loadedCount: allEnriched.count,
                totalCount: allEnriched.count,
                isComplete: false,
                phase: .fetchingSeries,
                startTime: startTime
            )
        }

        AppLogger.general.info("\(lib.name): fetching series...")

        do {
            let fetchedSeries: [Series]
            if provider.connection.type == .booklore {
                fetchedSeries = buildSeriesFromBooks(allEnriched, libraryId: lib.id, providerId: providerId)
                AppLogger.general.info("\(lib.name): using derived Grimmory series from fetched books (\(fetchedSeries.count))")
            } else {
                fetchedSeries = try await provider.fetchSeries(libraryId: lib.id)
                AppLogger.general.info("\(lib.name): provider returned \(fetchedSeries.count) series")
            }

            let derivedSeries =
                fetchedSeries.isEmpty
                ? buildSeriesFromBooks(allEnriched, libraryId: lib.id, providerId: providerId)
                : []
            await MainActor.run {
                self.series.removeAll { $0.libraryId == lib.id && $0.providerId == providerId }
                let newSeries = !fetchedSeries.isEmpty ? fetchedSeries : derivedSeries
                if !newSeries.isEmpty {
                    self.series.append(contentsOf: newSeries)
                }
            }
        } catch {
            AppLogger.general.error("Failed to fetch series for \(lib.name): \(error.localizedDescription)")
            let derived = buildSeriesFromBooks(allEnriched, libraryId: lib.id, providerId: providerId)
            await MainActor.run {
                self.series.removeAll { $0.libraryId == lib.id && $0.providerId == providerId }
                if !derived.isEmpty {
                    self.series.append(contentsOf: derived)
                }
            }
            AppLogger.general.info("\(lib.name): fell back to derived series (\(derived.count))")
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        AppLogger.general.info("\(lib.name) complete in \(elapsed)s")
    }

    private func importRemoteBrowsedRecents(
        lib: Library,
        provider: BookloreProvider,
        existingLibraryBooks: [Book]
    ) async {
        let recents = (try? await provider.fetchRecentBooks(libraryId: lib.id, limit: 100)) ?? []
        let deletedIds = DeletedBooksTombstoneStore.shared.allDeleted
        let visible = recents.filter { !deletedIds.contains($0.stableId) }
        guard !visible.isEmpty else { return }

        let normalized = normalizeFetchedBooks(visible, for: lib, provider: provider)
        let enriched = await MetadataManager.shared.enrichBooksWithStoredMetadata(normalized)
        let progressAdjusted = applyLocalProgressOverrides(
            enriched,
            preloadedStoredProgress: await preloadStoredProgressMap(for: enriched)
        )
        let stored = await bookStore.booksByUniqueIds(Set(progressAdjusted.map(\.uniqueId)))
        let merged = applyLocalRelationshipOverrides(
            progressAdjusted,
            existingBooks: existingLibraryBooks + Array(stored.values)
        )
        await bookStore.upsertBooks(merged)
    }

    private func refreshSingleLibraryViaGrimmoryCatalog(
        lib: Library,
        provider: BookloreProvider,
        providerId: UUID,
        providerName: String,
        existingLibraryBooks: [Book],
        startTime: Date
    ) async -> Bool {
        let session: GrimmoryCatalogImportSession
        do {
            session = try await provider.openCatalogImport(libraryId: lib.id)
        } catch {
            AppLogger.general.warning(
                "\(lib.name): transactional Grimmory catalog unavailable (\(error.localizedDescription)); using compatibility import"
            )
            return false
        }

        RemoteLibraryBrowseStore.shared.record(
            providerId: providerId,
            libraryId: lib.id,
            bookCount: session.totalElements
        )

        if session.totalElements > RemoteLibraryBrowseStore.bookCountThreshold {
            await MainActor.run {
                presentation.libraryImportProgress = LibraryImportProgress(
                    libraryId: lib.id,
                    libraryName: lib.name,
                    providerName: providerName,
                    loadedCount: min(existingLibraryBooks.count, session.totalElements),
                    totalCount: session.totalElements,
                    isComplete: false,
                    phase: .indexing,
                    startTime: startTime
                )
            }
            await importRemoteBrowsedRecents(
                lib: lib,
                provider: provider,
                existingLibraryBooks: existingLibraryBooks
            )
            await bookStore.markFullReconciled(providerId: providerId, libraryId: lib.id, at: Date())
            provider.completeCatalogSync(libraryId: lib.id)
            await MainActor.run { presentation.libraryImportProgress = nil }
            AppLogger.general.info(
                "\(lib.name): Grimmory library has \(session.totalElements) books; using remote browse instead of full local import"
            )
            return true
        }

        let reconciliation: ReconciliationStart
        if let resumed = session.reconciliation {
            reconciliation = resumed
        } else {
            reconciliation = await bookStore.beginReconciliation(libraryId: lib.id, providerId: providerId)
            do {
                try provider.bindCatalogImport(session, to: reconciliation)
            } catch {
                AppLogger.general.error("\(lib.name): could not persist Grimmory reconciliation: \(error.localizedDescription)")
                return true
            }
        }

        let deletedIds = await MainActor.run { DeletedBooksTombstoneStore.shared.allDeleted }
        var loadedSoFar = 0

        do {
            while let batch = try await provider.nextCatalogImportBatch(session) {
                try Task.checkCancellation()
                let visible = batch.books.filter { !deletedIds.contains($0.stableId) }
                let normalized = normalizeFetchedBooks(visible, for: lib, provider: provider)
                let enriched = await MetadataManager.shared.enrichBooksWithStoredMetadata(normalized)
                let progressAdjusted = applyLocalProgressOverrides(
                    enriched,
                    preloadedStoredProgress: await preloadStoredProgressMap(for: enriched)
                )
                let storedBatch = await bookStore.booksByUniqueIds(Set(progressAdjusted.map(\.uniqueId)))
                let merged = applyLocalRelationshipOverrides(
                    progressAdjusted,
                    existingBooks: existingLibraryBooks + Array(storedBatch.values)
                )

                try await bookStore.upsertReconciledPage(
                    books: merged,
                    generation: reconciliation.generation,
                    notifyChange: false
                )
                try provider.markCatalogImportBatchCommitted(batch, session: session)
                loadedSoFar = batch.loadedSoFar
                AppLogger.general.info(
                    "\(lib.name): committed Grimmory pages \(batch.pages.first ?? 0)-\(batch.pages.last ?? 0) (\(loadedSoFar) books)"
                )

                await MainActor.run {
                    presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: lib.id,
                        libraryName: lib.name,
                        providerName: providerName,
                        loadedCount: loadedSoFar,
                        totalCount: batch.totalCount,
                        isComplete: false,
                        phase: .indexing,
                        startTime: startTime
                    )
                }
            }
        } catch {
            await MainActor.run {
                providerConnections.markNeedsReauthentication(providerId: providerId, error: error)
            }
            AppLogger.general.error(
                "\(lib.name): Grimmory page import stopped after \(loadedSoFar) books: \(error.localizedDescription). Committed pages will resume."
            )
            await MainActor.run { presentation.libraryImportProgress = nil }
            return true
        }

        do {
            let outcome = try await bookStore.endReconciliation(
                libraryId: lib.id,
                providerId: providerId,
                generation: reconciliation.generation,
                existingCountBefore: reconciliation.existingCount
            )
            guard case let .completed(deleted, kept) = outcome else {
                AppLogger.general.warning("\(lib.name): Grimmory reconciliation refused a sparse catalog; checkpoint retained")
                await MainActor.run { presentation.libraryImportProgress = nil }
                return true
            }
            await bookStore.markFullReconciled(providerId: providerId, libraryId: lib.id, at: Date())
            provider.completeCatalogSync(libraryId: lib.id)
            AppLogger.general.info("\(lib.name): Grimmory reconciliation committed - \(kept) kept, \(deleted) removed")
        } catch {
            AppLogger.general.error("\(lib.name): Grimmory reconciliation failed: \(error.localizedDescription)")
            await MainActor.run { presentation.libraryImportProgress = nil }
            return true
        }

        let mirror = await bookStore.pagedBooks(libraryId: lib.id, providerId: providerId, offset: 0, limit: 2000)
        var seriesMap: [String: (bookIds: [String], sequences: [String: String])] = [:]
        var seriesOffset = 0
        let seriesPageSize = 1000
        while true {
            let books = await bookStore.pagedBooks(
                libraryId: lib.id,
                providerId: providerId,
                offset: seriesOffset,
                limit: seriesPageSize
            )
            for book in books {
                guard let info = book.seriesInfo, !info.name.isEmpty else { continue }
                var entry = seriesMap[info.name] ?? (bookIds: [], sequences: [:])
                entry.bookIds.append(book.id)
                if let sequence = info.sequence { entry.sequences[book.id] = sequence }
                seriesMap[info.name] = entry
            }
            guard books.count == seriesPageSize else { break }
            seriesOffset += books.count
        }
        let importedSeries = seriesMap.map { name, data in
            Series(
                id: "grimmory-series-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                name: name,
                description: nil,
                books: data.bookIds,
                bookSequences: data.sequences,
                bookCount: data.bookIds.count,
                libraryId: lib.id,
                providerId: providerId
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        await MainActor.run {
            var merged = library.books.filter { !($0.libraryId == lib.id && $0.providerId == providerId) }
            var seen = Set(merged.map(\.uniqueId))
            for book in mirror where !deletedIds.contains(book.stableId) && seen.insert(book.uniqueId).inserted {
                merged.append(book)
            }
            let priorSkip = library.skipsDeduplication
            library.skipsDeduplication = true
            library.books = merged
            library.skipsDeduplication = priorSkip
            self.series.removeAll { $0.libraryId == lib.id && $0.providerId == providerId }
            self.series.append(contentsOf: importedSeries)
            presentation.libraryImportProgress = nil
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        AppLogger.general.info("\(lib.name) (transactional Grimmory) complete in \(elapsed)s - \(loadedSoFar) books processed")
        return true
    }

    private func refreshSingleLibraryViaIncrementalCatalog(
        lib: Library,
        provider: IncrementalCatalogProvider,
        providerId: UUID,
        providerName: String,
        existingLibraryBooks: [Book],
        startTime: Date
    ) async -> Bool {
        let storedCheckpoint = CatalogImportCheckpointStore.load(
            connectionId: providerId,
            libraryId: lib.id
        )
        let source: LibraryCatalogBatchSource
        do {
            source = try await provider.makeCatalogBatchSource(
                libraryId: lib.id,
                resumeAfter: storedCheckpoint?.resumeToken,
                expectedSnapshotIdentifier: storedCheckpoint?.snapshotIdentifier
            )
        } catch {
            AppLogger.general.warning(
                "\(lib.name): incremental catalog unavailable (\(error.localizedDescription)); using compatibility import"
            )
            return false
        }

        var checkpoint: CatalogImportCheckpoint
        if let storedCheckpoint,
            storedCheckpoint.providerType == provider.connection.type,
            source.resumed
        {
            checkpoint = storedCheckpoint
            AppLogger.general.info(
                "\(lib.name): resuming incremental import after \(storedCheckpoint.committedBookCount) committed books"
            )
        } else {
            let reconciliation = await bookStore.beginReconciliation(libraryId: lib.id, providerId: providerId)
            do {
                checkpoint = try CatalogImportCheckpointStore.start(
                    connection: provider.connection,
                    libraryId: lib.id,
                    snapshotIdentifier: source.snapshotIdentifier,
                    reconciliation: reconciliation
                )
            } catch {
                AppLogger.general.error("\(lib.name): could not persist catalog reconciliation: \(error.localizedDescription)")
                return true
            }
        }

        let deletedIds = await MainActor.run { DeletedBooksTombstoneStore.shared.allDeleted }
        var loadedSoFar = checkpoint.committedBookCount
        var catalogIdentities: [String: String] = [:]

        do {
            while let batch = try await source.next() {
                try Task.checkCancellation()
                let visible = try validatedCatalogBooks(
                    batch.books.filter { !deletedIds.contains($0.stableId) },
                    providerId: providerId,
                    identities: &catalogIdentities
                )
                let normalized = normalizeFetchedBooks(visible, for: lib, provider: provider)
                let enriched = await MetadataManager.shared.enrichBooksWithStoredMetadata(normalized)
                let progressAdjusted = applyLocalProgressOverrides(
                    enriched,
                    preloadedStoredProgress: await preloadStoredProgressMap(for: enriched)
                )
                let storedBatch = await bookStore.booksByUniqueIds(Set(progressAdjusted.map(\.uniqueId)))
                let merged = applyLocalRelationshipOverrides(
                    progressAdjusted,
                    existingBooks: existingLibraryBooks + Array(storedBatch.values)
                )

                try await bookStore.upsertReconciledPage(
                    books: merged,
                    generation: checkpoint.reconciliationGeneration,
                    notifyChange: false
                )
                try CatalogImportCheckpointStore.markCommitted(batch, checkpoint: &checkpoint)
                loadedSoFar = checkpoint.committedBookCount
                AppLogger.general.info(
                    "\(lib.name): committed incremental catalog batch (\(loadedSoFar) books, resume=\(batch.resumeToken ?? "complete"))"
                )

                await MainActor.run {
                    presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: lib.id,
                        libraryName: lib.name,
                        providerName: providerName,
                        loadedCount: loadedSoFar,
                        totalCount: batch.totalCount,
                        isComplete: false,
                        phase: .indexing,
                        startTime: startTime
                    )
                }
            }
        } catch {
            await MainActor.run {
                providerConnections.markNeedsReauthentication(providerId: providerId, error: error)
            }
            AppLogger.general.error(
                "\(lib.name): incremental catalog stopped after \(loadedSoFar) books: \(error.localizedDescription). Committed batches will resume."
            )
            await MainActor.run { presentation.libraryImportProgress = nil }
            return true
        }

        guard checkpoint.completedSnapshot else {
            AppLogger.general.error("\(lib.name): incremental catalog ended without a complete snapshot marker")
            await MainActor.run { presentation.libraryImportProgress = nil }
            return true
        }

        do {
            let outcome = try await bookStore.endReconciliation(
                libraryId: lib.id,
                providerId: providerId,
                generation: checkpoint.reconciliationGeneration,
                existingCountBefore: checkpoint.existingCountBefore
            )
            guard case let .completed(deleted, kept) = outcome else {
                AppLogger.general.warning("\(lib.name): incremental reconciliation refused a sparse catalog; checkpoint retained")
                await MainActor.run { presentation.libraryImportProgress = nil }
                return true
            }
            await bookStore.markFullReconciled(providerId: providerId, libraryId: lib.id, at: Date())
            CatalogImportCheckpointStore.clear(connectionId: providerId, libraryId: lib.id)
            AppLogger.general.info("\(lib.name): incremental reconciliation committed - \(kept) kept, \(deleted) removed")
        } catch {
            AppLogger.general.error("\(lib.name): incremental reconciliation failed: \(error.localizedDescription)")
            await MainActor.run { presentation.libraryImportProgress = nil }
            return true
        }

        let mirror = await bookStore.pagedBooks(libraryId: lib.id, providerId: providerId, offset: 0, limit: 2000)
        await MainActor.run {
            var merged = library.books.filter { !($0.libraryId == lib.id && $0.providerId == providerId) }
            var seen = Set(merged.map(\.uniqueId))
            for book in mirror where !deletedIds.contains(book.stableId) && seen.insert(book.uniqueId).inserted {
                merged.append(book)
            }
            let priorSkip = library.skipsDeduplication
            library.skipsDeduplication = true
            library.books = merged
            library.skipsDeduplication = priorSkip
            presentation.libraryImportProgress = nil
        }

        if provider.capabilities.contains(.series) {
            do {
                let fetchedSeries = try await provider.fetchSeries(libraryId: lib.id)
                await MainActor.run {
                    self.series.removeAll { $0.libraryId == lib.id && $0.providerId == providerId }
                    self.series.append(contentsOf: fetchedSeries)
                }
            } catch {
                AppLogger.general.error("\(lib.name): series fetch failed: \(error.localizedDescription)")
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        AppLogger.general.info("\(lib.name) (incremental) complete in \(elapsed)s - \(loadedSoFar) books processed")
        return true
    }

    private func validatedCatalogBooks(
        _ books: [Book],
        providerId: UUID,
        identities: inout [String: String]
    ) throws -> [Book] {
        var result: [Book] = []
        result.reserveCapacity(books.count)
        for book in books {
            guard book.providerId == providerId else { throw ProviderError.invalidResponse }
            let signature = "\(book.mediaType.rawValue)|\(book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\((book.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            if let existing = identities[book.uniqueId] {
                guard existing == signature else {
                    throw ProviderError.serverError("Provider returned conflicting books for identity \(book.uniqueId)")
                }
                continue
            }
            identities[book.uniqueId] = signature
            result.append(book)
        }
        return result
    }

    private func refreshSingleLibraryViaStreaming(
        lib: Library,
        provider: LibraryProvider,
        providerId: UUID,
        providerName: String,
        startTime: Date
    ) async {
        await MainActor.run {
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: lib.id,
                libraryName: lib.name,
                providerName: providerName,
                loadedCount: 0,
                totalCount: nil,
                isComplete: false,
                phase: .indexing,
                startTime: startTime
            )
        }

        let reconciliation = await bookStore.beginReconciliation(libraryId: lib.id, providerId: providerId)

        var loadedSoFar = 0
        var firstBatchTotalCount: Int? = nil
        let deletedIds = await MainActor.run { DeletedBooksTombstoneStore.shared.allDeleted }

        do {
            for try await batch in provider.fetchBookBatches(libraryId: lib.id) {
                let visible = batch.books.filter { !deletedIds.contains($0.stableId) }
                let normalized = normalizeFetchedBooks(visible, for: lib, provider: provider)
                let enriched = await MetadataManager.shared.enrichBooksWithStoredMetadata(normalized)
                let progressAdjusted = applyLocalProgressOverrides(
                    enriched,
                    preloadedStoredProgress: await preloadStoredProgressMap(for: enriched)
                )
                let storedBatch = await bookStore.booksByUniqueIds(Set(progressAdjusted.map(\.uniqueId)))
                let merged = applyLocalRelationshipOverrides(progressAdjusted, existingBooks: Array(storedBatch.values))

                try await bookStore.upsertReconciledPage(
                    books: merged,
                    generation: reconciliation.generation,
                    notifyChange: false
                )
                loadedSoFar += merged.count
                firstBatchTotalCount = firstBatchTotalCount ?? batch.totalCount

                let progressTotal = firstBatchTotalCount
                let progressLoaded = loadedSoFar
                await MainActor.run {
                    presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: lib.id,
                        libraryName: lib.name,
                        providerName: providerName,
                        loadedCount: progressLoaded,
                        totalCount: progressTotal,
                        isComplete: false,
                        phase: .indexing,
                        startTime: startTime
                    )
                }
            }
        } catch {
            await MainActor.run {
                providerConnections.markNeedsReauthentication(providerId: providerId, error: error)
            }
            AppLogger.general.error(
                "\(lib.name): streaming fetch failed: \(error). Skipping orphan reconciliation; partial pages preserved."
            )
            await MainActor.run { presentation.libraryImportProgress = nil }
            return
        }

        guard !Task.isCancelled else {
            AppLogger.general.info("\(lib.name): streaming fetch cancelled. Skipping orphan reconciliation.")
            await MainActor.run { presentation.libraryImportProgress = nil }
            return
        }

        var reconciliationCompleted = false
        do {
            let outcome = try await bookStore.endReconciliation(
                libraryId: lib.id,
                providerId: providerId,
                generation: reconciliation.generation,
                existingCountBefore: reconciliation.existingCount
            )
            switch outcome {
            case let .completed(deleted, kept):
                reconciliationCompleted = true
                AppLogger.general.info("\(lib.name): streamed reconciliation - \(kept) kept, \(deleted) orphans deleted")
            case let .refusedSparseResponse(existing, incoming):
                AppLogger.general.warning(
                    "\(lib.name): streamed reconciliation refused sparse response (existing=\(existing) vs incoming=\(incoming)); orphans preserved"
                )
            }
        } catch {
            AppLogger.general.error("\(lib.name): endReconciliation failed: \(error)")
        }

        if reconciliationCompleted {
            await bookStore.markFullReconciled(providerId: providerId, libraryId: lib.id, at: Date())
        }

        let mirrorLimit = 2000
        let mirror = await bookStore.pagedBooks(libraryId: lib.id, providerId: providerId, offset: 0, limit: mirrorLimit)
        await MainActor.run {
            var merged = library.books.filter { !($0.libraryId == lib.id && $0.providerId == providerId) }
            var seen = Set<String>(merged.map { $0.uniqueId })
            merged.reserveCapacity(merged.count + mirror.count)
            for book in mirror where !deletedIds.contains(book.stableId) && seen.insert(book.uniqueId).inserted {
                merged.append(book)
            }
            let priorSkip = library.skipsDeduplication
            library.skipsDeduplication = true
            library.books = merged
            library.skipsDeduplication = priorSkip
        }

        await MainActor.run {
            presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: lib.id,
                libraryName: lib.name,
                providerName: providerName,
                loadedCount: loadedSoFar,
                totalCount: loadedSoFar,
                isComplete: false,
                phase: .fetchingSeries,
                startTime: startTime
            )
        }
        if provider.capabilities.contains(.series) {
            do {
                let fetchedSeries = try await provider.fetchSeries(libraryId: lib.id)
                await MainActor.run {
                    self.series.removeAll { $0.libraryId == lib.id && $0.providerId == providerId }
                    if !fetchedSeries.isEmpty {
                        self.series.append(contentsOf: fetchedSeries)
                    }
                }
                AppLogger.general.info("\(lib.name): provider returned \(fetchedSeries.count) series")
            } catch {
                AppLogger.general.error("\(lib.name): series fetch failed: \(error.localizedDescription)")
            }
        }

        await MainActor.run { presentation.libraryImportProgress = nil }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        AppLogger.general.info("\(lib.name) (streaming) complete in \(elapsed)s - \(loadedSoFar) books processed")
    }

    @MainActor
    private func pruneMissingLibrariesForProvider(providerId: UUID, validLibraries: [Library]) {
        let validLibraryIds = Set(validLibraries.map(\.id))
        let beforeBookCount = library.books.count
        let beforeLibraryCount = libraries.count
        let beforeSeriesCount = series.count
        let beforeBookUniqueIds = Set(library.books.filter { $0.providerId == providerId }.map { $0.uniqueId })

        libraries.removeAll { library in
            library.providerId == providerId && !validLibraryIds.contains(library.id)
        }
        library.books.removeAll { book in
            book.providerId == providerId && !validLibraryIds.contains(book.libraryId)
        }
        series.removeAll { entry in
            entry.providerId == providerId && !validLibraryIds.contains(entry.libraryId)
        }
        if let current = session.currentBook,
            current.providerId == providerId,
            !validLibraryIds.contains(current.libraryId)
        {
            session.currentBook = nil
            presentation.isPlayerPresented = false
        }
        if let selected = presentation.selectedEbookForDetail,
            selected.providerId == providerId,
            !validLibraryIds.contains(selected.libraryId)
        {
            presentation.selectedEbookForDetail = nil
        }

        let removedBookIds = beforeBookUniqueIds.subtracting(Set(library.books.filter { $0.providerId == providerId }.map { $0.uniqueId }))
        if !removedBookIds.isEmpty {
            LibraryRecoveryCoordinator.shared.pendingBookStoreDeletions.formUnion(removedBookIds)
        }

        if beforeBookCount != library.books.count || beforeLibraryCount != libraries.count || beforeSeriesCount != series.count {
            AppLogger.general.info(
                "Pruned stale cached entries for provider \(providerId.uuidString): \(beforeBookCount) → \(library.books.count) books"
            )
        }
    }

    private func purgeMissingLibraryBooks(providerId: UUID, validLibraries: [Library]) async {
        var validProviderIds = Set(providerConnections.connections.filter { !$0.isArchived }.map { $0.id.uuidString })
        validProviderIds.insert(providerId.uuidString)
        let validLibraryIds = Set(validLibraries.map(\.id))
        let removed = await bookStore.deleteBooksFromInactiveLibraries(
            validProviderIds: validProviderIds,
            restrictedLibraryIds: [providerId.uuidString: validLibraryIds]
        )
        if removed > 0 {
            AppLogger.general.info(
                "Purged \(removed) cached books for providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString))"
            )
        }
    }

    private func preloadStoredProgressMap(
        for books: [Book]
    ) async -> [String: (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)] {
        guard !books.isEmpty else { return [:] }
        let lookups: [(uniqueId: String, stableKey: String, legacyKey: String)] = books.map {
            ($0.uniqueId, "bookProgress_\($0.stableId)", "bookProgress_\($0.id)")
        }
        return await Task.detached(priority: .userInitiated) {
            let defaults = UserDefaults.standard
            var map = [String: (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)](minimumCapacity: 256)
            for entry in lookups {
                let dict =
                    defaults.dictionary(forKey: entry.stableKey)
                    ?? (entry.stableKey != entry.legacyKey ? defaults.dictionary(forKey: entry.legacyKey) : nil)
                guard let dict,
                    let progress = dict["progress"] as? TimeInterval,
                    let duration = dict["duration"] as? TimeInterval,
                    let lastUpdated = dict["lastUpdated"] as? TimeInterval
                else { continue }
                map[entry.uniqueId] = (progress, duration, lastUpdated)
            }
            return map
        }.value
    }

    private func applyLocalProgressOverrides(
        _ books: [Book],
        preloadedStoredProgress: [String: (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)]? = nil
    ) -> [Book] {
        let storedProgressMap: [String: (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)] =
            preloadedStoredProgress
            ?? {
                var map: [String: (TimeInterval, TimeInterval, TimeInterval)] = [:]
                for book in books {
                    if let stored = BookProgressStore.shared.loadProgress(for: book) {
                        map[book.uniqueId] = stored
                    }
                }
                return map
            }()

        var adjusted = books

        for index in adjusted.indices {
            let book = adjusted[index]

            if book.isFinished {
                if book.mediaType == .ebook {
                    adjusted[index].ebookProgress = max(adjusted[index].ebookProgress ?? 0, 1.0)
                } else if let duration = adjusted[index].duration, duration > 0 {
                    adjusted[index].currentTime = max(adjusted[index].currentTime, duration)
                }
                continue
            }

            let localProgress = progress.progress(forUniqueId: book.uniqueId)
            let storedProgress = storedProgressMap[book.uniqueId]

            let localTime: TimeInterval?
            let localUpdate: Date?
            let localIsFinished: Bool?

            if let progress = localProgress {
                localTime = progress.currentTime
                localUpdate = progress.lastUpdate
                localIsFinished = progress.isFinished
            } else if let stored = storedProgress {
                localTime = stored.progress
                localUpdate = Date(timeIntervalSince1970: stored.lastUpdated)
                localIsFinished = nil
            } else {
                continue
            }

            guard let localTime, let localUpdate else { continue }

            let serverTime = book.currentTime
            let serverUpdate = book.lastUpdate
            let hasServerProgress = serverTime > 0 || (book.progress ?? 0) > 0

            let shouldOverride: Bool
            if !hasServerProgress {
                shouldOverride = localTime > 0
            } else {
                shouldOverride = localUpdate > serverUpdate
            }

            guard shouldOverride else { continue }

            adjusted[index].currentTime = localTime
            adjusted[index].lastUpdate = localUpdate
            if let localIsFinished {
                adjusted[index].isFinished = localIsFinished
            } else if let duration = adjusted[index].duration, duration > 0 {
                adjusted[index].isFinished = localTime >= (duration - 5)
            }
        }

        return adjusted
    }

    private func applyLocalRelationshipOverrides(_ books: [Book], existingBooks: [Book]) -> [Book] {
        guard !existingBooks.isEmpty else { return books }

        func preferredEbookURL(existing: Book, incoming: Book) -> URL? {
            if let incomingURL = incoming.ebookFileURL,
                FileManager.default.fileExists(atPath: incomingURL.path)
            {
                return incomingURL
            }
            if let incomingPath = incoming.filePath,
                !incomingPath.isEmpty,
                FileManager.default.fileExists(atPath: incomingPath)
            {
                return URL(fileURLWithPath: incomingPath)
            }
            if let existingURL = existing.ebookFileURL,
                FileManager.default.fileExists(atPath: existingURL.path)
            {
                return existingURL
            }
            if let existingPath = existing.filePath,
                !existingPath.isEmpty,
                FileManager.default.fileExists(atPath: existingPath)
            {
                return URL(fileURLWithPath: existingPath)
            }
            return incoming.ebookFileURL ?? existing.ebookFileURL
        }

        let existingByUniqueId = Dictionary(existingBooks.map { ($0.uniqueId, $0) }, uniquingKeysWith: { _, new in new })
        let existingByStableId = Dictionary(existingBooks.map { ($0.stableId, $0) }, uniquingKeysWith: { _, new in new })

        return books.map { incoming in
            guard let existing = existingByUniqueId[incoming.uniqueId] ?? existingByStableId[incoming.stableId] else {
                return incoming
            }

            var merged = incoming

            if incoming.lastUpdate > existing.lastUpdate {
                merged.ebookFileURL = preferredEbookURL(existing: existing, incoming: incoming)
            } else if incoming.mediaType == .ebook {
                if incoming.isFinished {
                    merged.ebookProgress = max(merged.ebookProgress ?? 0, 1.0)
                    merged.hideFromContinue = false
                    merged.epubLocator = merged.epubLocator ?? existing.epubLocator
                    merged.ebookFileURL = preferredEbookURL(existing: existing, incoming: incoming)
                    return merged
                }

                let existingProg = existing.ebookProgress ?? 0
                let incomingProg = merged.ebookProgress ?? 0
                if existingProg > incomingProg + 0.001 {
                    merged.ebookProgress = existing.ebookProgress
                    merged.epubLocator = existing.epubLocator ?? merged.epubLocator
                } else if incomingProg > existingProg + 0.001 {
                    merged.epubLocator = merged.epubLocator ?? existing.epubLocator
                } else {
                    merged.epubLocator = existing.epubLocator ?? merged.epubLocator
                }
                merged.ebookFileURL = preferredEbookURL(existing: existing, incoming: incoming)
            } else if existing.mediaType == .ebook, incoming.mediaType == .audiobook {
                merged.epubLocator = existing.epubLocator
                merged.ebookProgress = existing.ebookProgress
                merged.ebookFileURL = preferredEbookURL(existing: existing, incoming: incoming)
            } else {
                if incoming.isFinished {
                    if let duration = merged.duration, duration > 0 {
                        merged.currentTime = max(merged.currentTime, duration)
                    }
                    return merged
                }

                let existingProg = existing.ebookProgress ?? 0
                let incomingProg = merged.ebookProgress ?? 0
                if existingProg > incomingProg + 0.001 {
                    merged.ebookProgress = existing.ebookProgress
                    merged.epubLocator = existing.epubLocator ?? merged.epubLocator
                } else if incomingProg > existingProg + 0.001 {
                    merged.epubLocator = merged.epubLocator ?? existing.epubLocator
                } else {
                    merged.epubLocator = existing.epubLocator ?? merged.epubLocator
                }
                merged.ebookFileURL = preferredEbookURL(existing: existing, incoming: incoming)

                if existing.currentTime > merged.currentTime + 1.0 {
                    merged.currentTime = existing.currentTime
                    merged.lastUpdate = existing.lastUpdate
                }
            }
            merged.linkedAudiobookStableId = existing.linkedAudiobookStableId ?? merged.linkedAudiobookStableId
            merged.linkedAudiobookChapterOffset = existing.linkedAudiobookChapterOffset

            if merged.chapters?.isEmpty ?? true, let existingChapters = existing.chapters, !existingChapters.isEmpty {
                merged.chapters = existingChapters
            }

            return merged
        }
    }

    private func buildSeriesFromBooks(_ books: [Book], libraryId: String, providerId: UUID) -> [Series] {
        let seriesBooks = books.compactMap { book -> (name: String, sequence: String?, id: String)? in
            guard let info = book.seriesInfo, !info.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (info.name, info.sequence, book.id)
        }

        guard !seriesBooks.isEmpty else { return [] }

        var grouped: [String: [String]] = [:]
        var sequences: [String: [String: String]] = [:]

        for entry in seriesBooks {
            grouped[entry.name, default: []].append(entry.id)
            if let seq = entry.sequence {
                var map = sequences[entry.name, default: [:]]
                map[entry.id] = seq
                sequences[entry.name] = map
            }
        }

        return grouped.map { name, ids in
            Series(
                id: "derived_\(providerId.uuidString)_\(libraryId)_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))",
                name: name,
                description: nil,
                books: ids,
                bookSequences: sequences[name] ?? [:],
                bookCount: ids.count,
                libraryId: libraryId,
                providerId: providerId
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshBookDetails(for book: Book) async {
        guard let provider = providerConnections[book.providerId] else { return }

        do {
            var fetchedBook = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)

            let hasLinkedEbook = await MainActor.run {
                library.books.contains { $0.mediaType == .ebook && $0.linkedAudiobookStableId == book.stableId }
            }

            if !hasLinkedEbook {
                await ChapterMetadataCache.cache(fetchedBook)

                if fetchedBook.source == .booklore, fetchedBook.mediaType == .audiobook,
                    let bookloreProvider = provider as? BookloreProvider
                {
                    if fetchedBook.chapters?.isEmpty ?? true,
                        let cached = ReaderArtifactsStore.shared.loadCachedChapters(bookId: fetchedBook.stableId)
                            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: fetchedBook.id),
                        !cached.isEmpty
                    {
                        fetchedBook.chapters = cached
                    }

                    let bookDuration = fetchedBook.duration ?? 0
                    let existingChapters = fetchedBook.chapters ?? []
                    let chaptersAdequate = existingChapters.count > 1 || (existingChapters.count == 1 && bookDuration <= 1800)
                    if !chaptersAdequate, let session = try? await bookloreProvider.startPlaybackSession(for: fetchedBook) {
                        let resolvedChapters: [Chapter]
                        if session.chapters.count > 1 || (session.chapters.count == 1 && bookDuration <= 1800) {
                            resolvedChapters = session.chapters
                        } else if session.audioTracks.count > 1 {
                            var offset: Double = 0
                            resolvedChapters = session.audioTracks.enumerated().map { i, info in
                                let start = info.startOffset > 0 ? info.startOffset : offset
                                let end = start + max(info.duration, 0)
                                offset = end
                                return Chapter(
                                    id: "grimmory_track_\(info.index)",
                                    start: start,
                                    end: end,
                                    title: info.title ?? "Track \(i + 1)",
                                    index: i
                                )
                            }
                        } else {
                            resolvedChapters = []
                        }
                        if !resolvedChapters.isEmpty {
                            fetchedBook.chapters = resolvedChapters
                            ReaderArtifactsStore.shared.saveCachedChapters(bookId: fetchedBook.stableId, chapters: resolvedChapters)
                            if fetchedBook.id != fetchedBook.stableId {
                                ReaderArtifactsStore.shared.saveCachedChapters(bookId: fetchedBook.id, chapters: resolvedChapters)
                            }
                            AppLogger.general.info(
                                "[Grimmory] Synthesized \(resolvedChapters.count) chapters bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: fetchedBook.stableId))"
                            )
                        }
                    }
                }
            }

            let enrichedBook = await MetadataManager.shared.enrichBookWithStoredMetadata(fetchedBook)
            var preservedBook = applyLocalRelationshipOverrides([enrichedBook], existingBooks: [book]).first ?? enrichedBook

            if hasLinkedEbook {
                if let renamed = ReaderArtifactsStore.shared.loadCachedChapters(bookId: preservedBook.stableId)
                    ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: preservedBook.id),
                    !renamed.isEmpty
                {
                    preservedBook.chapters = renamed
                }
            }

            await MainActor.run {
                if let index = library.books.firstIndex(where: { $0.uniqueId == book.uniqueId }) {
                    library.books[index] = preservedBook
                }

                if session.currentBook?.uniqueId == book.uniqueId {
                    session.currentBook = preservedBook
                }

                saveMetadata()

                if !(preservedBook.chapters?.isEmpty ?? true) || preservedBook.linkedAudiobookStableId != nil {
                    let bookToSave = preservedBook
                    Task(priority: .utility) { await bookStore.upsertBooks([bookToSave]) }
                }
            }
        } catch {
            AppLogger.general.error("Error refreshing book details: \(error)")
        }
    }

    nonisolated struct MetadataCache: Codable {
        let libraries: [Library]
        let allBooks: [Book]
        let collections: [Collection]
        let series: [Series]
    }

    private static func defaultMetadataFileURL() -> URL? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documentsDirectory.appendingPathComponent("enve_metadata.json")
    }

    func saveMetadataChanges() {
        saveMetadata()
    }

    func saveMetadata(immediate: Bool = false) {
        guard let url = metadataFileURL else { return }
        let cache = MetadataCache(
            libraries: libraries,
            allBooks: [],
            collections: collections,
            series: series
        )
        metadataSaveTask?.cancel()

        if immediate {
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.general.error("Failed to save metadata immediately: \(error)")
            }
            return
        }

        metadataSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
                AppLogger.general.info(
                    "Saved metadata: \(cache.libraries.count) libraries, \(cache.series.count) series, \(cache.collections.count) collections"
                )
            } catch {
                AppLogger.general.error("Failed to save metadata: \(error)")
            }
        }
    }

    private func saveMetadataAsync() async {
        guard let url = metadataFileURL else { return }
        metadataSaveTask?.cancel()
        let cache = MetadataCache(libraries: libraries, allBooks: [], collections: collections, series: series)
        await Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
                AppLogger.general.info("Saved metadata async (\(cache.libraries.count) libraries, \(cache.series.count) series)")
            } catch {
                AppLogger.general.error("Failed to save metadata async: \(error)")
            }
        }.value
    }

    func loadCachedMetadata() async -> Bool {
        AppLogger.general.info("Attempting to load cached metadata...")

        guard let url = metadataFileURL else {
            AppLogger.general.info("Could not get metadata file URL")
            return false
        }

        let data: Data? = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value

        guard let data else {
            AppLogger.general.info("No cached metadata file found")
            return false
        }

        let cache: MetadataCache
        do {
            cache = try JSONDecoder().decode(MetadataCache.self, from: data)
        } catch {
            AppLogger.general.error("Failed to decode cached metadata: \(error)")
            return false
        }

        await MainActor.run {
            var seenMetaIds = Set<String>()
            let dedupedBooks = cache.allBooks.filter { seenMetaIds.insert($0.uniqueId).inserted }
            if dedupedBooks.count < cache.allBooks.count {
                AppLogger.general.info("Removed \(cache.allBooks.count - dedupedBooks.count) duplicate book(s) from metadata cache")
            }

            self.libraries = cache.libraries
            if library.books.isEmpty {
                library.books = dedupedBooks
            }
            self.collections = cache.collections
            self.series = cache.series
            AppLogger.general.info(
                "Loaded metadata: \(cache.libraries.count) libraries, \(library.books.count) books (in memory), \(cache.collections.count) collections, \(cache.series.count) series"
            )
        }

        await MainActor.run {
            progress.loadPersistedProgressIfMigrationPending()
        }

        let books = library.books
        let progressMap: [String: (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)]
        if books.count > 12000 {
            AppLogger.general.info("📊 [Startup] Skipping full local progress preload for large library (\(books.count) books)")
            progressMap = [:]
        } else {
            progressMap = await preloadStoredProgressMap(for: books)
        }

        await MainActor.run {
            if !progressMap.isEmpty {
                library.books = self.applyLocalProgressOverrides(library.books, preloadedStoredProgress: progressMap)
            }
        }

        return true
    }
}
