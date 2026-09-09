import Foundation
import Logging

@MainActor
final class KomgaEbookSyncStrategy: ProviderSyncStrategy {
    let id = "komga-ebook"
    let displayName = "Komga"

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
        if !force,
            let lastSyncTime,
            now.timeIntervalSince(lastSyncTime) < minimumServerSyncInterval
        {
            return .zero
        }
        lastSyncTime = now

        let activeBookId = playbackState.currentBook?.stableId
        let connections = providerConnections.activeConnections(of: .komga)
        guard !connections.isEmpty else { return .zero }

        var pulled = 0
        var failedBackends: [String] = []

        for connection in connections {
            guard let provider = providerConnections.provider(for: connection.id) as? KomgaProvider else { continue }

            do {
                let progressItems = try await provider.fetchRecentProgress(
                    limit: launchOptimized ? 40 : 100,
                    launchOptimized: launchOptimized
                )
                let localBooks = await books.books(
                    source: Book.BookSource.komga.rawValue,
                    providerId: connection.id,
                    mediaType: "ebook"
                )
                let localBooksById = Dictionary(uniqueKeysWithValues: localBooks.map { ($0.id, $0) })
                let progressByBookId = Dictionary(uniqueKeysWithValues: progressItems.map { ($0.libraryItemId, $0) })

                for progress in progressItems {
                    guard let book = localBooksById[progress.libraryItemId],
                        book.stableId != activeBookId,
                        PendingSyncQueueStore.shared.entries[book.stableId] == nil,
                        let serverProgress = progress.ebookProgress
                    else { continue }

                    let localProgress = book.ebookProgress ?? book.canonicalEbookProgress
                    let direction = resolveProgressConflictWithBackwardCheck(
                        localPosition: localProgress,
                        localDate: book.lastUpdate,
                        serverPosition: serverProgress,
                        serverDate: progress.lastUpdate
                    )
                    guard direction == .pull else { continue }

                    let isFinished = progress.isFinished || serverProgress >= 0.99
                    var persistedBook = book
                    persistedBook.ebookProgress = serverProgress
                    persistedBook.isFinished = isFinished
                    persistedBook.serverReadStatus = isFinished ? "READ" : "IN_PROGRESS"
                    persistedBook.hideFromContinue = false
                    persistedBook.lastUpdate = progress.lastUpdate
                    if AppState.shared.mutateBook(
                        stableId: book.stableId,
                        {
                            $0 = persistedBook
                        }
                    ) == nil {
                        await bookWriter.upsertBooks([persistedBook])
                    }
                    BookProgressStore.shared.saveRecentlyPlayed(book, date: progress.lastUpdate)
                    AppLogger.sync.debug(
                        "Pulled Komga ebook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) progress=\(Int(serverProgress * 100))%"
                    )
                    pulled += 1
                }

                for book in localBooks
                where
                    book.stableId != activeBookId && PendingSyncQueueStore.shared.entries[book.stableId] == nil
                    && (force || book.canonicalEbookProgress > 0.001) && progressByBookId[book.id] == nil
                {
                    if let remote = try await provider.fetchEbookProgress(for: book) {
                        guard force, remote.progress != book.ebookProgress || (remote.progress >= 0.99) != book.isFinished else { continue }
                        var updated = book
                        updated.ebookProgress = remote.progress
                        updated.isFinished = remote.progress >= 0.99
                        updated.serverReadStatus = updated.isFinished ? "READ" : "IN_PROGRESS"
                        updated.hideFromContinue = false
                        updated.lastUpdate = remote.updatedAt ?? book.lastUpdate
                        updated.epubLocator = nil
                        if AppState.shared.mutateBook(stableId: book.stableId, { $0 = updated }) == nil {
                            await bookWriter.upsertBooks([updated])
                        }
                        pulled += 1
                        continue
                    }
                    guard book.canonicalEbookProgress > 0 || book.isFinished else { continue }

                    let resetDate = Date()
                    var resetBook = book
                    resetBook.ebookProgress = 0
                    resetBook.epubLocator = nil
                    resetBook.isFinished = false
                    resetBook.serverReadStatus = nil
                    resetBook.hideFromContinue = true
                    resetBook.lastUpdate = resetDate
                    if AppState.shared.mutateBook(
                        stableId: book.stableId,
                        {
                            $0 = resetBook
                        }
                    ) == nil {
                        await bookWriter.upsertBooks([resetBook])
                    }
                    BookProgressStore.shared.remove(stableId: book.stableId)
                    pulled += 1
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return ProviderSyncResult(pulled: pulled, pushed: 0, failedBackends: failedBackends, wasCancelled: true)
                }
                if !failedBackends.contains(connection.name) { failedBackends.append(connection.name) }
                AppLogger.sync.error(
                    "Failed to sync Komga progress providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: connection.id.uuidString)): \(error.localizedDescription)"
                )
            }
        }

        return ProviderSyncResult(pulled: pulled, pushed: 0, failedBackends: failedBackends)
    }
}
