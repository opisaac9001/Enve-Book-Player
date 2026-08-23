import Foundation
import Logging

@MainActor
final class SiloActivitySyncStrategy: ProviderSyncStrategy {
    let id = "silo-activity"
    let displayName = "Silo (Activity)"

    private let minimumServerSyncInterval: TimeInterval = 60
    private var lastSyncTime: Date?
    private var cursorUnsupportedConnections: Set<UUID> = []
    private let playbackState: any PlaybackStateProvider = ActivePlayback.controller
    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying
    ) {
        self.providerConnections = providerConnections
        self.books = books
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

                if cursorUnsupportedConnections.contains(connection.id) {
                    pulled += try await pullSnapshot(
                        providerId: connection.id,
                        through: provider
                    )
                } else {
                    do {
                        pulled += try await pullCursorDeltas(
                            scope: scope,
                            forceFullReplay: force,
                            through: provider
                        )
                    } catch SiloProgressDeltaError.unsupported {
                        cursorUnsupportedConnections.insert(connection.id)
                        pulled += try await pullSnapshot(
                            providerId: connection.id,
                            through: provider
                        )
                    }
                }
            } catch is CancellationError {
                return ProviderSyncResult(pulled: pulled, pushed: pushed)
            } catch {
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
        return ProviderSyncResult(pulled: pulled, pushed: pushed)
    }

    private func pullCursorDeltas(
        scope: ServerMirrorScope,
        forceFullReplay: Bool,
        through provider: SiloProvider
    ) async throws -> Int {
        let checkpoint = ServerMirrorCheckpointStore.shared.checkpoint(for: scope)
        let isFullReplay = forceFullReplay || checkpoint?.cursor == nil
        if isFullReplay {
            return try await pullCompleteCursorState(
                scope: scope,
                through: provider
            )
        }

        var cursor = checkpoint?.cursor ?? "0"
        var pulled = 0
        var pageCount = 0

        while true {
            try Task.checkCancellation()
            let page = try await provider.fetchProgressDelta(since: cursor)
            let result = await apply(
                page.progress,
                providerId: scope.connectionId,
                reconcileMissing: false
            )
            guard result.didApplyPage else { return pulled }
            pulled += result.appliedCount

            ServerMirrorCheckpointStore.shared.commit(
                scope: scope,
                syncLevel: .nativeCursorDelta,
                cursor: page.nextCursor,
                fingerprint: ServerMirrorFingerprint.cursor(page.nextCursor),
                itemCount: page.progress.count
            )

            if page.nextCursor == cursor { return pulled }
            cursor = page.nextCursor
            pageCount += 1
            if pageCount > 10_000 {
                throw ProviderError.serverError("Silo progress cursor exceeded the safety limit")
            }
        }
    }

    private func pullCompleteCursorState(
        scope: ServerMirrorScope,
        through provider: SiloProvider
    ) async throws -> Int {
        var cursor = "0"
        var progress: [UserMediaProgress] = []
        var pageCount = 0

        while true {
            try Task.checkCancellation()
            let page = try await provider.fetchProgressDelta(since: cursor)
            progress.append(contentsOf: page.progress)
            let previousCursor = cursor
            cursor = page.nextCursor
            if cursor == previousCursor { break }
            pageCount += 1
            if pageCount > 10_000 {
                throw ProviderError.serverError("Silo progress cursor exceeded the safety limit")
            }
        }

        let result = await apply(
            progress,
            providerId: scope.connectionId,
            reconcileMissing: true
        )
        guard result.didApplyPage else { return 0 }

        ServerMirrorCheckpointStore.shared.commit(
            scope: scope,
            syncLevel: .nativeCursorDelta,
            cursor: cursor,
            fingerprint: ServerMirrorFingerprint.cursor(cursor),
            itemCount: progress.count
        )
        return result.appliedCount
    }

    private func pullSnapshot(
        providerId: UUID,
        through provider: SiloProvider
    ) async throws -> Int {
        let progress = try await provider.fetchUserMediaProgress(libraryId: "")
        let result = await apply(
            progress,
            providerId: providerId,
            reconcileMissing: false
        )
        guard result.didApplyPage else { return 0 }
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
            PendingSyncQueueStore.shared.entries.values
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

        await UserProgressStore.shared.applyAuthoritativeServerProgress(updates)
        return (true, updates.count)
    }
}
