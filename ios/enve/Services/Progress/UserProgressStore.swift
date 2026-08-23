import Foundation
import Logging

@MainActor
@Observable
final class UserProgressStore {
    static let shared = UserProgressStore()

    private(set) var entries: [String: UserMediaProgress] = [:]

    var syncProgressToServer: Bool = true {
        didSet {
            defaults.set(syncProgressToServer, forKey: Self.syncEnabledKey)
        }
    }

    private let library: LibraryBookCache
    private let session: any CurrentBookSession
    private let bookStore: any ProgressRepository
    private let providerConnections: any ProviderConnectionAccessing
    private let progressCache: BookProgressStore
    private let defaults: UserDefaults

    private var legacyPendingSyncProgress: [String: UserMediaProgress] = [:]
    private var userProgressSaveTask: Task<Void, Never>?
    private let progressFileURL: URL?

    private static let syncEnabledKey = "sync_progress_to_server"
    private static let legacyPendingSyncKey = "pending_sync_progress"
    private static let progressFilename = "enve_user_progress.json"
    private static let legacyProgressMigratedKey = "enve.legacyProgressMigratedToBookStoreV1"

    init(
        library: LibraryBookCache = AppState.shared.libraryCache,
        session: any CurrentBookSession = AppState.shared,
        bookStore: any ProgressRepository = AppState.shared.bookStore,
        providerConnections: any ProviderConnectionAccessing = AppState.shared.providerConnections,
        progressFileURL: URL? = nil,
        progressCache: BookProgressStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.library = library
        self.session = session
        self.bookStore = bookStore
        self.providerConnections = providerConnections
        self.progressCache = progressCache
        self.defaults = defaults
        self.progressFileURL = progressFileURL ?? Self.defaultProgressFileURL()

        if defaults.object(forKey: Self.syncEnabledKey) == nil {
            syncProgressToServer = true
        } else {
            syncProgressToServer = defaults.bool(forKey: Self.syncEnabledKey)
        }
        loadPendingSyncProgress()
    }

    var isLegacyProgressMigrationPending: Bool {
        !defaults.bool(forKey: Self.legacyProgressMigratedKey)
    }

    func loadPersistedProgressIfMigrationPending() {
        guard isLegacyProgressMigrationPending else { return }
        loadPersistedProgress()
    }

    func progress(forUniqueId uniqueId: String) -> UserMediaProgress? {
        entries[uniqueId]
    }

    var allProgress: [UserMediaProgress] {
        Array(entries.values)
    }

    func transferProgress(fromUniqueId oldUniqueId: String, to book: Book) {
        guard let existing = entries[oldUniqueId] else { return }
        entries[book.uniqueId] = UserMediaProgress(
            id: book.id,
            libraryItemId: book.id,
            providerId: book.providerId,
            episodeId: nil,
            currentTime: existing.currentTime,
            progress: existing.progress,
            isFinished: existing.isFinished,
            duration: existing.duration,
            lastUpdate: existing.lastUpdate,
            ebookProgress: nil
        )
        entries.removeValue(forKey: oldUniqueId)
    }

    func forget(keys: some Sequence<String>) {
        for key in keys {
            entries.removeValue(forKey: key)
        }
    }

    func retain(uniqueIds: Set<String>) {
        entries = entries.filter { uniqueIds.contains($0.key) }
        legacyPendingSyncProgress = legacyPendingSyncProgress.filter { uniqueIds.contains($0.key) }
        persistLegacyPendingSyncProgress()
    }

    func removeAll() {
        entries.removeAll()
        legacyPendingSyncProgress.removeAll()
        defaults.removeObject(forKey: Self.legacyPendingSyncKey)
    }

    func update(_ progress: UserMediaProgress, preserveEbookPosition: Bool = true) {
        if let existingProgress = entries[progress.uniqueId],
            existingProgress.lastUpdate > progress.lastUpdate
        {
            return
        }
        let latestBookUpdate = [
            library.hot.book(uniqueId: progress.uniqueId)?.lastUpdate,
            library.uniqueIdIndex[progress.uniqueId].flatMap { index in
                library.books.indices.contains(index) ? library.books[index].lastUpdate : nil
            },
            session.currentBook?.uniqueId == progress.uniqueId ? session.currentBook?.lastUpdate : nil,
        ].compactMap { $0 }.max()
        if let latestBookUpdate, latestBookUpdate > progress.lastUpdate {
            return
        }
        entries[progress.uniqueId] = progress
        let targetEbookProgress: (Book) -> Double? = { book in
            if let ebookProgress = progress.ebookProgress {
                return Book.normalizedFractionProgress(ebookProgress)
            }
            if book.isStorytellerReadAloud {
                return Book.normalizedFractionProgress(progress.progress)
            }
            guard book.mediaType == .ebook else { return book.ebookProgress }
            return Book.normalizedFractionProgress(progress.progress)
        }
        let applyEbookPosition: (inout Book) -> Void = { book in
            book.ebookProgress = targetEbookProgress(book)
            if progress.ebookProgress == nil,
                book.isStorytellerReadAloud,
                let locator = StorytellerProvider.localAudioLocatorJSONString(
                    for: book,
                    progression: progress.progress
                )
            {
                book.epubLocator = locator
            }
        }

        var updatedSnapshot: Book?
        if let bookIndex = library.uniqueIdIndex[progress.uniqueId], bookIndex < library.books.count {
            var updated = library.books[bookIndex]
            updated.currentTime = progress.currentTime
            updated.isFinished = progress.isFinished
            updated.lastUpdate = progress.lastUpdate
            applyEbookPosition(&updated)
            library.replaceExisting(updated)
            updatedSnapshot = updated
        } else if var updated = library.hot.book(uniqueId: progress.uniqueId) {
            updated.currentTime = progress.currentTime
            updated.isFinished = progress.isFinished
            updated.lastUpdate = progress.lastUpdate
            applyEbookPosition(&updated)
            updatedSnapshot = updated
        }
        if let updatedSnapshot {
            library.hot.insert(updatedSnapshot)
        }

        if let existing = session.currentBook, existing.uniqueId == progress.uniqueId {
            var updated = existing
            updated.currentTime = progress.currentTime
            updated.isFinished = progress.isFinished
            updated.lastUpdate = progress.lastUpdate
            applyEbookPosition(&updated)
            session.currentBook = updated
            library.hot.insert(updated)
        }

        persist()

        let capturedProgress = progress
        let capturedPreserveEbookPosition = preserveEbookPosition
        let store = bookStore
        Task.detached(priority: .utility) {
            await store.updateProgress(
                uniqueId: capturedProgress.uniqueId,
                currentTime: capturedProgress.currentTime,
                isFinished: capturedProgress.isFinished,
                lastUpdate: capturedProgress.lastUpdate
            )
            await store.upsertProgress(
                bookUniqueId: capturedProgress.uniqueId,
                stableId: capturedProgress.libraryItemId,
                currentTime: capturedProgress.currentTime,
                duration: capturedProgress.duration,
                ebookProgress: capturedProgress.ebookProgress,
                epubLocator: nil,
                isFinished: capturedProgress.isFinished,
                lastUpdate: capturedProgress.lastUpdate,
                hideFromContinue: false,
                preserveEbookPosition: capturedPreserveEbookPosition
            )
        }
    }

    func applyAuthoritativeServerProgress(
        _ updates: [(progress: UserMediaProgress, book: Book)]
    ) async {
        await applyAuthoritativeServerActivity(
            updates.map {
                (
                    progress: $0.progress,
                    book: $0.book,
                    hideFromContinue: $0.book.hideFromContinue,
                    epubLocator: $0.book.epubLocator,
                    serverReadStatus: $0.book.serverReadStatus
                )
            }
        )
    }

    func applyAuthoritativeServerActivity(
        _ updates: [(
            progress: UserMediaProgress,
            book: Book,
            hideFromContinue: Bool,
            epubLocator: String?,
            serverReadStatus: String?
        )]
    ) async {
        guard !updates.isEmpty else { return }
        var updatedSnapshots: [Book] = []
        updatedSnapshots.reserveCapacity(updates.count)

        library.performBatch {
            for update in updates {
                let progress = update.progress
                entries[progress.uniqueId] = progress

                if let index = library.uniqueIdIndex[progress.uniqueId], index < library.books.count {
                    library.books[index].currentTime = progress.currentTime
                    library.books[index].ebookProgress = progress.ebookProgress
                    library.books[index].epubLocator = update.epubLocator
                    library.books[index].isFinished = progress.isFinished
                    library.books[index].lastUpdate = progress.lastUpdate
                    library.books[index].hideFromContinue = update.hideFromContinue
                    library.books[index].serverReadStatus = update.serverReadStatus
                    updatedSnapshots.append(library.books[index])
                } else if var cached = library.hot.book(uniqueId: progress.uniqueId) {
                    cached.currentTime = progress.currentTime
                    cached.ebookProgress = progress.ebookProgress
                    cached.epubLocator = update.epubLocator
                    cached.isFinished = progress.isFinished
                    cached.lastUpdate = progress.lastUpdate
                    cached.hideFromContinue = update.hideFromContinue
                    cached.serverReadStatus = update.serverReadStatus
                    updatedSnapshots.append(cached)
                }

                if var selected = session.currentBook, selected.uniqueId == progress.uniqueId {
                    selected.currentTime = progress.currentTime
                    selected.ebookProgress = progress.ebookProgress
                    selected.epubLocator = update.epubLocator
                    selected.isFinished = progress.isFinished
                    selected.lastUpdate = progress.lastUpdate
                    selected.hideFromContinue = update.hideFromContinue
                    selected.serverReadStatus = update.serverReadStatus
                    session.currentBook = selected
                }
            }
        }

        if !updatedSnapshots.isEmpty {
            library.hot.insertMany(updatedSnapshots)
        }
        persist()
        progressCache.saveProgress(
            updates.map { (book: $0.book, progress: $0.progress) }
        )

        let persistenceUpdates = updates.map {
            AuthoritativeProgressUpdate(
                bookUniqueId: $0.book.uniqueId,
                stableId: $0.book.stableId,
                currentTime: $0.progress.currentTime,
                duration: $0.progress.duration,
                ebookProgress: $0.progress.ebookProgress,
                epubLocator: $0.epubLocator,
                isFinished: $0.progress.isFinished,
                lastUpdate: $0.progress.lastUpdate,
                hideFromContinue: $0.hideFromContinue,
                serverReadStatus: $0.serverReadStatus
            )
        }
        await bookStore.applyAuthoritativeProgress(persistenceUpdates)
    }

    func resetToBeginning(for book: Book) {
        let hasTextPosition =
            book.mediaType == .ebook
            || book.isReadAloudBook
            || book.epub3Features?.hasMediaOverlay == true

        let zeroed = UserMediaProgress(
            id: UUID().uuidString,
            libraryItemId: book.id,
            providerId: book.providerId,
            episodeId: nil,
            currentTime: 0,
            progress: 0,
            isFinished: false,
            duration: book.duration ?? 0,
            lastUpdate: Date(),
            ebookProgress: hasTextPosition ? 0 : nil
        )

        entries[zeroed.uniqueId] = zeroed
        persist()

        entries.removeValue(forKey: book.stableId)
        PendingSyncQueueStore.shared.remove(stableId: book.stableId)

        let resetBook = library.mutateBook(uniqueId: book.uniqueId) { updated in
            updated.currentTime = 0
            updated.isFinished = false
            updated.lastUpdate = zeroed.lastUpdate
            updated.epubLocator = nil
            if hasTextPosition {
                updated.ebookProgress = 0
            }
        }
        if let resetBook {
            library.hot.insert(resetBook)
            Task(priority: .utility) {
                let store = bookStore
                await store.updateProgress(
                    uniqueId: resetBook.uniqueId,
                    currentTime: 0,
                    isFinished: false,
                    lastUpdate: zeroed.lastUpdate
                )
                await store.upsertProgress(
                    bookUniqueId: resetBook.uniqueId,
                    stableId: resetBook.stableId,
                    currentTime: 0,
                    duration: resetBook.duration ?? 0,
                    ebookProgress: hasTextPosition ? 0 : nil,
                    epubLocator: nil,
                    isFinished: false,
                    lastUpdate: zeroed.lastUpdate,
                    hideFromContinue: false,
                    preserveEbookPosition: false
                )
            }
        }

        progressCache.clearProgress(for: book.stableId)
        progressCache.clearProgress(for: book.id)

        let playback = ActivePlayback.controller
        if playback.snapshot.currentBook?.uniqueId == book.uniqueId {
            playback.seek(to: 0)
        }

        if syncProgressToServer {
            var syncBook = resetBook ?? book
            syncBook.currentTime = 0
            syncBook.isFinished = false
            syncBook.lastUpdate = zeroed.lastUpdate
            syncBook.epubLocator = nil
            if hasTextPosition { syncBook.ebookProgress = 0 }
            Task {
                await SyncCoordinator.shared.pushProgress(
                    book: syncBook,
                    forceImmediate: true,
                    domain: hasTextPosition ? .ebook : .audiobook
                )
            }
        }

    }

    func toggleFinished(for book: Book) {
        let newFinished = !book.isFinished
        let hasTextPosition = book.mediaType == .ebook || book.hasEPUB3MediaOverlay

        let progress = UserMediaProgress(
            id: UUID().uuidString,
            libraryItemId: book.id,
            providerId: book.providerId,
            episodeId: nil,
            currentTime: newFinished ? (book.duration ?? 0) : 0,
            progress: newFinished ? 1.0 : 0.0,
            isFinished: newFinished,
            duration: book.duration ?? 0,
            lastUpdate: Date(),
            ebookProgress: hasTextPosition ? (newFinished ? 1 : 0) : nil
        )

        update(progress)
        if book.isStorytellerReadAloud {
            let locator =
                newFinished
                ? StorytellerProvider.readAloudBoundaryLocatorJSONString(progression: 1)
                : nil
            library.mutateBook(uniqueId: book.uniqueId) { $0.epubLocator = locator }
        }
        SmartCollectionStore.shared.refresh()

        if syncProgressToServer {
            var syncBook = library.bookInMemory(uniqueId: book.uniqueId) ?? book
            syncBook.currentTime = progress.currentTime
            syncBook.isFinished = newFinished
            syncBook.lastUpdate = progress.lastUpdate
            if hasTextPosition { syncBook.ebookProgress = newFinished ? 1 : 0 }
            Task {
                await SyncCoordinator.shared.pushProgress(
                    book: syncBook,
                    forceImmediate: true,
                    domain: hasTextPosition ? .ebook : .audiobook
                )
            }
        }
    }

    private func loadPendingSyncProgress() {
        if let data = defaults.data(forKey: Self.legacyPendingSyncKey),
            let decoded = try? JSONDecoder().decode([String: UserMediaProgress].self, from: data)
        {
            legacyPendingSyncProgress = decoded
        }
    }

    private func persistLegacyPendingSyncProgress() {
        guard !legacyPendingSyncProgress.isEmpty else {
            defaults.removeObject(forKey: Self.legacyPendingSyncKey)
            return
        }
        guard let data = try? JSONEncoder().encode(legacyPendingSyncProgress) else { return }
        defaults.set(data, forKey: Self.legacyPendingSyncKey)
    }

    func retryPendingSyncs() async {
        guard syncProgressToServer else { return }

        var migratedKeys: [String] = []
        for (legacyKey, progress) in legacyPendingSyncProgress {
            guard var book = library.books.first(where: {
                $0.uniqueId == progress.uniqueId || $0.id == progress.libraryItemId
            }) else { continue }
            let isEbook = progress.ebookProgress != nil || book.mediaType == .ebook
            book.currentTime = progress.currentTime
            book.ebookProgress = progress.ebookProgress
            book.isFinished = progress.isFinished
            book.lastUpdate = progress.lastUpdate
            SyncCoordinator.shared.enqueuePendingSync(
                book: book,
                position: progress.currentTime,
                duration: progress.duration,
                serverItemId: book.partKey ?? book.id,
                domain: isEbook ? .ebook : .audiobook,
                progress: isEbook ? (progress.ebookProgress ?? progress.progress) : progress.progress,
                locator: isEbook ? book.epubLocator : nil,
                isFinished: progress.isFinished
            )
            migratedKeys.append(legacyKey)
        }
        for key in migratedKeys {
            legacyPendingSyncProgress.removeValue(forKey: key)
        }
        persistLegacyPendingSyncProgress()
        await SyncCoordinator.shared.flushPendingSyncs()

        let grimmoryBooks = library.books.filter { providerConnections.provider(for: $0.providerId) is BookloreProvider }
        await AnnotationSyncService.shared.flushAllPending(books: grimmoryBooks)
    }

    func progress(for book: Book, episodeId: String? = nil) -> UserMediaProgress? {
        if let episodeId = episodeId {
            let key = "\(book.providerId)_\(book.id)-\(episodeId)"
            return entries[key]
        }
        return entries[book.uniqueId]
    }

    func migrateLegacyProgressFileIfNeeded() async {
        guard !defaults.bool(forKey: Self.legacyProgressMigratedKey) else { return }

        guard let url = progressFileURL,
            let data = try? Data(contentsOf: url)
        else {
            defaults.set(true, forKey: Self.legacyProgressMigratedKey)
            return
        }

        do {
            let decoded = try JSONDecoder().decode([String: UserMediaProgress].self, from: data)
            if !decoded.isEmpty {
                let entries = decoded.map { uniqueId, progress in
                    (
                        bookUniqueId: uniqueId,
                        stableId: progress.libraryItemId,
                        currentTime: progress.currentTime,
                        duration: progress.duration,
                        isFinished: progress.isFinished,
                        lastUpdate: progress.lastUpdate
                    )
                }
                await bookStore.importLegacyProgress(entries)
                applyUserProgressMap(decoded)
            }
            defaults.set(true, forKey: Self.legacyProgressMigratedKey)
            AppLogger.general.info("legacy progress migration v1 completed for \(decoded.count) item(s)")
        } catch {
            AppLogger.general.error("legacy progress migration v1 deferred - decode failed: \(error). File preserved.")

        }
    }

    private static func defaultProgressFileURL() -> URL? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documentsDirectory.appendingPathComponent(Self.progressFilename)
    }

    func persist(immediate: Bool = false) {
        guard let url = progressFileURL else { return }
        let snapshot = entries

        if immediate {
            userProgressSaveTask?.cancel()
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.general.error("Failed to save user progress immediately: \(error)")
            }
            return
        }

        userProgressSaveTask?.cancel()
        let task = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.general.error("Failed to save user progress: \(error)")
            }
        }
        userProgressSaveTask = task
    }

    private func applyUserProgressMap(_ decoded: [String: UserMediaProgress]) {
        entries = decoded
        AppLogger.general.info("Loaded \(decoded.count) user progress items")
        guard !decoded.isEmpty else { return }

        var books = library.books
        var indexByUniqueId = [String: Int](minimumCapacity: books.count)
        for (i, book) in books.enumerated() {
            indexByUniqueId[book.uniqueId] = i
        }
        var didChange = false
        for (id, progress) in decoded {
            guard let idx = indexByUniqueId[id] else { continue }
            books[idx].currentTime = progress.currentTime
            books[idx].progress = progress.progress
            books[idx].isFinished = progress.isFinished
            didChange = true
        }
        if didChange {
            let priorSuppress = library.suppressNotifications
            library.suppressNotifications = true
            defer { library.suppressNotifications = priorSuppress }
            library.books = books
        }
    }

    private func loadPersistedProgress() {
        guard let url = progressFileURL,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: UserMediaProgress].self, from: data)
        else {
            return
        }
        applyUserProgressMap(decoded)
    }
}
