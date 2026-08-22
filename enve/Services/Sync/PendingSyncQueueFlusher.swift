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
    private let bookLookup: (String) async -> Book?

    init(
        providerResolver: any LibraryProviderResolving,
        bookLookup: @escaping (String) async -> Book?
    ) {
        self.providerResolver = providerResolver
        providerSink = ProviderSyncSink(providerResolver: providerResolver)
        self.bookLookup = bookLookup
    }

    func push(stableId: String, entry: PendingServerSync) async throws -> PendingSyncDisposition {
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
        book.isFinished = entry.isFinished ?? (entry.duration > 0 && entry.position >= entry.duration * 0.99)
        book.lastUpdate = Date(timeIntervalSince1970: entry.updatedAt)
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
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: stableId)
        do {
            switch try await transport.push(stableId: stableId, entry: entry) {
            case .remove:
                store.remove(stableId: stableId)
                AppLogger.sync.debug("[PendingSync] Flushed bookDiagnosticID=\(diagnosticID)")
            case .retain:
                AppLogger.sync.debug("[PendingSync] Retained bookDiagnosticID=\(diagnosticID); transport is unavailable")
            }
        } catch {
            let status = httpStatus(from: error)
            switch status {
            case 401, 403:
                store.suspend(stableId: stableId)
                AppLogger.sync.error("[PendingSync] Authentication failed for bookDiagnosticID=\(diagnosticID)")
            case 404, 410, 422:
                store.remove(stableId: stableId)
                AppLogger.sync.error("[PendingSync] Dropped permanent failure for bookDiagnosticID=\(diagnosticID) status=\(status ?? 0)")
            default:
                store.markRetry(stableId: stableId, at: now())
                AppLogger.sync.error("[PendingSync] Scheduled retry for bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)")
            }
        }
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
