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
    private static let recentItemLimit = 20
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
            $0.enabled && ($0.type == .audiobookshelf || $0.type == .jellyfin || $0.type == .emby)
        }
        let strategyConnectionCount = [ProviderType.booklore, .storyteller, .bookOrbit, .komga, .silo]
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

                let recent =
                    sorted
                    .filter { ($0.isFinished ?? false) == false && (($0.currentTime ?? 0) > 0 || ($0.ebookProgress ?? 0) > 0) }
                    .prefix(Self.recentItemLimit)

                let neededIds = Set(recent.compactMap(\.libraryItemId))
                let bookById = await bookQuerying.booksByIds(neededIds)

                for item in recent {
                    guard let libraryItemId = item.libraryItemId else { continue }
                    guard let book = bookById[libraryItemId] else { continue }
                    guard !absorbedStableIds.contains(book.stableId) else { continue }
                    guard book.stableId != playbackState.currentBook?.stableId else { continue }

                    let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
                    let serverDate = item.lastUpdate.flatMap { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

                    if book.mediaType == .ebook {
                        let serverEbookProgress = item.ebookProgress ?? item.progress ?? 0
                        let localEbookProgress = book.ebookProgress ?? 0

                        let direction = resolveProgressConflict(
                            localPosition: localEbookProgress,
                            localDate: book.lastUpdate,
                            serverPosition: serverEbookProgress,
                            serverDate: serverDate
                        )

                        switch direction {
                        case .pull:
                            await progressRepository.updateEbookProgress(
                                uniqueId: book.uniqueId,
                                ebookProgress: serverEbookProgress,
                                epubLocator: nil,
                                isFinished: serverEbookProgress >= 0.99,
                                lastUpdate: serverDate
                            )
                            libraryCache.mutateBook(stableId: book.stableId) {
                                $0.ebookProgress = serverEbookProgress
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
                        let localTime = local?.progress ?? 0
                        let localDate = local.flatMap { Date(timeIntervalSince1970: $0.lastUpdated) } ?? .distantPast

                        let direction = resolveProgressConflict(
                            localPosition: localTime,
                            localDate: localDate,
                            serverPosition: serverTime,
                            serverDate: serverDate
                        )

                        switch direction {
                        case .pull:
                            progressCache.saveProgress(for: book, progress: serverTime, duration: duration, at: Date())
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
                                AppLogger.sync.error(
                                    "Failed to push audiobook progress bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
                                )
                            }
                        case .none, .conflict:
                            break
                        }
                    }

                    progressCache.saveRecentlyPlayed(book, date: serverDate)
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
                if Task.isCancelled {
                    AppLogger.sync.info("Server status sync cancelled before strategy \(strategy.id)")
                    wasCancelled = true
                    break
                }
                let result = await strategy.sync(force: force, launchOptimized: launchOptimized)
                pullCount += result.pulled
                pushCount += result.pushed
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
