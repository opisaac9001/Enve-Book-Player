import Foundation
import Logging

/// Inject reauthentication reporting without coupling tests to persisted connection state.
@MainActor
protocol ProviderReauthenticationSignalling: AnyObject {
    func markNeedsReauthentication(providerId: UUID, error: Error)
}

extension ProviderConnectionStore: ProviderReauthenticationSignalling {}

/// Resolve by timestamp, confirm remote rewinds, skip active playback, and isolate failures per service.
@MainActor
final class OPDSProgressionSyncStrategy: ProviderSyncStrategy {
    let id = "opds-progression"
    let displayName = "OPDS Progression"

    private enum Outcome {
        case pulled
        case pushed
        case unchanged
    }

    private let minimumServerSyncInterval: TimeInterval = 60
    private var lastSyncTime: Date?

    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let progressRepository: any ProgressRepository
    private let libraryCache: any RecentlyPlayedLibraryCaching
    private let progressCache: any RecentlyPlayedProgressCaching
    private let playbackState: any PlaybackStateProvider
    private let pendingSyncs: PendingSyncQueueStore
    private let conflicts: EbookConflictStore
    private let rewinds: RemoteRewindTracker
    private weak var reauthentication: (any ProviderReauthenticationSignalling)?

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        progressRepository: any ProgressRepository,
        libraryCache: any RecentlyPlayedLibraryCaching,
        progressCache: any RecentlyPlayedProgressCaching,
        playbackState: any PlaybackStateProvider,
        reauthentication: (any ProviderReauthenticationSignalling)? = nil,
        pendingSyncs: PendingSyncQueueStore = .shared,
        conflicts: EbookConflictStore = .shared,
        rewinds: RemoteRewindTracker = .shared
    ) {
        self.providerConnections = providerConnections
        self.books = books
        self.progressRepository = progressRepository
        self.libraryCache = libraryCache
        self.progressCache = progressCache
        self.playbackState = playbackState
        self.reauthentication = reauthentication
        self.pendingSyncs = pendingSyncs
        self.conflicts = conflicts
        self.rewinds = rewinds
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        let now = Date()
        if !force, let lastSyncTime, now.timeIntervalSince(lastSyncTime) < minimumServerSyncInterval {
            return .zero
        }
        lastSyncTime = now

        let connections = providerConnections.activeConnections(of: .opds)
        guard !connections.isEmpty else { return .zero }

        var pulled = 0
        var pushed = 0
        var failedBackends: [String] = []
        let absorbed = await books.absorbedStableIds()

        for connection in connections {
            guard let provider = providerConnections.provider(for: connection.id) as? OPDSProvider,
                provider.hasProgressionEndpoints
            else { continue }

            let candidates = await books.books(source: Book.BookSource.opds.rawValue, providerId: connection.id)
                .filter { provider.progressionEndpoint(for: $0) != nil }
                .sorted { $0.lastUpdate > $1.lastUpdate }

            var retiredServices: Set<HTTPOrigin> = []

            for book in candidates.prefix(launchOptimized && !force ? 40 : candidates.count) {
                guard isEligible(book, absorbed: absorbed),
                    let endpoint = provider.progressionEndpoint(for: book)
                else { continue }
                // Skip a failed service for this pass without blocking other services on the connection.
                let service = HTTPOrigin(url: endpoint.url)
                guard !retiredServices.contains(service) else { continue }

                do {
                    try Task.checkCancellation()
                    switch try await reconcile(book: book, provider: provider, connection: connection) {
                    case .pulled: pulled += 1
                    case .pushed: pushed += 1
                    case .unchanged: break
                    }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        return ProviderSyncResult(
                            pulled: pulled,
                            pushed: pushed,
                            failedBackends: failedBackends,
                            wasCancelled: true
                        )
                    }
                    if !failedBackends.contains(connection.name) { failedBackends.append(connection.name) }
                    AppLogger.sync.error(
                        "[OPDS] Progression sync failed for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                    )
                    if error is URLError { retiredServices.insert(service) }
                    if case .unauthorized? = error as? OPDSProgressionError {
                        retiredServices.insert(service)
                        reportRefusedCredentials(endpoint: endpoint, provider: provider, connection: connection)
                    }
                }
            }
        }

        return ProviderSyncResult(pulled: pulled, pushed: pushed, failedBackends: failedBackends)
    }

    private func isEligible(_ book: Book, absorbed: Set<String>) -> Bool {
        book.stableId != playbackState.currentBook?.stableId
            && !absorbed.contains(book.stableId)
            && pendingSyncs.entries[book.stableId] == nil
            && !conflicts.contains(stableId: book.stableId)
    }

    private func reconcile(
        book: Book,
        provider: OPDSProvider,
        connection: ServerConnection
    ) async throws -> Outcome {
        let local = localProgression(of: book)

        guard let document = try await provider.fetchProgression(for: book) else {
            guard local > 0.001 else { return .unchanged }
            return try await push(book: book, provider: provider)
        }

        switch resolveProgressConflictWithBackwardCheck(
            localPosition: local,
            localDate: book.lastUpdate,
            serverPosition: document.progression,
            serverDate: document.modified
        ) {
        case .pull:
            return await apply(document, to: book)
        case .push:
            return try await push(book: book, provider: provider)
        case .conflict:
            return await resolveBackwardMove(document, for: book, connection: connection)
        case .none:
            return .unchanged
        }
    }

    /// Confirm remote rewinds unless the tracker recognizes an outbound echo or a previously accepted rewind.
    private func resolveBackwardMove(
        _ document: OPDSProgressionDocument,
        for book: Book,
        connection: ServerConnection
    ) async -> Outcome {
        let verdict = rewinds.assess(
            scope: scope(for: book, source: connection.name),
            observation: observation(of: document, for: book),
            localProgress: localProgression(of: book)
        )

        switch verdict {
        case .confirmed:
            conflicts.remove(stableId: book.stableId)
            return await apply(document, to: book)
        case .echo, .dismissed:
            return .unchanged
        case .notRewind, .unconfirmed:
            record(document, conflictFor: book, connection: connection)
            return .unchanged
        }
    }

    private func scope(for book: Book, source: String) -> RemoteProgressScope {
        RemoteProgressScope(book: book, domain: domain(of: book), source: source)
    }

    private func domain(of book: Book) -> ProgressSyncDomain {
        book.mediaType == .ebook ? .ebook : .audiobook
    }

    private func observation(of document: OPDSProgressionDocument, for book: Book) -> RemoteProgressObservation {
        RemoteProgressObservation(
            progress: document.progression,
            positionSeconds: book.mediaType == .ebook
                ? nil
                : OPDSProgressionMapping.audioSeconds(
                    in: document.point,
                    progression: document.progression,
                    duration: book.duration
                ),
            locator: book.mediaType == .ebook
                ? OPDSProgressionMapping.ebookLocator(
                    for: book,
                    point: document.point,
                    progression: document.progression
                )
                : nil,
            observedAt: document.modified
        )
    }

    private func push(book: Book, provider: OPDSProvider) async throws -> Outcome {
        do {
            if book.mediaType == .ebook {
                try await provider.updateEbookProgress(
                    for: book,
                    progress: book.ebookProgress ?? book.canonicalEbookProgress,
                    epubLocator: book.epubLocator
                )
            } else {
                // Do not record skipped pushes; an unsent position must never be recognized as an outbound echo.
                guard try await provider.pushPlaybackProgression(
                    for: book,
                    currentTime: book.currentTime,
                    isFinished: book.isFinished
                ) else { return .unchanged }
            }
            // Record successful pushes so the rewind tracker can recognize their echoes.
            rewinds.recordOutboundWrite(
                key: RemoteProgressWriteKey(book: book, domain: domain(of: book)),
                progress: localProgression(of: book),
                positionSeconds: book.mediaType == .ebook ? nil : book.currentTime,
                locator: book.mediaType == .ebook ? book.epubLocator : nil
            )
            return .pushed
        } catch let error as OPDSProgressionError {
            // After a 409, fetch the service's newer position.
            guard case .staleProgression(_) = error else { throw error }
            guard let newer = try await provider.fetchProgression(for: book) else { return .unchanged }
            return await apply(newer, to: book)
        }
    }

    private func apply(_ document: OPDSProgressionDocument, to book: Book) async -> Outcome {
        let isFinished = document.progression >= Book.finishedProgressThreshold
        var updated = book
        updated.isFinished = isFinished
        updated.serverReadStatus = isFinished ? "READ" : "READING"
        updated.hideFromContinue = false
        updated.lastUpdate = document.modified

        if book.mediaType == .ebook {
            updated.ebookProgress = document.progression
            if let locator = OPDSProgressionMapping.ebookLocator(
                for: book,
                point: document.point,
                progression: document.progression
            ) {
                updated.epubLocator = locator
            }
        } else {
            guard let seconds = OPDSProgressionMapping.audioSeconds(
                in: document.point,
                progression: document.progression,
                duration: book.duration
            ) else { return .unchanged }
            updated.currentTime = seconds
        }

        // A local edit can arrive while the service request is suspended.
        guard pendingSyncs.entries[book.stableId] == nil,
            book.stableId != playbackState.currentBook?.stableId,
            let current = await books.book(uniqueId: book.uniqueId),
            current.lastUpdate == book.lastUpdate,
            current.currentTime == book.currentTime,
            current.ebookProgress == book.ebookProgress,
            current.epubLocator == book.epubLocator
        else { return .unchanged }

        await progressRepository.applyAuthoritativeProgress([
            AuthoritativeProgressUpdate(
                bookUniqueId: book.uniqueId,
                stableId: book.stableId,
                currentTime: updated.currentTime,
                duration: book.duration ?? 0,
                ebookProgress: updated.ebookProgress,
                epubLocator: updated.epubLocator,
                isFinished: updated.isFinished,
                lastUpdate: updated.lastUpdate,
                hideFromContinue: updated.hideFromContinue,
                serverReadStatus: updated.serverReadStatus
            )
        ])
        libraryCache.mutateBook(stableId: book.stableId) { $0 = updated }
        if book.mediaType != .ebook {
            progressCache.saveProgress(
                for: updated,
                progress: updated.currentTime,
                duration: book.duration ?? 0,
                at: updated.lastUpdate
            )
        }
        if !updated.isFinished, updated.currentTime > 0 || (updated.ebookProgress ?? 0) > 0 {
            progressCache.saveRecentlyPlayed(updated, date: updated.lastUpdate)
        }

        AppLogger.sync.debug(
            "[OPDS] Pulled progression for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) progression=\(Int(document.progression * 100))%"
        )
        return .pulled
    }

    /// Pending conflicts suspend reconciliation until the user chooses a position.
    private func record(_ document: OPDSProgressionDocument, conflictFor book: Book, connection: ServerConnection) {
        conflicts.add(
            EbookSyncConflict(
                bookStableId: book.stableId,
                bookTitle: book.title,
                localProgress: localProgression(of: book),
                serverProgress: document.progression,
                serverLocator: book.mediaType == .ebook
                    ? OPDSProgressionMapping.ebookLocator(
                        for: book,
                        point: document.point,
                        progression: document.progression
                    )
                    : nil,
                serverDate: document.modified,
                remoteSource: connection.name
            )
        )
        AppLogger.sync.info(
            "[OPDS] Progression would move bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) backwards; awaiting the reader's answer"
        )
    }

    /// Only feed-origin 401 responses invalidate the connection; delegated services are accessed anonymously.
    private func reportRefusedCredentials(
        endpoint: OPDSProgressionEndpoint,
        provider: OPDSProvider,
        connection: ServerConnection
    ) {
        guard OPDSURL.sameOrigin(endpoint.url, as: provider.feedURL()) else { return }
        reauthentication?.markNeedsReauthentication(providerId: connection.id, error: ProviderError.unauthorized)
    }

    private func localProgression(of book: Book) -> Double {
        guard book.mediaType == .ebook else {
            return Book.audioProgressFraction(currentTime: book.currentTime, duration: book.duration)
        }
        return book.ebookProgress ?? book.canonicalEbookProgress
    }
}
