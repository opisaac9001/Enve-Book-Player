import Combine
import CryptoKit
import Foundation
import Logging

@MainActor
struct LibraryRecoveryStores {
    var mirrorCheckpoints: ServerMirrorCheckpointStore
    var userCollections: UserCollectionStore
    var smartCollections: SmartCollectionStore
    var pendingSync: PendingSyncQueueStore
    var purgeCachedArtifacts: (Book) -> Void
    var purgeDownloadArtifacts: (String) -> Void
    var cleanupAlignmentCaches: ([Book]) -> Void

    static func live() -> LibraryRecoveryStores {
        LibraryRecoveryStores(
            mirrorCheckpoints: .shared,
            userCollections: .shared,
            smartCollections: .shared,
            pendingSync: .shared,
            purgeCachedArtifacts: { book in
                ReaderArtifactsStore.shared.clearCachedChapters(bookId: book.stableId)
                ReaderArtifactsStore.shared.clearCachedChapters(bookId: book.id)
                ReaderArtifactsStore.shared.clearBookmarks(bookId: book.id)
                BookProgressStore.shared.clearProgress(for: book.stableId)
                BookProgressStore.shared.clearProgress(for: book.id)
                BookProgressStore.shared.remove(stableId: book.stableId)
                Task { await AppCache.shared.removeCoverData(for: book) }

                if book.epub3Features?.hasMediaOverlay == true || book.source == .storyteller {
                    LocalEbookImporter.shared.removeReadaloudCache(forBookId: book.id, stableId: book.stableId)
                }
            },
            purgeDownloadArtifacts: { diskId in
                let storage = LocalStorageManager.shared
                try? storage.deleteDownloadedAudiobook(diskId)
                try? storage.deleteMetadataOverride(for: diskId)
            },
            cleanupAlignmentCaches: { books in
                if #available(iOS 26.0, *) {
                    StoryAlignService.shared.cleanupOrphanedCaches(allBooks: books)
                }
            }
        )
    }
}

@MainActor
@Observable
final class LibraryRecoveryCoordinator {
    static let shared = LibraryRecoveryCoordinator()

    var pendingBookStoreDeletions = Set<String>()

    private let library: LibraryBookCache
    private let session: any CurrentBookSession
    private let presentation: AppPresentationState
    private let startup: any LibraryStartupGating
    private let catalog: LibraryCatalogCoordinator
    private let progress: UserProgressStore
    private let bookStore: BookStoreRepository
    private let providerConnections: any ProviderConnectionEditing
    private let stores: LibraryRecoveryStores

    private static let legacyEbookLinksMigratedKey = "enve.legacyEbookLinksMigratedToBookStoreV1"
    private static let legacyEbookRelationshipStoreKey = "ebook_audiobook_relationships"

    init(
        library: LibraryBookCache = AppState.shared.libraryCache,
        session: any CurrentBookSession = AppState.shared,
        presentation: AppPresentationState = AppState.shared.presentation,
        startup: any LibraryStartupGating = AppState.shared,
        catalog: LibraryCatalogCoordinator = .shared,
        progress: UserProgressStore = .shared,
        bookStore: BookStoreRepository = AppState.shared.bookStore,
        providerConnections: any ProviderConnectionEditing = AppState.shared.providerConnections,
        stores: LibraryRecoveryStores = .live()
    ) {
        self.library = library
        self.session = session
        self.presentation = presentation
        self.startup = startup
        self.catalog = catalog
        self.progress = progress
        self.bookStore = bookStore
        self.providerConnections = providerConnections
        self.stores = stores
    }

    func runStartupMigrations() async {
        await migrateLegacyEbookRelationshipsIfNeeded()
        await reconcileDuplicateStorytellerConnectionsIfNeeded()
    }

    private func reconcileDuplicateStorytellerConnectionsIfNeeded() async {
        let activeStoryteller = providerConnections.connections.filter { $0.type == .storyteller && !$0.isArchived }
        let groups = Dictionary(grouping: activeStoryteller) { normalizedStorytellerEndpoint($0.url) ?? $0.url.lowercased() }
        let duplicateGroups = groups.values.filter { $0.count > 1 }
        guard !duplicateGroups.isEmpty else { return }

        var updatedConnections = providerConnections.connections
        var migratedBooks: [Book] = []
        var oldUniqueIdsToRemove = Set<String>()
        var migratedPairs: [(old: Book, new: Book)] = []

        for group in duplicateGroups {
            let winner = await preferredStorytellerConnection(in: group)
            let losers = group.filter { $0.id != winner.id }
            guard !losers.isEmpty else { continue }

            var mergedWinner = winner
            for connection in group where connection.id != winner.id {
                mergeStorytellerConnectionFields(from: connection, into: &mergedWinner)
            }

            if let index = updatedConnections.firstIndex(where: { $0.id == winner.id }) {
                updatedConnections[index] = mergedWinner
            }

            let existingWinnerBooks = await bookStore.books(source: Book.BookSource.storyteller.rawValue, providerId: winner.id)
            let existingByBookId = Dictionary(uniqueKeysWithValues: existingWinnerBooks.map { ($0.id, $0) })

            for loser in losers {
                let loserBooks = await bookStore.books(source: Book.BookSource.storyteller.rawValue, providerId: loser.id)
                for loserBook in loserBooks {
                    let existing = existingByBookId[loserBook.id]
                    let migrated = migratedStorytellerBook(loserBook, existing: existing, winnerId: winner.id)
                    migratedBooks.append(migrated)
                    oldUniqueIdsToRemove.insert(loserBook.uniqueId)
                    migratedPairs.append((old: loserBook, new: migrated))
                }

                if let index = updatedConnections.firstIndex(where: { $0.id == loser.id }) {
                    updatedConnections[index].isArchived = true
                    updatedConnections[index].isConnected = false
                }
            }

            AppLogger.general.info(
                "Merged \(losers.count) duplicate Storyteller connection(s) into connectionDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: winner.id.uuidString))"
            )
        }

        if !migratedBooks.isEmpty {
            await bookStore.upsertBooks(migratedBooks)
            for pair in migratedPairs {
                BookProgressStore.shared.migrateProgress(from: pair.old, to: pair.new)
            }
            if !oldUniqueIdsToRemove.isEmpty {
                await bookStore.deleteBooks(uniqueIds: oldUniqueIdsToRemove)
            }
            migrateInMemoryStorytellerBooks(migratedBooks, removing: oldUniqueIdsToRemove)
        }

        providerConnections.connections = updatedConnections
    }

    private func preferredStorytellerConnection(in group: [ServerConnection]) async -> ServerConnection {
        var countsByConnection: [UUID: Int] = [:]
        for connection in group {
            let storeCount = await bookStore.bookCount(providerId: connection.id, mediaType: nil)
            let memoryCount = library.books.filter { $0.source == .storyteller && $0.providerId == connection.id }.count
            countsByConnection[connection.id] = max(storeCount, memoryCount)
        }

        return group.sorted { lhs, rhs in
            let lhsCount = countsByConnection[lhs.id] ?? 0
            let rhsCount = countsByConnection[rhs.id] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            if (lhs.token?.isEmpty == false) != (rhs.token?.isEmpty == false) { return lhs.token?.isEmpty == false }
            return (lhs.lastVerified ?? .distantPast) > (rhs.lastVerified ?? .distantPast)
        }.first ?? group[0]
    }

    private func mergeStorytellerConnectionFields(from source: ServerConnection, into target: inout ServerConnection) {
        if target.token?.isEmpty ?? true { target.token = source.token }
        if target.password?.isEmpty ?? true { target.password = source.password }
        if target.username?.isEmpty ?? true { target.username = source.username }
        if target.userId?.isEmpty ?? true { target.userId = source.userId }
        if target.customHeaders?.isEmpty ?? true { target.customHeaders = source.customHeaders }
        target.secretCustomHeaderNames.formUnion(source.secretCustomHeaderNames)
        if source.isConnected { target.isConnected = true }
        if let sourceVerified = source.lastVerified,
            sourceVerified > (target.lastVerified ?? .distantPast)
        {
            target.lastVerified = sourceVerified
        }
        if let sourceLibraries = source.selectedLibraryIds, !sourceLibraries.isEmpty {
            if let targetLibraries = target.selectedLibraryIds, !targetLibraries.isEmpty {
                target.selectedLibraryIds = targetLibraries.union(sourceLibraries)
            } else {
                target.selectedLibraryIds = sourceLibraries
            }
        }
    }

    private func migratedStorytellerBook(_ book: Book, existing: Book?, winnerId: UUID) -> Book {
        var base = existing ?? book
        if book.lastUpdate > base.lastUpdate {
            base.currentTime = book.currentTime
            base.isFinished = book.isFinished
            base.lastUpdate = book.lastUpdate
            base.ebookProgress = book.ebookProgress
            base.epubLocator = book.epubLocator
            base.serverReadStatus = book.serverReadStatus
        } else {
            if base.ebookProgress == nil { base.ebookProgress = book.ebookProgress }
            if base.epubLocator?.isEmpty ?? true { base.epubLocator = book.epubLocator }
            if base.serverReadStatus?.isEmpty ?? true { base.serverReadStatus = book.serverReadStatus }
        }
        if base.chapters?.isEmpty ?? true { base.chapters = book.chapters }
        if base.ebookFileURL == nil { base.ebookFileURL = book.ebookFileURL }
        return copyStorytellerBook(base, providerId: winnerId)
    }

    private func copyStorytellerBook(_ book: Book, providerId: UUID) -> Book {
        var copy = Book(
            id: book.id,
            ratingKey: book.ratingKey,
            title: book.title,
            author: book.author,
            authors: book.authors,
            narrator: book.narrator,
            thumb: book.thumb,
            partKey: book.partKey,
            duration: book.duration,
            chapters: book.chapters,
            currentChapterIndex: book.currentChapterIndex,
            source: .storyteller,
            backendId: providerId.uuidString,
            trackIndex: book.trackIndex,
            filePath: book.filePath,
            audioFileIno: book.audioFileIno,
            audioFileInos: book.audioFileInos,
            audioTracks: book.audioTracks,
            isPodcastEpisode: book.isPodcastEpisode,
            episodeId: book.episodeId,
            podcastLibraryItemId: book.podcastLibraryItemId,
            podcastName: book.podcastName,
            mediaType: book.mediaType,
            ebookFormat: book.ebookFormat,
            epubLocator: book.epubLocator,
            ebookProgress: book.ebookProgress,
            ebookFileURL: book.ebookFileURL,
            linkedAudiobookStableId: normalizedStorytellerStableId(book.linkedAudiobookStableId, providerId: providerId),
            linkedAudiobookChapterOffset: book.linkedAudiobookChapterOffset,
            hideFromContinue: book.hideFromContinue,
            epub3Features: book.epub3Features,
            hasAlternateFormat: book.hasAlternateFormat,
            readAloudSourceStableId: normalizedStorytellerStableId(book.readAloudSourceStableId, providerId: providerId),
            description: book.description,
            series: book.series,
            seriesNumber: book.seriesNumber,
            publishedYear: book.publishedYear,
            genres: book.genres,
            publisher: book.publisher,
            isbn: book.isbn,
            asin: book.asin,
            addedAt: book.addedAt,
            libraryName: book.libraryName,
            backendName: book.backendName,
            copyright: book.copyright,
            language: book.language,
            encodingTool: book.encodingTool,
            currentTime: book.currentTime,
            isFinished: book.isFinished,
            lastUpdate: book.lastUpdate,
            providerId: providerId,
            libraryId: book.libraryId
        )
        copy.seriesSequence = book.seriesSequence
        copy.serverReadStatus = book.serverReadStatus
        return copy
    }

    private func migrateInMemoryStorytellerBooks(_ migratedBooks: [Book], removing oldUniqueIds: Set<String>) {
        guard !migratedBooks.isEmpty || !oldUniqueIds.isEmpty else { return }
        var booksByUniqueId: [String: Book] = [:]
        booksByUniqueId.reserveCapacity(library.books.count)
        for book in library.books {
            booksByUniqueId[book.uniqueId] = book
        }
        for oldUniqueId in oldUniqueIds {
            booksByUniqueId.removeValue(forKey: oldUniqueId)
            library.hot.remove(uniqueId: oldUniqueId)
        }
        for book in migratedBooks {
            booksByUniqueId[book.uniqueId] = book
            library.hot.insert(book)
        }
        library.books = Array(booksByUniqueId.values)
    }

    private func normalizedStorytellerStableId(_ value: String?, providerId: UUID) -> String? {
        guard let value, value.hasPrefix("storyteller:") else { return value }
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return value }
        return "storyteller:\(providerId.uuidString):\(parts[2])"
    }

    private func normalizedStorytellerEndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return nil
        }
        let portValue = components.port
        let usesDefaultPort = (scheme == "http" && portValue == 80) || (scheme == "https" && portValue == 443)
        let port = usesDefaultPort ? "" : portValue.map { ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return "\(scheme)://\(host)\(port)\(path.isEmpty ? "" : "/\(path)")"
    }

    func rescueOrphanedDownloads() async {
        let storage = LocalStorageManager.shared

        reconcileRescuedDownloads()

        let allDiskIds = await Task.detached(priority: .utility) {
            Set(storage.downloadedAudiobookIds())
        }.value

        guard !allDiskIds.isEmpty else { return }

        let knownBooks = library.books
        let bookKeys: [(downloadKey: String, stableId: String, id: String)] = knownBooks.map {
            ($0.downloadKey, $0.stableId, $0.id)
        }
        let knownSanitizedIds: Set<String> = await Task.detached(priority: .utility) {
            let sanitize: (String) -> String = { input in
                input
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: "\\", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "?", with: "-")
                    .replacingOccurrences(of: "&", with: "-")
                    .replacingOccurrences(of: "=", with: "-")
            }
            var ids = Set<String>()
            for key in bookKeys {
                ids.insert(sanitize(key.downloadKey))
                ids.insert(sanitize(key.stableId))
                ids.insert(sanitize(key.id))
            }
            return ids
        }.value

        let orphanedDiskIds = allDiskIds.subtracting(knownSanitizedIds)

        guard !orphanedDiskIds.isEmpty else { return }

        AppLogger.general.info("[Recovery] Found \(orphanedDiskIds.count) orphaned download(s) on disk - rescuing...")

        let localProviderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let rescueLibraryId = "rescued-downloads"
        var rescuedBooks: [Book] = []

        for diskId in orphanedDiskIds {
            guard let audioFiles = storage.localAudiobookFilesIfExists(bookId: diskId),
                !audioFiles.isEmpty
            else {
                continue
            }

            let metadata = try? storage.loadMetadataOverride(OfflineBookMetadata.self, for: diskId)

            if let metadata,
                let serverBook = serverBookMatchingRescuedDownload(metadata),
                !storage.isAudiobookDownloaded(serverBook.downloadKey),
                storage.reassociateDownload(from: diskId, to: serverBook.downloadKey)
            {
                saveOfflineMetadata(for: serverBook, preserving: metadata, storage: storage)
                AppLogger.general.info(
                    "[Recovery] Reassociated orphaned download bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: serverBook.stableId))"
                )
                continue
            }

            var tracks: [AudioTrack] = []
            var runningOffset: TimeInterval = 0
            for (index, fileURL) in audioFiles.enumerated() {
                if let metaTracks = metadata?.audioTracks, index < metaTracks.count {
                    tracks.append(metaTracks[index])
                    runningOffset += metaTracks[index].duration
                } else {
                    let track = AudioTrack(
                        id: "\(diskId)_track_\(index)",
                        index: index,
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        filePath: fileURL.path,
                        contentUrl: nil,
                        duration: 0,
                        startOffset: runningOffset,
                        fileSize: (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64),
                        format: fileURL.pathExtension
                    )
                    tracks.append(track)
                }
            }

            let coverPath = storage.coverOverridePath(for: diskId)
            let hasCover = FileManager.default.fileExists(atPath: coverPath.path)

            let bookId = metadata?.id ?? diskId
            let book = Book(
                id: bookId,
                ratingKey: bookId,
                title: metadata?.title ?? diskId.replacingOccurrences(of: "-", with: " "),
                author: metadata?.author,
                narrator: metadata?.narrator,
                thumb: hasCover ? coverPath.path : nil,
                partKey: diskId,
                duration: metadata?.duration ?? tracks.reduce(0) { $0 + $1.duration },
                chapters: metadata?.chapters,
                currentChapterIndex: nil,
                source: .local,
                backendId: rescueLibraryId,
                trackIndex: 0,
                filePath: audioFiles.first?.path,
                audioFileIno: nil,
                audioFileInos: nil,
                audioTracks: tracks.isEmpty ? nil : tracks,
                currentTime: 0,
                isFinished: false,
                lastUpdate: Date(),
                providerId: localProviderId,
                libraryId: rescueLibraryId
            )

            rescuedBooks.append(book)
            AppLogger.general.info(
                "[Recovery] Rescued bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) files=\(audioFiles.count)"
            )
        }

        guard !rescuedBooks.isEmpty else { return }

        var booksToPersist: [Book] = []
        await MainActor.run {
            if !catalog.libraries.contains(where: { $0.id == rescueLibraryId }) {
                catalog.libraries.append(
                    Library(
                        id: rescueLibraryId,
                        name: "Rescued Downloads",
                        type: "local",
                        providerId: localProviderId
                    )
                )
            }

            let existingIds = Set(library.books.map { $0.uniqueId })
            let newBooks = rescuedBooks.filter { !existingIds.contains($0.uniqueId) }
            if !newBooks.isEmpty {
                var updated = library.books
                updated.append(contentsOf: newBooks)
                library.books = updated
                presentation.orphanedBooks = newBooks
                booksToPersist = newBooks
                library.hot.insertMany(newBooks)
                AppLogger.general.info("[Recovery] Added \(newBooks.count) rescued book(s) to library. Total: \(library.books.count)")

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    presentation.showOrphanedBooksSheet = true
                }
            }
        }

        if !booksToPersist.isEmpty {
            await bookStore.upsertBooks(booksToPersist)
        }
    }

    func reconcileRescuedDownloads() {
        let storage = LocalStorageManager.shared
        let rescuedBooks = library.books.filter { $0.libraryId == "rescued-downloads" }

        for rescuedBook in rescuedBooks {
            let diskId = rescuedBook.partKey ?? rescuedBook.downloadKey
            guard let metadata = try? storage.loadMetadataOverride(OfflineBookMetadata.self, for: diskId),
                let serverBook = serverBookMatchingRescuedDownload(metadata),
                !storage.isAudiobookDownloaded(serverBook.downloadKey)
            else {
                continue
            }
            matchRescuedBook(rescuedBook, to: serverBook)
        }
    }

    private func serverBookMatchingRescuedDownload(_ metadata: OfflineBookMetadata) -> Book? {
        guard metadata.source != .local else { return nil }

        let candidates = library.books.filter {
            $0.source == metadata.source
                && $0.id == metadata.id
                && $0.mediaType != .ebook
                && $0.libraryId != "rescued-downloads"
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func saveOfflineMetadata(
        for book: Book,
        preserving priorMetadata: OfflineBookMetadata?,
        fallbackTracks: [AudioTrack]? = nil,
        storage: LocalStorageManager
    ) {
        let priorTracks = priorMetadata?.audioTracks ?? fallbackTracks
        let localFiles = storage.localAudiobookFilesIfExists(bookId: book.downloadKey) ?? []
        let localTracks = localFiles.enumerated().map { index, fileURL in
            let prior = priorTracks.flatMap { tracks in
                tracks.indices.contains(index) ? tracks[index] : nil
            }
            return AudioTrack(
                id: "\(book.downloadKey)_track_\(index)",
                index: index,
                title: prior?.title ?? fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path,
                contentUrl: nil,
                duration: prior?.duration ?? 0,
                startOffset: prior?.startOffset ?? 0,
                fileSize: (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64),
                format: fileURL.pathExtension,
                bitrate: prior?.bitrate,
                sampleRate: prior?.sampleRate,
                channels: prior?.channels
            )
        }
        let metadata = OfflineBookMetadata(
            id: book.id,
            stableId: book.stableId,
            title: book.title,
            author: book.author ?? priorMetadata?.author,
            narrator: book.narrator ?? priorMetadata?.narrator,
            duration: book.duration ?? priorMetadata?.duration,
            chapters: book.chapters?.isEmpty == false ? book.chapters : priorMetadata?.chapters,
            audioTracks: localTracks.isEmpty ? (book.audioTracks ?? priorTracks) : localTracks,
            coverURLString: book.coverURL?.absoluteString ?? priorMetadata?.coverURLString,
            source: book.source
        )
        try? storage.saveMetadataOverride(metadata, for: book.downloadKey)
    }

    func matchRescuedBook(_ rescuedBook: Book, to serverBook: Book) {
        let rescuedKey = rescuedBook.downloadKey
        let serverKey = serverBook.downloadKey
        let diskId = rescuedBook.partKey ?? rescuedKey
        let preservedMetadata = try? LocalStorageManager.shared.loadMetadataOverride(
            OfflineBookMetadata.self,
            for: diskId
        )

        AppLogger.general.info(
            "Matching rescued bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: rescuedBook.stableId)) to serverBookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: serverBook.stableId))"
        )

        let rescuedUniqueId = rescuedBook.uniqueId
        let serverUniqueId = serverBook.uniqueId

        progress.transferProgress(fromUniqueId: rescuedUniqueId, to: serverBook)

        var updatedServerBook: Book?
        if rescuedBook.currentTime > 0,
            let serverIdx = library.books.firstIndex(where: { $0.uniqueId == serverUniqueId })
        {
            var updated = library.books[serverIdx]
            updated.currentTime = rescuedBook.currentTime
            updated.isFinished = rescuedBook.isFinished
            updated.lastUpdate = Date()
            library.books[serverIdx] = updated
            library.hot.insert(updated)
            updatedServerBook = updated
        }

        if let savedProgress = BookProgressStore.shared.loadProgress(for: rescuedBook) {
            BookProgressStore.shared.saveProgress(
                for: serverBook,
                progress: savedProgress.progress,
                duration: savedProgress.duration
            )
        }

        library.books = library.books.filter { $0.uniqueId != rescuedUniqueId }
        library.hot.remove(uniqueId: rescuedUniqueId)
        presentation.orphanedBooks.removeAll { $0.uniqueId == rescuedUniqueId }

        if let serverProgress = progress.progress(forUniqueId: serverUniqueId) {
            var queuedBook = updatedServerBook ?? serverBook
            queuedBook.currentTime = serverProgress.currentTime
            queuedBook.isFinished = serverProgress.isFinished
            queuedBook.lastUpdate = serverProgress.lastUpdate
            SyncCoordinator.shared.enqueuePendingSync(
                book: queuedBook,
                position: serverProgress.currentTime,
                duration: serverProgress.duration,
                serverItemId: queuedBook.partKey ?? queuedBook.id,
                isFinished: serverProgress.isFinished
            )
        }

        cleanupRescuedLibraryIfEmpty()
        progress.persist()
        catalog.saveMetadata()

        let rescuedId = rescuedUniqueId
        let updated = updatedServerBook
        let store = bookStore
        Task.detached(priority: .utility) {
            await store.deleteBooks(uniqueIds: [rescuedId])
            if let updated {
                await store.upsertBooks([updated])
            }
        }

        let storage = LocalStorageManager.shared
        let moved = storage.reassociateDownload(from: diskId, to: serverKey)
        if !moved {
            if !storage.reassociateDownload(from: rescuedKey, to: serverKey) {
                storage.reassociateDownload(from: rescuedBook.id, to: serverKey)
            }
        }
        if storage.isAudiobookDownloaded(serverKey) {
            saveOfflineMetadata(
                for: serverBook,
                preserving: preservedMetadata,
                fallbackTracks: rescuedBook.audioTracks,
                storage: storage
            )
        }

        AppLogger.general.info(
            "Matched rescued bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: serverBook.stableId)); file move queued"
        )
    }

    func dismissOrphanedBook(_ book: Book) {
        presentation.orphanedBooks.removeAll { $0.uniqueId == book.uniqueId }
    }

    func deleteOrphanedBook(_ book: Book) {
        let diskId = book.partKey ?? book.downloadKey
        let removedId = book.uniqueId

        library.books = library.books.filter { $0.uniqueId != removedId }
        library.hot.remove(uniqueId: removedId)
        presentation.orphanedBooks.removeAll { $0.uniqueId == removedId }
        progress.forget(keys: [removedId])

        cleanupRescuedLibraryIfEmpty()
        catalog.saveMetadata()

        let store = bookStore
        Task.detached(priority: .utility) {
            await store.deleteBooks(uniqueIds: [removedId])
        }

        stores.purgeDownloadArtifacts(diskId)
    }

    private func cleanupRescuedLibraryIfEmpty() {
        let rescueLibraryId = "rescued-downloads"
        let remaining = library.books.filter { $0.libraryId == rescueLibraryId }
        if remaining.isEmpty {
            catalog.libraries.removeAll { $0.id == rescueLibraryId }
        }
    }

    func pruneStaleBooksCacheEarly() {
        guard !library.books.isEmpty else { return }
        let activeConnections = providerConnections.connections.filter { !$0.isArchived }
        let validProviderIds = Set(activeConnections.map { $0.id })
        guard !validProviderIds.isEmpty || !activeConnections.isEmpty else { return }

        let allowedLibraryIdsByProvider: [UUID: Set<String>?] = Dictionary(
            activeConnections.map { ($0.id, $0.selectedLibraryIds) },
            uniquingKeysWith: { _, new in new }
        )

        let beforeCount = library.books.count
        let beforeUniqueIds = Set(library.books.map { $0.uniqueId })

        library.books.removeAll { book in
            if book.source == .local || book.source == .smb { return false }
            guard validProviderIds.contains(book.providerId) else { return true }
            if let allowed = allowedLibraryIdsByProvider[book.providerId] ?? nil, !allowed.isEmpty {
                return !allowed.contains(book.libraryId)
            }
            return false
        }

        let removedIds = beforeUniqueIds.subtracting(Set(library.books.map { $0.uniqueId }))
        guard !removedIds.isEmpty else { return }

        AppLogger.general.info(
            "📊 [EarlyPrune] Removed \(beforeCount - library.books.count) stale books (\(beforeCount) → \(library.books.count)) mem=\(AppState.currentMemoryMB())MB"
        )

        pendingBookStoreDeletions.formUnion(removedIds)
    }

    func pruneDisconnectedProviderData() {
        guard startup.isStartupCacheLoaded else { return }

        let activeConnections = providerConnections.connections.filter { !$0.isArchived }
        let validProviderIds = Set(activeConnections.map { $0.id })
        stores.mirrorCheckpoints.retainConnections(validProviderIds)

        AppLogger.general.info(
            "📊 [Prune] \(activeConnections.count) active connections, \(validProviderIds.count) valid providers, \(library.books.count) books before prune"
        )

        let allowedLibraryIdsByProvider: [UUID: Set<String>?] = Dictionary(
            activeConnections.map { connection in
                (connection.id, connection.selectedLibraryIds)
            },
            uniquingKeysWith: { _, new in new }
        )

        let beforeLibraries = catalog.libraries.count
        let beforeBooks = library.books.count
        let beforeCollections = catalog.collections.count
        let beforeSeries = catalog.series.count
        let beforeBookUniqueIds = Set(library.books.map { $0.uniqueId })

        let localProviderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        library.suppressNotifications = true
        defer { library.suppressNotifications = false }

        catalog.libraries.removeAll { library in
            if library.providerId == localProviderId || library.type == "local" { return false }
            guard validProviderIds.contains(library.providerId) else { return true }
            if let allowed = allowedLibraryIdsByProvider[library.providerId] ?? nil, !allowed.isEmpty {
                return !allowed.contains(library.id)
            }
            return false
        }

        let orphanedEbooks = library.books.filter { book in
            guard book.source != .local, book.source != .smb else { return false }
            guard book.mediaType == .ebook else { return false }
            if !validProviderIds.contains(book.providerId) { return true }
            if let allowed = allowedLibraryIdsByProvider[book.providerId] ?? nil, !allowed.isEmpty {
                return !allowed.contains(book.libraryId)
            }
            return false
        }

        library.books.removeAll { book in
            if book.source == .local || book.source == .smb { return false }
            guard validProviderIds.contains(book.providerId) else { return true }
            if let allowed = allowedLibraryIdsByProvider[book.providerId] ?? nil, !allowed.isEmpty {
                return !allowed.contains(book.libraryId)
            }
            return false
        }

        let remainingBookIds = Set(library.books.map { $0.id })
        let localTitles = Set(library.books.filter { $0.source == .local }.map { $0.title.lowercased() })
        for orphan in orphanedEbooks {
            guard !remainingBookIds.contains(orphan.id),
                !localTitles.contains(orphan.title.lowercased())
            else { continue }
            if let cachedURL = orphan.ebookFileURL ?? LocalEbookImporter.shared.cachedEbook(forBookId: orphan.id),
                FileManager.default.fileExists(atPath: cachedURL.path),
                let localURL = LocalEbookImporter.shared.migrateToLocal(cachedURL: cachedURL)
            {
                if let localBook = persistMigratedLocalEbook(orphan, localURL: localURL) {
                    library.books.append(localBook)
                    AppLogger.general.debug(
                        "[Prune] Migrated cached ebook bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: orphan.stableId))"
                    )
                }
            }
        }
        catalog.collections.removeAll { collection in
            if let providerId = collection.providerId {
                return !validProviderIds.contains(providerId)
            }
            return false
        }
        catalog.series.removeAll { !validProviderIds.contains($0.providerId) && $0.providerId != localProviderId }

        progress.retain(uniqueIds: Set(library.books.map { $0.uniqueId }))

        let didChange =
            beforeLibraries != catalog.libraries.count || beforeBooks != library.books.count || beforeCollections != catalog.collections.count
            || beforeSeries != catalog.series.count

        if didChange {
            library.changes.send(())
            catalog.saveMetadata()
            progress.persist()

            let removedBookIds = beforeBookUniqueIds.subtracting(Set(library.books.map { $0.uniqueId }))
            if !removedBookIds.isEmpty {
                pendingBookStoreDeletions.formUnion(removedBookIds)
            }
            AppLogger.general.info(
                "📊 [Prune] Pruned: \(beforeBooks) → \(library.books.count) books, \(beforeLibraries) → \(catalog.libraries.count) libs, \(beforeCollections) → \(catalog.collections.count) collections"
            )
        }

        let activeProviderIdStrings: Set<String> = Set(activeConnections.map { $0.id.uuidString })
        let restrictedLibraryIds: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: activeConnections.compactMap { connection in
                guard let allowed = connection.selectedLibraryIds, !allowed.isEmpty else { return nil }
                return (connection.id.uuidString, allowed)
            }
        )
        let store = bookStore
        Task(priority: .utility) { [weak self] in
            let removed = await store.deleteBooksFromInactiveLibraries(
                validProviderIds: activeProviderIdStrings,
                restrictedLibraryIds: restrictedLibraryIds
            )
            guard removed > 0 else { return }
            AppLogger.general.info("📊 [Prune] Purged \(removed) orphan books from BookStore after library/connection removal")
            self?.library.changes.send(())
        }
    }

    private func persistMigratedLocalEbook(_ orphan: Book, localURL: URL) -> Book? {
        ensureFileSharingLibraryExists()

        let metadata = mergedLocalMetadata(for: orphan, localURL: localURL)
        let fileHash = hashFile(at: localURL) ?? orphan.stableId.replacingOccurrences(of: ":", with: "-")
        let sidecarPath = saveMigratedEbookSidecar(metadata: metadata, fileHash: fileHash, localURL: localURL)
        let relativePath = localURL.path.replacingOccurrences(of: LocalEbookImporter.shared.localEbooksRoot.path + "/", with: "")
        let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let localBookFile = LocalBookFile(
            id: "\(LocalLibraryService.fileSharingLibraryId):\(fileHash)",
            fileName: localURL.lastPathComponent,
            filePath: localURL.path,
            relativePath: relativePath,
            fileSize: fileSize,
            format: localURL.pathExtension.lowercased(),
            fileHash: fileHash,
            metadata: metadata,
            sidecarPath: sidecarPath,
            extractedAt: orphan.addedAt ?? Date()
        )

        var cachedBooks = LocalLibraryStorageStore.shared.loadBooks(libraryId: LocalLibraryService.fileSharingLibraryId)
        cachedBooks.removeAll {
            $0.id == localBookFile.id || $0.filePath == localBookFile.filePath || $0.id == orphan.id
        }
        cachedBooks.append(localBookFile)

        LocalLibraryStorageStore.shared.saveScanResult(
            LocalLibraryScanResult(
                localLibraryId: LocalLibraryService.fileSharingLibraryId,
                booksFound: cachedBooks,
                skippedFiles: [],
                scanDuration: 0,
                scannedAt: Date()
            )
        )

        var localBook = localBookFile.toBook(libraryId: LocalLibraryService.fileSharingLibraryId)
        localBook.currentTime = orphan.currentTime
        localBook.isFinished = orphan.isFinished
        localBook.lastUpdate = orphan.lastUpdate
        localBook.epubLocator = orphan.epubLocator
        localBook.ebookProgress = orphan.ebookProgress
        localBook.linkedAudiobookStableId = orphan.linkedAudiobookStableId
        localBook.linkedAudiobookChapterOffset = orphan.linkedAudiobookChapterOffset
        return localBook
    }

    private func ensureFileSharingLibraryExists() {
        if LocalLibraryStorageStore.shared.loadLibraries().contains(where: { $0.id == LocalLibraryService.fileSharingLibraryId }) {
            return
        }

        LocalLibraryStorageStore.shared.saveLibrary(
            LocalLibrary(
                id: LocalLibraryService.fileSharingLibraryId,
                name: "Drag & Drop Books",
                folderPath: LocalLibraryService.fileSharingRootURL.path,
                createdAt: Date(),
                isEnabled: true,
                type: .fileSharing
            )
        )
    }

    private func mergedLocalMetadata(for orphan: Book, localURL: URL) -> LocalBookMetadata {
        var metadata = LocalBookMetadata(title: localURL.deletingPathExtension().lastPathComponent)
        metadata.title = orphan.title.isEmpty ? metadata.title : orphan.title
        metadata.author = preferred(orphan.author, fallback: metadata.author)
        metadata.narrator = preferred(orphan.narrator, fallback: metadata.narrator)
        metadata.description = preferred(orphan.description, fallback: metadata.description)
        metadata.series = preferred(orphan.series, fallback: metadata.series)
        metadata.seriesNumber = orphan.seriesNumber ?? metadata.seriesNumber
        metadata.publishedYear = orphan.publishedYear ?? metadata.publishedYear
        metadata.genres = (orphan.genres?.isEmpty == false) ? orphan.genres : metadata.genres
        metadata.publisher = preferred(orphan.publisher, fallback: metadata.publisher)
        metadata.isbn = preferred(orphan.isbn, fallback: metadata.isbn)
        metadata.asin = preferred(orphan.asin, fallback: metadata.asin)
        metadata.duration = orphan.duration ?? metadata.duration

        if metadata.coverImagePath?.isEmpty != false,
            let orphanThumb = orphan.thumb,
            FileManager.default.fileExists(atPath: orphanThumb)
        {
            metadata.coverImagePath = orphanThumb
        }

        return metadata
    }

    private func preferred(_ primary: String?, fallback: String?) -> String? {
        if let primary, !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primary
        }
        return fallback
    }

    private func saveMigratedEbookSidecar(metadata: LocalBookMetadata, fileHash: String, localURL: URL) -> String? {
        let sidecar = LocalBookSidecar(
            metadata: metadata,
            fileHash: fileHash,
            fileName: localURL.lastPathComponent,
            format: localURL.pathExtension.lowercased()
        )
        let sidecarURL = URL(fileURLWithPath: LocalBookFile.sidecarPath(for: localURL.path))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sidecar)
            try data.write(to: sidecarURL, options: .atomic)
            return sidecarURL.path
        } catch {
            AppLogger.general.error(
                "Failed to write local ebook sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: localURL)): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func hashFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func prepareForFullDataClear() {
        pendingBookStoreDeletions.removeAll()

        DeletedBooksTombstoneStore.shared.clearAll()
        stores.mirrorCheckpoints.clearAll()
    }

    func resetBookDataState() async {
        session.currentBook = nil
        presentation.isPlayerPresented = false

        library.suppressNotifications = true
        defer { library.suppressNotifications = false }
        catalog.libraries.removeAll()
        library.books.removeAll()
        catalog.collections.removeAll()
        stores.mirrorCheckpoints.clearAll()
        stores.userCollections.clearAll()
        stores.smartCollections.clearAll()
        catalog.series.removeAll()
        progress.removeAll()
        stores.pendingSync.removeAll()

        library.changes.send(())
    }

    private struct LegacyEbookRelationship: Codable {
        let linkedAudiobookStableId: String
        let linkedAudiobookChapterOffset: Int
    }

    private func migrateLegacyEbookRelationshipsIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.legacyEbookLinksMigratedKey) else { return }
        guard let data = defaults.data(forKey: Self.legacyEbookRelationshipStoreKey) else {
            defaults.set(true, forKey: Self.legacyEbookLinksMigratedKey)
            return
        }

        do {
            let decoded = try JSONDecoder().decode([String: LegacyEbookRelationship].self, from: data)
            let links = decoded.compactMap {
                ebookStableId,
                rel -> (ebookStableId: String, audiobookStableId: String, chapterOffset: Int)? in
                guard !rel.linkedAudiobookStableId.isEmpty else { return nil }
                return (
                    ebookStableId: ebookStableId, audiobookStableId: rel.linkedAudiobookStableId,
                    chapterOffset: rel.linkedAudiobookChapterOffset
                )
            }
            if !links.isEmpty {
                await bookStore.importLegacyLinks(links)
            }
            defaults.removeObject(forKey: Self.legacyEbookRelationshipStoreKey)
            defaults.set(true, forKey: Self.legacyEbookLinksMigratedKey)
            AppLogger.general.info("legacy ebook-link migration v1 completed for \(links.count) item(s)")
        } catch {
            AppLogger.general.error("legacy ebook-link migration v1 deferred - decode failed: \(error). Blob preserved.")
        }
    }

    func flushPendingBookStoreDeletions(delaySeconds: UInt64 = 0) {
        let ids = pendingBookStoreDeletions
        pendingBookStoreDeletions.removeAll()
        guard !ids.isEmpty else { return }
        let store = bookStore
        Task.detached(priority: .utility) {
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
            AppLogger.general.info("📊 [BookStore] Starting stale-row cleanup for \(ids.count) rows")
            let idList = Array(ids)

            let chunkSize = 100
            for start in stride(from: 0, to: idList.count, by: chunkSize) {
                let end = min(start + chunkSize, idList.count)
                let chunk = Set(idList[start..<end])
                await store.deleteBooks(uniqueIds: chunk)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await Task.yield()
            }
            let storeCount = await store.bookCount()
            AppLogger.general.info("📊 [BookStore] Deleted \(ids.count) stale rows, \(storeCount) rows remain")
        }
    }

    func removeBook(_ book: Book) {
        removeBooks([book])
    }

    func removeBooks(_ booksToRemove: [Book]) {
        guard !booksToRemove.isEmpty else { return }

        let idsToRemove = Set(booksToRemove.map(\.uniqueId))
        let bookIdsToRemove = Set(booksToRemove.map(\.id))
        let stableIdsToRemove = Set(booksToRemove.map(\.stableId))

        library.suppressNotifications = true
        defer { library.suppressNotifications = false }

        library.books = library.books.filter { !idsToRemove.contains($0.uniqueId) }

        if let current = session.currentBook, idsToRemove.contains(current.uniqueId) {
            session.currentBook = nil
        }

        for i in 0..<catalog.collections.count {
            let collection = catalog.collections[i]
            let updatedBooks = collection.books.filter { !bookIdsToRemove.contains($0) }

            if updatedBooks.count != collection.books.count {
                catalog.collections[i] = Collection(
                    id: collection.id,
                    name: collection.name,
                    description: collection.description,
                    books: updatedBooks,
                    bookCount: updatedBooks.count,
                    iconName: collection.iconName,
                    color: collection.color,
                    providerId: collection.providerId,
                    parentID: collection.parentID,
                    customCoverPath: collection.customCoverPath,
                    isSystem: collection.isSystem,
                    isUserGenerated: collection.isUserGenerated
                )
            }
        }

        progress.forget(keys: stableIdsToRemove)
        for stableId in stableIdsToRemove {
            stores.pendingSync.remove(stableId: stableId)
        }

        for book in booksToRemove {
            stores.purgeCachedArtifacts(book)
        }

        stores.cleanupAlignmentCaches(library.books)

        for uid in idsToRemove {
            library.hot.remove(uniqueId: uid)
        }

        library.changes.send(())
        NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)

        catalog.saveMetadata()
        progress.persist()

        let capturedIds = idsToRemove
        let store = bookStore
        Task(priority: .utility) {
            await store.deleteBooks(uniqueIds: capturedIds)
        }

        AppLogger.general.info("Removed \(booksToRemove.count) book(s)")
    }

    func permanentlyDeleteBook(_ book: Book) {
        DeletedBooksTombstoneStore.shared.markDeleted(book.stableId, title: book.title)

        _ = LocalStorageManager.shared.deleteAudiobook(book)
        try? LocalEbookImporter.shared.deleteRemoteEbookArtifacts(forBookId: book.id)
        if #available(iOS 26.0, *) {
            StoryAlignService.shared.deleteConversions(involving: book)
        }

        try? LocalStorageManager.shared.deletePlaybackState(for: book.stableId)
        try? LocalStorageManager.shared.deletePlaybackState(for: book.id)
        try? LocalStorageManager.shared.deleteMetadataOverride(for: book.id)

        removeBook(book)

        let store = bookStore
        Task(priority: .utility) {
            if book.source == .local {
                await LocalLibraryService.shared.removeBookFromScanCache(
                    bookId: book.id,
                    libraryId: book.libraryId,
                    filePath: book.filePath
                )
                try? await LocalLibraryService.shared.deleteBookFiles(for: book)
            }
            await store.setDeleted(true, stableId: book.stableId)
        }
    }

    func restoreDeletedBook(_ stableId: String) {
        DeletedBooksTombstoneStore.shared.markRestored(stableId)
        let store = bookStore
        Task(priority: .utility) {
            await store.setDeleted(false, stableId: stableId)
        }
    }

    func restoreDeletedBooks(_ stableIds: [String]) async {
        guard !stableIds.isEmpty else { return }
        for stableId in stableIds {
            DeletedBooksTombstoneStore.shared.markRestored(stableId)
            await bookStore.setDeleted(false, stableId: stableId)
        }
        await catalog.refreshLibrary()
    }
}
