import Combine
import Foundation
import Logging

enum ServerStatusSyncTrigger: String {
    case appLaunch = "app_launch"
    case homePullToRefresh = "home_pull_to_refresh"
}

struct ServerStatusSyncResult {
    let attemptedBackendCount: Int
    let pulledItemCount: Int
    let pushedItemCount: Int
    let failedBackends: [String]
    let wasCancelled: Bool

    static let idle = ServerStatusSyncResult(
        attemptedBackendCount: 0,
        pulledItemCount: 0,
        pushedItemCount: 0,
        failedBackends: [],
        wasCancelled: false
    )

    static let cancelled = ServerStatusSyncResult(
        attemptedBackendCount: 0,
        pulledItemCount: 0,
        pushedItemCount: 0,
        failedBackends: [],
        wasCancelled: true
    )

    var mergedItemCount: Int { pulledItemCount + pushedItemCount }
    var hasFailures: Bool { !failedBackends.isEmpty }
}

@MainActor
protocol RecentlyPlayedSyncing: AnyObject {
    func sync(trigger: ServerStatusSyncTrigger) async -> ServerStatusSyncResult
}

@MainActor
final class RecentlyPlayedSyncService: RecentlyPlayedSyncing {
    private static let snapshotRefreshBookLimit = 5_000

    private let playbackState: any PlaybackStateProvider
    private let providerConnections: any ProviderConnectionAccessing
    private let bookQuerying: any BookQuerying
    private let bookWriting: any BookWriting
    private let progressRepository: any ProgressRepository
    private let progressAPI: any RecentlyPlayedProgressAPI
    private let progressCache: any RecentlyPlayedProgressCaching
    private let libraryCache: any RecentlyPlayedLibraryCaching
    private let ebookLinks: any EbookLinkPersisting
    private let strategyRegistry: any SyncStrategyProviding

    init(
        playbackState: any PlaybackStateProvider,
        providerConnections: any ProviderConnectionAccessing,
        bookQuerying: any BookQuerying,
        bookWriting: any BookWriting,
        progressRepository: any ProgressRepository,
        progressAPI: any RecentlyPlayedProgressAPI,
        progressCache: any RecentlyPlayedProgressCaching,
        libraryCache: any RecentlyPlayedLibraryCaching,
        ebookLinks: any EbookLinkPersisting,
        strategyRegistry: any SyncStrategyProviding
    ) {
        self.playbackState = playbackState
        self.providerConnections = providerConnections
        self.bookQuerying = bookQuerying
        self.bookWriting = bookWriting
        self.progressRepository = progressRepository
        self.progressAPI = progressAPI
        self.progressCache = progressCache
        self.libraryCache = libraryCache
        self.ebookLinks = ebookLinks
        self.strategyRegistry = strategyRegistry
    }

    func sync(trigger: ServerStatusSyncTrigger) async -> ServerStatusSyncResult {
        let progressBackends = providerConnections.allBackends().filter {
            $0.enabled && $0.type == .audiobookshelf
        }
        let strategyConnectionCount = [ProviderType.booklore, .storyteller, .bookOrbit, .komga, .silo, .jellyfin, .emby, .plex, .kavita]
            .reduce(0) { $0 + providerConnections.activeConnections(of: $1).count }

        guard !progressBackends.isEmpty || strategyConnectionCount > 0 else {
            return .idle
        }
        let attemptedBackendCount = progressBackends.count + strategyConnectionCount

        AppLogger.sync.info("Fetching server progress from \(attemptedBackendCount) backend(s) [\(trigger.rawValue)]...")

        let absorbedStableIds = await bookQuerying.absorbedStableIds()

        var pullCount = 0
        var pushCount = 0
        var failedBackends: [String] = []
        var wasCancelled = false

        for backend in progressBackends {
            do {
                let allProgress = try await progressAPI.allProgress(backend: backend)

                let sorted = allProgress.sorted { lhs, rhs in
                    (lhs.lastUpdate ?? 0) > (rhs.lastUpdate ?? 0)
                }

                let localBooks: [Book]
                if let providerId = UUID(uuidString: backend.id) {
                    localBooks = await bookQuerying.books(source: Book.BookSource.audiobookshelf.rawValue, providerId: providerId)
                } else {
                    localBooks = await bookQuerying.books(backendId: backend.id, source: Book.BookSource.audiobookshelf.rawValue)
                }
                let booksByItemId = Dictionary(grouping: localBooks, by: { $0.partKey ?? $0.id })

                for item in sorted {
                    try Task.checkCancellation()
                    guard item.episodeId == nil, let libraryItemId = item.libraryItemId else { continue }
                    for book in booksByItemId[libraryItemId] ?? [] {
                        guard !absorbedStableIds.contains(book.stableId) else { continue }
                        guard book.stableId != playbackState.currentBook?.stableId,
                            PendingSyncQueueStore.shared.entries[book.stableId] == nil
                        else { continue }

                        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
                        let serverDate = item.lastUpdate.flatMap { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast

                        if book.mediaType == .ebook {
                            let serverEbookProgress = item.ebookProgress ?? item.progress ?? 0
                            let serverFinished = item.resolvedIsFinished
                            let localEbookProgress = book.ebookProgress ?? 0

                            var direction = resolveProgressConflict(
                                localPosition: localEbookProgress,
                                localDate: book.lastUpdate,
                                serverPosition: serverEbookProgress,
                                serverDate: serverDate
                            )

                            if serverDate > book.lastUpdate, serverEbookProgress == 0, localEbookProgress > 0 {
                                direction = .pull
                            }
                            if direction == .none, serverDate >= book.lastUpdate, book.isFinished != serverFinished {
                                direction = .pull
                            }
                            switch direction {
                            case .pull:
                                await progressRepository.updateEbookProgress(
                                    uniqueId: book.uniqueId,
                                    ebookProgress: serverEbookProgress,
                                    epubLocator: nil,
                                    isFinished: serverFinished,
                                    lastUpdate: serverDate
                                )
                                libraryCache.mutateBook(stableId: book.stableId) {
                                    $0.ebookProgress = serverEbookProgress
                                    $0.isFinished = serverFinished
                                    $0.epubLocator = nil
                                    $0.lastUpdate = serverDate
                                }
                                ebookLinks.saveLinks()
                                AppLogger.sync.debug(
                                    "Pulled ebook progress bookDiagnosticID=\(diagnosticID) progress=\(Int(serverEbookProgress * 100))%"
                                )
                                pullCount += 1
                            case .push:
                                do {
                                    try await progressAPI.pushEbookProgress(
                                        libraryItemId: book.partKey ?? book.id,
                                        progress: localEbookProgress,
                                        isFinished: localEbookProgress >= 0.99,
                                        backend: backend
                                    )
                                    AppLogger.sync.debug(
                                        "Pushed ebook progress bookDiagnosticID=\(diagnosticID) progress=\(Int(localEbookProgress * 100))%"
                                    )
                                    pushCount += 1
                                } catch {
                                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                                    if !failedBackends.contains(backend.name) { failedBackends.append(backend.name) }
                                    AppLogger.sync.error(
                                        "Failed to push ebook progress bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
                                    )
                                }
                            case .none, .conflict:
                                break
                            }
                        } else {
                            let serverTime = item.currentTime ?? 0
                            let duration = item.duration ?? book.duration ?? 0

                            let local = progressCache.loadProgress(for: book)
                            let localTime = local?.progress ?? book.currentTime
                            let localDate = local.flatMap { Date(timeIntervalSince1970: $0.lastUpdated) } ?? book.lastUpdate

                            var direction = resolveProgressConflict(
                                localPosition: localTime,
                                localDate: localDate,
                                serverPosition: serverTime,
                                serverDate: serverDate
                            )

                            let serverFinished = item.resolvedIsFinished
                            if serverDate > localDate, serverTime == 0, localTime > 0 {
                                direction = .pull
                            }
                            if direction == .none, serverDate >= localDate, book.isFinished != serverFinished {
                                direction = .pull
                            }
                            switch direction {
                            case .pull:
                                progressCache.saveProgress(for: book, progress: serverTime, duration: duration, at: serverDate)
                                await progressRepository.applyAuthoritativeProgress([
                                    AuthoritativeProgressUpdate(
                                        bookUniqueId: book.uniqueId,
                                        stableId: book.stableId,
                                        currentTime: serverTime,
                                        duration: duration,
                                        ebookProgress: book.ebookProgress,
                                        epubLocator: book.epubLocator,
                                        isFinished: serverFinished,
                                        lastUpdate: serverDate,
                                        hideFromContinue: item.hideFromContinueListening ?? false
                                    )
                                ])
                                libraryCache.mutateBook(stableId: book.stableId) {
                                    $0.currentTime = serverTime
                                    $0.isFinished = serverFinished
                                    $0.lastUpdate = serverDate
                                    $0.hideFromContinue = item.hideFromContinueListening ?? false
                                }
                                AppLogger.sync.debug(
                                    "Pulled audiobook progress bookDiagnosticID=\(diagnosticID) position=\(Int(serverTime))s"
                                )
                                pullCount += 1
                            case .push:
                                do {
                                    let localDuration = local?.duration ?? duration
                                    try await progressAPI.pushAudiobookProgress(
                                        libraryItemId: book.partKey ?? book.id,
                                        currentTime: localTime,
                                        duration: localDuration,
                                        isFinished: localDuration > 0 && localTime >= localDuration,
                                        backend: backend
                                    )
                                    AppLogger.sync.debug(
                                        "Pushed audiobook progress bookDiagnosticID=\(diagnosticID) position=\(Int(localTime))s"
                                    )
                                    pushCount += 1
                                } catch {
                                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                                    if !failedBackends.contains(backend.name) { failedBackends.append(backend.name) }
                                    AppLogger.sync.error(
                                        "Failed to push audiobook progress bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
                                    )
                                }
                            case .none, .conflict:
                                break
                            }
                        }

                        if !item.resolvedIsFinished, item.hideFromContinueListening != true,
                            (item.currentTime ?? 0) > 0 || (item.ebookProgress ?? 0) > 0
                        {
                            progressCache.saveRecentlyPlayed(book, date: serverDate)
                        }
                    }
                }
            } catch is CancellationError {
                AppLogger.sync.debug("Server status sync cancelled")
                wasCancelled = true
                break
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    AppLogger.sync.debug("Server status sync cancelled")
                    wasCancelled = true
                    break
                }
                AppLogger.sync.error("Failed to fetch server progress: \(error.localizedDescription)")
                failedBackends.append(backend.name)
            }
        }

        let force = trigger == .homePullToRefresh
        let launchOptimized = trigger == .appLaunch
        let strategies = strategyRegistry.syncStrategies
        await libraryCache.withAllBooksTransaction {
            for strategy in strategies {
                if wasCancelled || Task.isCancelled {
                    AppLogger.sync.info("Server status sync cancelled before strategy \(strategy.id)")
                    wasCancelled = true
                    break
                }
                let result = await strategy.sync(force: force, launchOptimized: launchOptimized)
                pullCount += result.pulled
                pushCount += result.pushed
                failedBackends.append(contentsOf: result.failedBackends.filter { !failedBackends.contains($0) })
                wasCancelled = wasCancelled || result.wasCancelled
            }
        }

        let mergeCount = pullCount + pushCount
        if mergeCount > 0 {
            AppLogger.sync.info("Synced \(mergeCount) item(s) (\(pullCount) pulled, \(pushCount) pushed)")
            await refreshAudiobookSnapshots()
            NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
        }

        return ServerStatusSyncResult(
            attemptedBackendCount: attemptedBackendCount,
            pulledItemCount: pullCount,
            pushedItemCount: pushCount,
            failedBackends: failedBackends,
            wasCancelled: wasCancelled
        )
    }

    private func refreshAudiobookSnapshots() async {
        let audiobookCount = await bookQuerying.bookCount(mediaType: "audiobook")
        guard audiobookCount <= Self.snapshotRefreshBookLimit else { return }

        var refreshed: [Book] = []
        libraryCache.performAllBooksBatch {
            for index in libraryCache.allBooks.indices {
                let book = libraryCache.allBooks[index]
                guard book.mediaType != .ebook else { continue }
                if let progressData = progressCache.loadProgress(for: book),
                    libraryCache.allBooks[index].currentTime != progressData.progress
                {
                    libraryCache.allBooks[index].currentTime = progressData.progress
                    libraryCache.allBooks[index].lastUpdate = Date(timeIntervalSince1970: progressData.lastUpdated)
                    refreshed.append(libraryCache.allBooks[index])
                }
            }
        }
        libraryCache.allBooksChanged.send(())

        if !refreshed.isEmpty {
            await bookWriting.upsertBooks(refreshed)
        }
    }
}
