import Foundation
import Logging

@MainActor
final class StorytellerSyncStrategy: ProviderSyncStrategy {
    let id = "storyteller"
    let displayName = "Storyteller"

    private let minimumServerSyncInterval: TimeInterval = 60
    private var lastSyncTime: Date?
    private let playbackState: any PlaybackStateProvider
    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let catalogRepository: any CatalogReconciling
    private let pendingSync: PendingSyncQueueStore
    private let mirrorCheckpoints: ServerMirrorCheckpointStore
    private let lastOpened: LastOpenedBookStore
    private let storytellerPositions: StorytellerPositionSyncService
    private let isEbookReaderOpen: @MainActor () -> Bool
    // Resolved on demand so registration does not construct the session's progress or catalog owners.
    private let progress: @MainActor () -> UserProgressStore
    private let catalog: @MainActor () -> LibraryCatalogCoordinator

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        catalogRepository: any CatalogReconciling,
        playbackState: any PlaybackStateProvider = ActivePlayback.controller,
        pendingSync: PendingSyncQueueStore = .shared,
        mirrorCheckpoints: ServerMirrorCheckpointStore = .shared,
        lastOpened: LastOpenedBookStore = .shared,
        storytellerPositions: StorytellerPositionSyncService = .shared,
        isEbookReaderOpen: @escaping @MainActor () -> Bool = { SyncCoordinator.shared.isEbookReaderOpen },
        progress: @escaping @MainActor () -> UserProgressStore = { .shared },
        catalog: @escaping @MainActor () -> LibraryCatalogCoordinator = { .shared }
    ) {
        self.providerConnections = providerConnections
        self.books = books
        self.catalogRepository = catalogRepository
        self.playbackState = playbackState
        self.pendingSync = pendingSync
        self.mirrorCheckpoints = mirrorCheckpoints
        self.lastOpened = lastOpened
        self.storytellerPositions = storytellerPositions
        self.isEbookReaderOpen = isEbookReaderOpen
        self.progress = progress
        self.catalog = catalog
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        let now = Date()
        if !force,
            let lastSyncTime,
            now.timeIntervalSince(lastSyncTime) < minimumServerSyncInterval
        {
            return .zero
        }
        lastSyncTime = now

        let connections = providerConnections.activeConnections(of: .storyteller)
        guard !connections.isEmpty else { return .zero }

        var pulled = 0
        var failedBackends: [String] = []
        var pushed = 0
        var catalogChanged = false

        for connection in connections {
            guard let provider = providerConnections.provider(for: connection.id) as? StorytellerProvider else {
                continue
            }

            do {
                let remoteBooks = try await provider.fetchMirrorSnapshot(
                    forceRefresh: !launchOptimized
                )
                let catalog = await reconcileCatalog(
                    remoteBooks,
                    connection: connection
                )
                catalogChanged = catalog.changed || catalogChanged
                let localById = Dictionary(
                    uniqueKeysWithValues: catalog.localBooks
                        .filter { $0.libraryId == "storyteller-library" && $0.readAloudSourceStableId == nil }
                        .map { ($0.id, $0) }
                )
                let pendingIds = pendingBookIds(providerId: connection.id)
                var updates:
                    [(
                        progress: UserMediaProgress,
                        book: Book,
                        hideFromContinue: Bool,
                        epubLocator: String?,
                        serverReadStatus: String?
                    )] = []

                for remoteBook in remoteBooks {
                    if Task.isCancelled {
                        return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends, wasCancelled: true)
                    }
                    guard let localBook = localById[remoteBook.id],
                        !pendingIds.uniqueIds.contains(localBook.uniqueId),
                        !pendingIds.stableIds.contains(localBook.stableId),
                        !isActivelyReading(localBook)
                    else {
                        continue
                    }

                    let reconciliation: StorytellerSnapshotReconciliation
                    do {
                        reconciliation = try await storytellerPositions.reconcileSnapshot(
                            for: remoteBook,
                            through: provider
                        )
                    } catch {
                        if error is CancellationError || (error as? URLError)?.code == .cancelled {
                            return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends, wasCancelled: true)
                        }
                        if !failedBackends.contains(connection.name) { failedBackends.append(connection.name) }
                        AppLogger.sync.error(
                            "Storyteller pending position could not be reconciled bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: remoteBook.stableId)): \(error.localizedDescription)"
                        )
                        continue
                    }
                    if reconciliation.pushedPendingPosition {
                        pushed += 1
                    }

                    let update = activityUpdate(
                        remoteBook: remoteBook,
                        localBook: localBook,
                        reconciliation: reconciliation
                    )
                    if activityDiffers(update, from: localBook) {
                        updates.append(update)
                    }
                }

                await progress().applyAuthoritativeServerActivity(updates)
                pulled += updates.count

                let scope = ServerMirrorScope(
                    connectionId: connection.id,
                    accountKey: ServerMirrorFingerprint.accountKey(for: provider.connection),
                    libraryId: nil,
                    domain: .activity
                )
                mirrorCheckpoints.commitCompleteSnapshot(
                    scope: scope,
                    syncLevel: .fullSnapshot,
                    fingerprint: activityFingerprint(remoteBooks),
                    itemCount: remoteBooks.count
                )
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends, wasCancelled: true)
                }
                if !failedBackends.contains(connection.name) { failedBackends.append(connection.name) }
                AppLogger.sync.error(
                    "Storyteller mirror sync failed providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: connection.id.uuidString)): \(error.localizedDescription)"
                )
            }
        }

        if pulled > 0 || catalogChanged {
            NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
        }
        return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends)
    }

    private func reconcileCatalog(
        _ remoteBooks: [Book],
        connection: ServerConnection
    ) async -> (changed: Bool, localBooks: [Book]) {
        let scope = ServerMirrorScope(
            connectionId: connection.id,
            accountKey: ServerMirrorFingerprint.accountKey(for: connection),
            libraryId: nil,
            domain: .catalog
        )
        let fingerprint = ServerMirrorFingerprint.catalogSnapshot(remoteBooks)
        let localBooks = await books.books(
            source: Book.BookSource.storyteller.rawValue,
            providerId: connection.id
        )
        let localIds = Set(
            localBooks.lazy.filter {
                $0.libraryId == "storyteller-library" && $0.readAloudSourceStableId == nil
            }.map(\.id)
        )
        let remoteIds = Set(remoteBooks.map(\.id))
        let checkpoint = mirrorCheckpoints.checkpoint(for: scope)
        let needsReconciliation = checkpoint?.fingerprint != fingerprint || localIds != remoteIds

        if needsReconciliation {
            let startedAt = Date()
            await catalog().refreshConnectionLibraries(
                providerId: connection.id,
                forceFullReconciliation: true,
                refreshCollections: false
            )
            guard
                let cursor = await catalogRepository.loadCursor(
                    providerId: connection.id,
                    libraryId: "storyteller-library"
                ), cursor.lastFullReconciledAt >= startedAt
            else {
                AppLogger.sync.error(
                    "Storyteller catalog snapshot could not be committed providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: connection.id.uuidString))"
                )
                return (false, localBooks)
            }
        } else {
            await catalogRepository.markFullReconciled(
                providerId: connection.id,
                libraryId: "storyteller-library",
                at: Date()
            )
        }

        mirrorCheckpoints.commitCompleteSnapshot(
            scope: scope,
            syncLevel: .fullSnapshot,
            fingerprint: fingerprint,
            itemCount: remoteBooks.count
        )
        if needsReconciliation {
            let refreshed = await books.books(
                source: Book.BookSource.storyteller.rawValue,
                providerId: connection.id
            )
            return (true, refreshed)
        }
        return (false, localBooks)
    }

    private func activityUpdate(
        remoteBook: Book,
        localBook: Book,
        reconciliation: StorytellerSnapshotReconciliation
    ) -> (
        progress: UserMediaProgress,
        book: Book,
        hideFromContinue: Bool,
        epubLocator: String?,
        serverReadStatus: String?
    ) {

        var authoritative = reconciliation.authoritative?.position
        if remoteBook.isStorytellerReadAloud || localBook.isStorytellerReadAloud,
            let staged = authoritative,
            StorytellerPositionSyncService.isAudioLocator(staged.locatorJSON)
        {
            authoritative = nil
        }
        let locator = authoritative?.locatorJSON ?? remoteBook.epubLocator
        let locatorProgress = Book.progressFromEbookLocator(locator) ?? 0
        var fraction =
            authoritative?.progression
            ?? Book.normalizedFractionProgress(remoteBook.ebookProgress)
            ?? locatorProgress
        var status = remoteBook.serverReadStatus

        if reconciliation.pushedPendingPosition {
            status = fraction >= Book.finishedProgressThreshold ? "READ" : (fraction > 0 ? "READING" : status)
        }
        if status == "READ" {
            fraction = 1
        }
        fraction = min(max(fraction, 0), 1)

        let isFinished = status == "READ" || fraction >= Book.finishedProgressThreshold
        let hideFromContinue = status == "TO_READ" || isFinished
        let duration = remoteBook.duration ?? localBook.duration ?? 0
        let currentTime: TimeInterval
        let ebookProgress: Double?
        if remoteBook.mediaType == .audiobook {
            currentTime = duration > 0 ? duration * fraction : fraction
            ebookProgress = nil
        } else {
            currentTime = 0
            ebookProgress = locator == nil && status != "READ" ? nil : fraction
        }

        return (
            UserMediaProgress(
                id: "storyteller-\(remoteBook.id)",
                libraryItemId: remoteBook.id,
                providerId: remoteBook.providerId,
                episodeId: nil,
                currentTime: currentTime,
                progress: fraction,
                isFinished: isFinished,
                duration: duration,
                lastUpdate: authoritative?.observedAt ?? remoteBook.lastUpdate,
                ebookProgress: ebookProgress
            ),
            localBook,
            hideFromContinue,
            locator,
            status
        )
    }

    private func activityDiffers(
        _ update: (
            progress: UserMediaProgress,
            book: Book,
            hideFromContinue: Bool,
            epubLocator: String?,
            serverReadStatus: String?
        ),
        from book: Book
    ) -> Bool {
        let progress = update.progress
        let localEbookProgress = Book.normalizedFractionProgress(book.ebookProgress)
        let remoteEbookProgress = Book.normalizedFractionProgress(progress.ebookProgress)
        return abs(book.currentTime - progress.currentTime) > 0.01
            || localEbookProgress != remoteEbookProgress
            || book.epubLocator != update.epubLocator
            || book.isFinished != progress.isFinished
            || book.lastUpdate != progress.lastUpdate
            || book.hideFromContinue != update.hideFromContinue
            || book.serverReadStatus != update.serverReadStatus
    }

    private func activityFingerprint(_ books: [Book]) -> String {
        ServerMirrorFingerprint.activity(
            books.map {
                "\($0.id)|\($0.serverReadStatus ?? "")|\($0.ebookProgress ?? 0)|\($0.epubLocator ?? "")|\($0.lastUpdate.timeIntervalSince1970)"
            }
        )
    }

    private func pendingBookIds(providerId: UUID) -> (uniqueIds: Set<String>, stableIds: Set<String>) {
        let stableIds = Set(
            pendingSync.entries.values
                .filter { $0.source == .storyteller }
                .map(\.stableId)
        )
        return ([], stableIds)
    }

    private func isActivelyReading(_ book: Book) -> Bool {
        if playbackState.currentBook?.stableId == book.stableId {
            return true
        }
        return isEbookReaderOpen()
            && lastOpened.stableId == book.stableId
    }
}
