import Foundation
import Logging

@MainActor
final class SiloActivitySyncStrategy: ProviderSyncStrategy {
    let id = "silo-activity"
    let displayName = "Silo (Activity)"

    private let minimumServerSyncInterval: TimeInterval = 60
    private var lastSyncTime: Date?
    private let playbackState: any PlaybackStateProvider
    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let pendingSync: PendingSyncQueueStore
    private let mirrorCheckpoints: ServerMirrorCheckpointStore
    // Resolved on demand so registration does not construct the session's progress owner.
    private let progressStore: @MainActor () -> UserProgressStore

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        playbackState: any PlaybackStateProvider,
        pendingSync: PendingSyncQueueStore,
        mirrorCheckpoints: ServerMirrorCheckpointStore,
        progress: @escaping @MainActor () -> UserProgressStore
    ) {
        self.providerConnections = providerConnections
        self.books = books
        self.playbackState = playbackState
        self.pendingSync = pendingSync
        self.mirrorCheckpoints = mirrorCheckpoints
        self.progressStore = progress
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

        let connections = providerConnections.activeConnections(of: .silo)
        guard !connections.isEmpty else { return .zero }

        var pulled = 0
        var failedBackends: [String] = []
        let pushed = 0

        for connection in connections {
            guard let provider = providerConnections.provider(for: connection.id) as? SiloProvider else {
                continue
            }
            do {
                let profileId = try await provider.activityProfileID()
                let scope = ServerMirrorScope(
                    connectionId: connection.id,
                    accountKey: ServerMirrorFingerprint.accountKey(
                        for: provider.connection,
                        profileId: profileId
                    ),
                    libraryId: nil,
                    domain: .activity
                )
                pulled += try await pullSnapshot(scope: scope, through: provider)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends, wasCancelled: true)
                }
                if !failedBackends.contains(connection.name) { failedBackends.append(connection.name) }
                AppLogger.sync.error(
                    "Silo activity sync failed providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: connection.id.uuidString)): \(error.localizedDescription)"
                )
            }
        }

        if pulled > 0 {
            NotificationCenter.default.post(
                name: .continueListeningNeedsRefresh,
                object: nil
            )
        }
        return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends)
    }

    // Silo v2 has no progress delta feed; the cursor-paged listing is a complete snapshot of the profile.
    private func pullSnapshot(
        scope: ServerMirrorScope,
        through provider: SiloProvider
    ) async throws -> Int {
        let progress = try await provider.fetchUserMediaProgress(libraryId: "")
        let result = await apply(
            progress,
            providerId: scope.connectionId,
            reconcileMissing: true
        )
        guard result.didApplyPage else { return 0 }

        mirrorCheckpoints.commit(
            scope: scope,
            syncLevel: .fullSnapshot,
            fingerprint: ServerMirrorFingerprint.activity(
                progress.map { "\($0.libraryItemId)|\($0.currentTime)|\($0.isFinished)|\($0.lastUpdate.timeIntervalSince1970)" }
            ),
            itemCount: progress.count
        )
        return result.appliedCount
    }

    private func apply(
        _ progress: [UserMediaProgress],
        providerId: UUID,
        reconcileMissing: Bool
    ) async -> (didApplyPage: Bool, appliedCount: Int) {
        let uniqueIds = Set(progress.map(\.uniqueId))
        let booksById = await books.booksByAnyIds(uniqueIds)
        let pendingStableIds = Set(
            pendingSync.entries.values
                .filter { $0.source == .silo }
                .map(\.stableId)
        )
        var updates: [(progress: UserMediaProgress, book: Book)] = []
        updates.reserveCapacity(progress.count)

        for remote in progress {
            guard let book = booksById[remote.uniqueId],
                !pendingStableIds.contains(book.stableId),
                book.providerId == providerId,
                book.id == remote.libraryItemId,
                book.source == .silo,
                book.mediaType == .audiobook
            else {
                continue
            }
            if playbackState.currentBook?.stableId == book.stableId {
                return (false, 0)
            }
            updates.append((remote, book))
        }

        if reconcileMissing {
            let localProgressBooks = await books.booksWithProgress(
                providerId: providerId
            )
            let serverBookIds = Set(progress.map(\.libraryItemId))
            let resetDate = Date()
            for book in localProgressBooks
            where
                book.source == .silo
                && book.mediaType == .audiobook
                && !serverBookIds.contains(book.id)
                && !pendingStableIds.contains(book.stableId)
            {
                if playbackState.currentBook?.stableId == book.stableId {
                    return (false, 0)
                }
                updates.append(
                    (
                        UserMediaProgress(
                            id: book.id,
                            libraryItemId: book.id,
                            providerId: providerId,
                            episodeId: nil,
                            currentTime: 0,
                            progress: 0,
                            isFinished: false,
                            duration: book.duration ?? 0,
                            lastUpdate: resetDate,
                            ebookProgress: nil
                        ),
                        book
                    )
                )
            }
        }

        await progressStore().applyAuthoritativeServerProgress(updates)
        return (true, updates.count)
    }
}
