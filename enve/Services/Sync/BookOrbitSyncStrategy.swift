import Foundation
import Logging

@MainActor
final class BookOrbitSyncStrategy: ProviderSyncStrategy {
    let id = "bookorbit"
    let displayName = "BookOrbit"

    private let minimumServerSyncInterval: TimeInterval = 60
    private var lastSyncTime: Date?
    private let playbackState: any PlaybackStateProvider = ActivePlayback.controller
    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let bookWriter: any BookWriting

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        bookWriter: any BookWriting
    ) {
        self.providerConnections = providerConnections
        self.books = books
        self.bookWriter = bookWriter
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        let now = Date()
        if !force, let last = lastSyncTime, now.timeIntervalSince(last) < minimumServerSyncInterval {
            return .zero
        }
        lastSyncTime = now

        let connections = providerConnections.activeConnections(of: .bookOrbit)
        guard !connections.isEmpty else { return .zero }

        var pulled = 0
        var pushed = 0

        for connection in connections {
            guard let provider = providerConnections.provider(for: connection.id) as? BookOrbitProvider else {
                continue
            }
            do {
                if launchOptimized {
                    pulled += try await pullLegacyContinueSnapshot(
                        providerId: connection.id,
                        through: provider
                    )
                    pushed += await ProviderHistorySessionSync.shared.retryPending(providerId: connection.id)
                    let pendingBooks = await userDataBooks(records: [], providerId: connection.id)
                    for book in pendingBooks {
                        let result = await BookOrbitReaderArtifactSync.shared.sync(book: book, provider: provider)
                        pulled += result.pulled
                        pushed += result.pushed
                    }
                    continue
                }

                let records: [BookOrbitProvider.ActivityRecord]
                do {
                    records = try await provider.fetchActivitySnapshot()
                } catch BookOrbitProvider.ActivitySnapshotError.unsupported {
                    pulled += try await pullLegacyContinueSnapshot(
                        providerId: connection.id,
                        through: provider
                    )
                    pushed += await ProviderHistorySessionSync.shared.retryPending(providerId: connection.id)
                    let books = await userDataBooks(records: [], providerId: connection.id, includeAll: true)
                    for book in books {
                        let result = await BookOrbitReaderArtifactSync.shared.sync(book: book, provider: provider)
                        pulled += result.pulled
                        pushed += result.pushed
                    }
                    continue
                }

                let result = await apply(
                    records,
                    providerId: connection.id,
                    reconcileMissing: true
                )
                guard result.didApplySnapshot else { continue }
                pulled += result.appliedCount

                let scope = ServerMirrorScope(
                    connectionId: connection.id,
                    accountKey: ServerMirrorFingerprint.accountKey(for: provider.connection),
                    libraryId: nil,
                    domain: .activity
                )
                let fingerprintItems = records.map { record in
                    let rating = record.rating.map { String($0) } ?? ""
                    return "\(record.bookId)|\(record.status.rawValue)|\(record.progress)|\(record.epubCFI ?? "")|\(rating)|\(record.updatedAt.timeIntervalSince1970)"
                }
                let fingerprint = ServerMirrorFingerprint.activity(fingerprintItems)
                ServerMirrorCheckpointStore.shared.commitCompleteSnapshot(
                    scope: scope,
                    syncLevel: .fullSnapshot,
                    fingerprint: fingerprint,
                    itemCount: records.count
                )
                pushed += await ProviderHistorySessionSync.shared.retryPending(providerId: connection.id)
                let books = await userDataBooks(records: records, providerId: connection.id, includeAll: true)
                pulled += await ProviderHistorySessionSync.shared.pullBookOrbitSessions(provider: provider, books: books)
                for book in books {
                    let result = await BookOrbitReaderArtifactSync.shared.sync(book: book, provider: provider)
                    pulled += result.pulled
                    pushed += result.pushed
                }
            } catch is CancellationError {
                return ProviderSyncResult(pulled: pulled, pushed: pushed)
            } catch {
                AppLogger.sync.error("[BookOrbit] activity sync failed: \(error.localizedDescription)")
            }
        }

        if pulled > 0 {
            NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
        }
        return ProviderSyncResult(pulled: pulled, pushed: pushed)
    }

    private func pullLegacyContinueSnapshot(
        providerId: UUID,
        through provider: BookOrbitProvider
    ) async throws -> Int {
        let progress = try await provider.fetchUserMediaProgress(libraryId: "")
        let uniqueIds = Set(progress.map(\.uniqueId))
        let booksById = await books.booksByAnyIds(uniqueIds)
        let pendingIds = pendingBookIds(providerId: providerId)
        var updates: [(progress: UserMediaProgress, book: Book)] = []

        for remote in progress {
            guard !pendingIds.uniqueIds.contains(remote.uniqueId),
                let book = booksById[remote.uniqueId],
                !pendingIds.stableIds.contains(book.stableId),
                book.providerId == providerId,
                book.id == remote.libraryItemId,
                book.source == .bookOrbit,
                !isActivelyReading(book)
            else {
                continue
            }
            updates.append((remote, book))
        }

        await UserProgressStore.shared.applyAuthoritativeServerProgress(updates)
        return updates.count
    }

    private func apply(
        _ records: [BookOrbitProvider.ActivityRecord],
        providerId: UUID,
        reconcileMissing: Bool
    ) async -> (didApplySnapshot: Bool, appliedCount: Int) {
        let uniqueIds = Set(records.map { "\(providerId)_\($0.bookId)" })
        let booksById = await books.booksByAnyIds(uniqueIds)
        let pendingIds = pendingBookIds(providerId: providerId)
        var updates:
            [(
                progress: UserMediaProgress,
                book: Book,
                hideFromContinue: Bool,
                epubLocator: String?,
                serverReadStatus: String?
            )] = []
        var ratingSnapshots: [Book] = []

        for record in records {
            let uniqueId = "\(providerId)_\(record.bookId)"
            guard !pendingIds.uniqueIds.contains(uniqueId),
                let book = booksById[uniqueId],
                !pendingIds.stableIds.contains(book.stableId),
                book.providerId == providerId,
                book.id == record.bookId,
                book.source == .bookOrbit
            else {
                continue
            }
            if isActivelyReading(book) { return (false, 0) }
            if book.personalRating != record.rating,
                let updated = AppState.shared.mutateBook(uniqueId: book.uniqueId, { $0.personalRating = record.rating })
            {
                ratingSnapshots.append(updated)
            }
            updates.append(activityUpdate(record: record, book: book))
        }

        if reconcileMissing {
            let localActivityBooks = await books.booksWithProgress(providerId: providerId)
            let serverBookIds = Set(records.map(\.bookId))
            let resetDate = Date()
            for book in localActivityBooks
            where
                book.source == .bookOrbit
                && !serverBookIds.contains(book.id)
                && !pendingIds.uniqueIds.contains(book.uniqueId)
                && !pendingIds.stableIds.contains(book.stableId)
            {
                if isActivelyReading(book) { return (false, 0) }
                updates.append(
                    (
                        UserMediaProgress(
                            id: "bookorbit-\(book.id)",
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
                        book,
                        false,
                        nil,
                        nil
                    )
                )
            }
        }

        if !ratingSnapshots.isEmpty {
            await bookWriter.upsertBooks(ratingSnapshots)
        }
        await UserProgressStore.shared.applyAuthoritativeServerActivity(updates)
        return (true, updates.count + ratingSnapshots.count)
    }

    private func userDataBooks(
        records: [BookOrbitProvider.ActivityRecord],
        providerId: UUID,
        includeAll: Bool = false
    ) async -> [Book] {
        if includeAll {
            return await books.books(
                source: Book.BookSource.bookOrbit.rawValue,
                providerId: providerId
            )
        }
        var ids = Set(records.map { "\(providerId)_\($0.bookId)" })
        ids.formUnion(BookOrbitReaderArtifactSync.shared.pendingBookIds(providerId: providerId))
        guard !ids.isEmpty else { return [] }
        let lookup = await books.booksByAnyIds(ids)
        var seen = Set<String>()
        return lookup.values
            .filter {
                $0.providerId == providerId
                    && $0.source == .bookOrbit
                    && seen.insert($0.stableId).inserted
            }
    }

    private func activityUpdate(
        record: BookOrbitProvider.ActivityRecord,
        book: Book
    ) -> (
        progress: UserMediaProgress,
        book: Book,
        hideFromContinue: Bool,
        epubLocator: String?,
        serverReadStatus: String?
    ) {
        let isFinished = record.status == .read || record.status == .skimmed
        let hideFromContinue: Bool
        let fraction: Double
        switch record.status {
        case .reading, .rereading:
            hideFromContinue = false
            fraction = record.progress
        case .onHold, .abandoned:
            hideFromContinue = true
            fraction = record.progress
        case .read, .skimmed:
            hideFromContinue = true
            fraction = 1
        case .unread, .wantToRead:
            hideFromContinue = record.status == .wantToRead
            fraction = 0
        }

        let duration = book.duration ?? 0
        let currentTime =
            book.mediaType == .audiobook && duration > 0
            ? duration * fraction
            : 0
        let epubLocator =
            book.mediaType == .ebook
            ? EpubLocationBridge.readiumLocator(
                href: nil,
                epubCFI: record.epubCFI,
                fraction: fraction
            )
            : nil
        return (
            UserMediaProgress(
                id: "bookorbit-\(book.id)",
                libraryItemId: book.id,
                providerId: book.providerId,
                episodeId: nil,
                currentTime: currentTime,
                progress: fraction,
                isFinished: isFinished,
                duration: duration,
                lastUpdate: record.updatedAt,
                ebookProgress: book.mediaType == .ebook ? fraction : nil
            ),
            book,
            hideFromContinue,
            epubLocator,
            record.status.rawValue.uppercased()
        )
    }

    private func pendingBookIds(providerId: UUID) -> (uniqueIds: Set<String>, stableIds: Set<String>) {
        let stableIds = Set(
            PendingSyncQueueStore.shared.entries.values
                .filter { $0.source == .bookOrbit }
                .map(\.stableId)
        )
        return ([], stableIds)
    }

    private func isActivelyReading(_ book: Book) -> Bool {
        if playbackState.currentBook?.stableId == book.stableId {
            return true
        }
        return SyncCoordinator.shared.isEbookReaderOpen
            && LastOpenedBookStore.shared.stableId == book.stableId
    }
}
