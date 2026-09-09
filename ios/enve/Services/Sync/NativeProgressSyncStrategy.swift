import Foundation

@MainActor
final class NativeProgressSyncStrategy: ProviderSyncStrategy {
    var id: String { "native-\(source.rawValue)" }
    var displayName: String { String(describing: providerType) }

    private let providerType: ProviderType
    private let source: Book.BookSource
    private let connections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let progressRepository: any ProgressRepository
    private let libraryCache: any RecentlyPlayedLibraryCaching
    private let progressCache: any RecentlyPlayedProgressCaching
    private let playbackState: any PlaybackStateProvider
    private let pendingSyncs: PendingSyncQueueStore

    init(
        providerType: ProviderType,
        source: Book.BookSource,
        connections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        progressRepository: any ProgressRepository,
        libraryCache: any RecentlyPlayedLibraryCaching,
        progressCache: any RecentlyPlayedProgressCaching,
        playbackState: any PlaybackStateProvider,
        pendingSyncs: PendingSyncQueueStore = .shared
    ) {
        self.providerType = providerType
        self.source = source
        self.connections = connections
        self.books = books
        self.progressRepository = progressRepository
        self.libraryCache = libraryCache
        self.progressCache = progressCache
        self.playbackState = playbackState
        self.pendingSyncs = pendingSyncs
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        var result = ProviderSyncResult.zero
        let absorbed = await books.absorbedStableIds()
        for connection in connections.activeConnections(of: providerType) {
            guard let provider = connections.provider(for: connection.id) else {
                result.failedBackends.append(connection.name)
                continue
            }
            let localBooks = await books.books(source: source.rawValue, providerId: connection.id)
            let candidates = localBooks.sorted { $0.lastUpdate > $1.lastUpdate }
            for book in candidates.prefix(launchOptimized && !force ? 40 : candidates.count) {
                guard book.stableId != playbackState.currentBook?.stableId,
                    !absorbed.contains(book.stableId), pendingSyncs.entries[book.stableId] == nil
                else { continue }
                do {
                    try Task.checkCancellation()
                    var updated = book
                    let serverDate: Date?
                    if book.mediaType == .ebook {
                        guard let pulling = provider as? any EbookProgressPulling,
                            let progress = try await pulling.fetchEbookProgressState(for: book)
                        else { continue }
                        updated.ebookProgress = progress.progress
                        if let locator = progress.locator, !locator.isEmpty {
                            updated.epubLocator = locator
                        } else if abs(progress.progress - (book.ebookProgress ?? 0)) > 0.005 {
                            updated.epubLocator = nil
                        }
                        updated.isFinished = progress.readState.isFinished || progress.readState.isAbandoned || progress.progress >= 0.99
                        updated.serverReadStatus = updated.isFinished ? "READ" : progress.readState.persistedStatus
                        updated.hideFromContinue = progress.readState == .notReading
                        serverDate = progress.updatedAt
                    } else {
                        guard let pulling = provider as? any AudiobookProgressPulling,
                            let progress = try await pulling.fetchAudiobookProgressState(for: book)
                        else { continue }
                        updated.currentTime = progress.positionSeconds
                        updated.isFinished = progress.readState.isFinished || progress.readState.isAbandoned || progress.percentage >= 0.99
                        updated.serverReadStatus = updated.isFinished ? "READ" : progress.readState.persistedStatus
                        updated.hideFromContinue = progress.readState == .notReading
                        serverDate = progress.updatedAt
                    }
                    // A local edit can arrive while the provider request is suspended.
                    guard pendingSyncs.entries[book.stableId] == nil,
                        book.stableId != playbackState.currentBook?.stableId,
                        let current = await books.book(uniqueId: book.uniqueId),
                        current.lastUpdate == book.lastUpdate,
                        current.currentTime == book.currentTime, current.ebookProgress == book.ebookProgress,
                        current.epubLocator == book.epubLocator
                    else { continue }
                    guard updated.currentTime != book.currentTime || (updated.ebookProgress ?? 0) != (book.ebookProgress ?? 0)
                        || updated.epubLocator != book.epubLocator || updated.isFinished != book.isFinished
                        || updated.hideFromContinue != book.hideFromContinue
                    else { continue }
                    updated.lastUpdate = serverDate ?? book.lastUpdate
                    await progressRepository.applyAuthoritativeProgress([
                        AuthoritativeProgressUpdate(
                            bookUniqueId: book.uniqueId, stableId: book.stableId,
                            currentTime: updated.currentTime, duration: book.duration ?? 0,
                            ebookProgress: updated.ebookProgress, epubLocator: updated.epubLocator,
                            isFinished: updated.isFinished, lastUpdate: updated.lastUpdate,
                            hideFromContinue: updated.hideFromContinue, serverReadStatus: updated.serverReadStatus
                        )
                    ])
                    libraryCache.mutateBook(stableId: book.stableId) { $0 = updated }
                    if book.mediaType != .ebook {
                        progressCache.saveProgress(for: updated, progress: updated.currentTime, duration: book.duration ?? 0, at: updated.lastUpdate)
                    }
                    if !updated.isFinished, !updated.hideFromContinue,
                        updated.currentTime > 0 || (updated.ebookProgress ?? 0) > 0
                    {
                        progressCache.saveRecentlyPlayed(updated, date: updated.lastUpdate)
                    }
                    result = ProviderSyncResult(pulled: result.pulled + 1, pushed: 0, failedBackends: result.failedBackends)
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        result.wasCancelled = true
                        return result
                    }
                    if !result.failedBackends.contains(connection.name) { result.failedBackends.append(connection.name) }
                    if error is URLError { break }
                    if case ProviderError.unauthorized = error { break }
                }
            }
        }
        return result
    }
}
