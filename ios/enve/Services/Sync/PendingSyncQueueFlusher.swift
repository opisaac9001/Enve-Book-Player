import Foundation
import Logging

enum PendingSyncDisposition {
    case remove
    case retain
}

@MainActor
protocol PendingSyncTransporting: AnyObject {
    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition
}

@MainActor
final class ProviderPendingSyncTransport: PendingSyncTransporting {
    private let providerResolver: any LibraryProviderResolving
    private let providerSink: ProviderSyncSink
    private let pendingSync: PendingSyncQueueStore?
    private let serialQueue: PerBookSerialQueue?
    private let isDownloaded: (Book) -> Bool
    private let bookLookup: (String) async -> Book?
    private let serverSyncEnabled: () -> Bool

    init(
        providerResolver: any LibraryProviderResolving,
        storytellerPositions: @escaping () -> StorytellerPositionSyncService,
        bookLookup: @escaping (String) async -> Book?,
        pendingSync: PendingSyncQueueStore? = nil,
        serialQueue: PerBookSerialQueue? = nil,
        isDownloaded: @escaping (Book) -> Bool = { _ in false },
        serverSyncEnabled: @escaping () -> Bool = { true }
    ) {
        self.providerResolver = providerResolver
        providerSink = ProviderSyncSink(providerResolver: providerResolver, storytellerPositions: storytellerPositions, pendingSync: pendingSync)
        self.pendingSync = pendingSync
        self.serialQueue = serialQueue
        self.isDownloaded = isDownloaded
        self.bookLookup = bookLookup
        self.serverSyncEnabled = serverSyncEnabled
    }

    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition {
        guard let serialQueue else { return try await send(stableId: stableId, entry: entry) }
        var result: Result<PendingSyncDisposition, any Error> = .success(.retain)
        await serialQueue.enqueue(bookId: stableId) {
            guard self.pendingSync?.entries[stableId] == entry else { return }
            do { result = .success(try await self.send(stableId: stableId, entry: entry)) }
            catch { result = .failure(error) }
        }
        return try result.get()
    }

    private func send(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition {
        guard serverSyncEnabled() else { return .retain }
        guard var book = await bookLookup(stableId) else {
            return entry.source == .local || entry.source == .smb ? .remove : .retain
        }
        guard let provider = providerResolver.provider(for: book) else { return .retain }
        guard provider.syncCapability.contains(.pushProgress) else { return .remove }
        guard providerSink.isApplicable(to: book, domain: entry.domain) else { return .remove }

        if entry.domain.usesEbookProgress {
            book.ebookProgress = entry.progress ?? 0
            book.epubLocator = entry.locator
        } else {
            book.currentTime = entry.position
        }
        book.isFinished = entry.isFinished ?? (entry.duration > 0 && entry.position >= entry.duration * Book.finishedProgressThreshold)
        book.lastUpdate = Date(timeIntervalSince1970: entry.updatedAt)
        guard serverSyncEnabled() else { return .retain }
        if let pendingSync, pendingSync.entries[stableId] == entry,
            entry.domain == .audiobook, entry.downloadedBaseline == nil, isDownloaded(book),
            provider is any AudiobookProgressPulling, provider.syncCapability.contains(.pullProgress)
        {
            var guardedEntry = entry
            guardedEntry.downloadedBaseline = DownloadedProgressBaseline(
                position: entry.position, updatedAt: book.lastUpdate, isFinished: book.isFinished
            )
            pendingSync.enqueue(guardedEntry)
        }
        try await providerSink.push(
            ProgressUpdate(
                book: book,
                domain: entry.domain,
                positionSeconds: entry.position,
                progress: entry.progress ?? (entry.duration > 0 ? entry.position / entry.duration : 0),
                locator: entry.locator,
                sourceEngine: EpubLocationBridge.sourceEngine(from: entry.locator),
                sessionId: nil,
                isFinished: book.isFinished,
                timeListened: 0,
                playbackRate: 1
            )
        )
        return .remove
    }
}

@MainActor
final class PendingSyncQueueFlusher {
    var onValidationFailure: (@MainActor (String, String) -> Void)?
    var onDownloadedConflict: (@MainActor (String, TimeInterval) -> Void)?

    private let store: PendingSyncQueueStore
    private let transport: any PendingSyncTransporting
    private let now: () -> Date
    private var isFlushing = false

    init(
        store: PendingSyncQueueStore = .shared,
        transport: any PendingSyncTransporting,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    func validationFailure(for stableId: String) -> String? {
        store.entries[stableId]?.validationFailureMessage
    }

    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let readyEntries = store.entriesReady(at: now()).sorted {
            if $0.value.updatedAt == $1.value.updatedAt {
                return $0.key < $1.key
            }
            return $0.value.updatedAt < $1.value.updatedAt
        }
        guard !readyEntries.isEmpty else {
            if !store.isEmpty {
                AppLogger.sync.debug("[PendingSync] \(store.count) queued updates remain in backoff")
            }
            return
        }

        AppLogger.sync.debug("[PendingSync] Flushing \(readyEntries.count) of \(store.count) queued updates")
        for (stableId, entry) in readyEntries {
            await flush(stableId: stableId, entry: entry)
        }
    }

    private func flush(stableId: String, entry: PendingServerSync) async {
        guard store.entries[stableId] == entry else { return }
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: stableId)
        do {
            let disposition = try await transport.push(stableId: stableId, entry: entry)
            guard store.entries[stableId] == entry else { return }
            switch disposition {
            case .remove:
                store.remove(stableId: stableId)
                AppLogger.sync.debug("[PendingSync] Flushed bookDiagnosticID=\(diagnosticID)")
            case .retain:
                AppLogger.sync.debug("[PendingSync] Retained bookDiagnosticID=\(diagnosticID); transport is unavailable")
            }
        } catch {
            guard store.entries[stableId] == entry else { return }
            if let validation = error as? ProgressValidationError {
                let message = validation.localizedDescription
                store.suspend(stableId: stableId, validationFailureMessage: message)
                onValidationFailure?(stableId, message)
                AppLogger.sync.error("[PendingSync] Validation failed for bookDiagnosticID=\(diagnosticID): \(message)")
                return
            }
            let status = httpStatus(from: error)
            if entry.downloadedBaseline != nil {
                if let conflict = error as? DownloadedProgressConflict {
                    store.markRetry(stableId: stableId, failure: failure(.conflict), at: now())
                    onDownloadedConflict?(stableId, conflict.serverPosition)
                } else {
                    store.markRetry(stableId: stableId, failure: transientFailure(for: error, status: status), at: now())
                }
                return
            }
            if case .unauthorized = error as? ProviderError {
                store.suspend(stableId: stableId, failure: failure(.authentication))
                AppLogger.sync.error("[PendingSync] Authentication failed for bookDiagnosticID=\(diagnosticID)")
                return
            }
            switch status {
            case 401, 403:
                store.suspend(stableId: stableId, failure: failure(.authentication))
                AppLogger.sync.error("[PendingSync] Authentication failed for bookDiagnosticID=\(diagnosticID)")
            case 404, 410, 422:
                store.remove(stableId: stableId)
                AppLogger.sync.error("[PendingSync] Dropped permanent failure for bookDiagnosticID=\(diagnosticID) status=\(status ?? 0)")
            default:
                store.markRetry(stableId: stableId, failure: transientFailure(for: error, status: status), at: now())
                AppLogger.sync.error("[PendingSync] Scheduled retry for bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)")
            }
        }
    }

    private func failure(_ category: PendingSyncFailure.Category) -> PendingSyncFailure {
        let message = switch category {
        case .authentication: "The server needs you to sign in again."
        case .conflict: "The server has newer progress than this download."
        case .transient: "The update couldn't be sent."
        }
        return PendingSyncFailure(category: category, message: message, occurredAt: now().timeIntervalSince1970)
    }

    private func transientFailure(for error: Error, status: Int?) -> PendingSyncFailure {
        let message: String
        if let status {
            message = "The server returned an error (HTTP \(status))."
        } else if let urlError = error as? URLError {
            message = switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                "This device is offline."
            case .timedOut:
                "The server took too long to respond."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                "The server couldn't be reached."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                .clientCertificateRequired:
                "A secure connection to the server couldn't be made."
            default:
                "The connection to the server failed."
            }
        } else if case .rateLimited = error as? ProviderError {
            message = "The server is limiting requests. Enve will try again shortly."
        } else {
            return failure(.transient)
        }
        return PendingSyncFailure(category: .transient, message: message, occurredAt: now().timeIntervalSince1970)
    }

    private func httpStatus(from error: Error) -> Int? {
        guard let providerError = error as? ProviderError,
            case .serverError(let message) = providerError
        else {
            return nil
        }
        guard let httpRange = message.range(of: "HTTP", options: .caseInsensitive) else {
            return nil
        }
        return message[httpRange.upperBound...]
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first(where: { (100...599).contains($0) })
    }
}
