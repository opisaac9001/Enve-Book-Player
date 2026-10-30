import Combine
import Foundation
import Logging

public class PlayerSessionService {
    static let shared = PlayerSessionService(
        providerConnections: AppState.shared.providerConnections
    )

    public private(set) var currentABSSessionId: String?
    public private(set) var lastServerCurrentTime: TimeInterval?
    public private(set) var lastSession: ABSPlaySession?
    private var currentBook: Book?
    private var currentBackend: BackendConfig?
    private let audiobookshelfService: AudiobookshelfService
    private let providerConnections: any ProviderConnectionAccessing
    private let serverSyncEnabled: @MainActor () -> Bool

    public var pendingTimeListened: TimeInterval = 0

    init(
        audiobookshelfService: AudiobookshelfService = AudiobookshelfService(),
        providerConnections: any ProviderConnectionAccessing,
        serverSyncEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        self.serverSyncEnabled = serverSyncEnabled
        self.audiobookshelfService = audiobookshelfService
        self.providerConnections = providerConnections
    }

    public func startABSSession(for book: Book, startTime: TimeInterval) async throws -> ABSPlaySession {
        guard serverSyncEnabled() else { throw CancellationError() }
        guard let backendId = book.backendId,
            let backend = providerConnections.backend(id: backendId)
        else {
            throw NSError(domain: "SessionService", code: -1)
        }

        let session = try await audiobookshelfService.startPlaySession(
            libraryItemId: Self.libraryItemId(for: book),
            episodeId: nil,
            backend: backend,
            forceDirectPlay: true
        )
        guard serverSyncEnabled() else { throw CancellationError() }
        currentABSSessionId = session.id
        currentBook = book
        currentBackend = backend
        lastServerCurrentTime = session.currentTime
        lastSession = session
        pendingTimeListened = 0
        AppLogger.player.info("ABS session started. Server currentTime: \(session.currentTime ?? 0)s")
        return session
    }

    func ownsABSSession(for book: Book?) -> Bool {
        guard currentABSSessionId != nil, let book, let sessionBook = currentBook else { return false }
        return Self.libraryItemId(for: sessionBook) == Self.libraryItemId(for: book)
            && sessionBook.backendId == book.backendId
    }

    /// Returns false when the listening time certainly never reached the server and should be sent again.
    /// Progress for any book other than the session's own is dropped.
    @discardableResult
    public func syncABSSession(for book: Book?, progress: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async -> Bool {
        guard serverSyncEnabled(), let backend = currentBackend, duration > 0 else { return true }
        if currentABSSessionId != nil, !ownsABSSession(for: book) {
            AppLogger.player.warning("Dropped ABS session sync for a book the session does not belong to")
            return true
        }

        if let sessionId = currentABSSessionId {
            do {
                try await audiobookshelfService.syncPlaySession(
                    sessionId: sessionId,
                    currentTime: progress,
                    timeListened: timeListened,
                    duration: duration,
                    backend: backend
                )
                AppLogger.player.info("ABS session synced: \(Int(progress))s / \(Int(duration))s")
            } catch {
                AppLogger.player.error("Session sync failed, trying direct update: \(error.localizedDescription)")
                await updateProgressDirectly(progress: progress, duration: duration, backend: backend)
                return !AudiobookshelfProvider.requestNeverReachedServer(error)
            }
        } else {
            await updateProgressDirectly(progress: progress, duration: duration, backend: backend)
        }
        return true
    }

    public func closeABSSession(for book: Book?, progress: TimeInterval, duration: TimeInterval) async {
        // A session for another book is forgotten rather than closed with this book's position.
        guard serverSyncEnabled(), currentABSSessionId == nil || ownsABSSession(for: book) else {
            currentABSSessionId = nil
            lastServerCurrentTime = nil
            lastSession = nil
            pendingTimeListened = 0
            currentBook = nil
            currentBackend = nil
            return
        }
        guard let backend = currentBackend else {
            currentABSSessionId = nil
            lastServerCurrentTime = nil
            currentBook = nil
            return
        }

        if let sessionId = currentABSSessionId {
            do {
                try await audiobookshelfService.closePlaySession(
                    sessionId: sessionId,
                    currentTime: progress,
                    timeListened: pendingTimeListened,
                    duration: duration,
                    backend: backend
                )
                AppLogger.player.info("ABS session closed: \(Int(progress))s, timeListened: \(Int(pendingTimeListened))s")
            } catch {
                AppLogger.player.error("Session close failed, trying direct update: \(error.localizedDescription)")
                if duration > 0 {
                    await updateProgressDirectly(progress: progress, duration: duration, backend: backend)
                }
            }
        }

        currentABSSessionId = nil
        lastServerCurrentTime = nil
        lastSession = nil
        pendingTimeListened = 0
        currentBook = nil
        currentBackend = nil
    }

    private func updateProgressDirectly(progress: TimeInterval, duration: TimeInterval, backend: BackendConfig) async {
        guard serverSyncEnabled(), let book = currentBook else { return }
        do {
            try await audiobookshelfService.updateProgress(
                libraryItemId: Self.libraryItemId(for: book),
                currentTime: progress,
                duration: duration,
                backend: backend
            )
            AppLogger.player.info("ABS progress updated directly: \(Int(progress))s")
        } catch {
            AppLogger.player.error("Direct progress update failed: \(error.localizedDescription)")
        }
    }

    private static func libraryItemId(for book: Book) -> String {
        book.partKey ?? book.id
    }

    @discardableResult
    public func syncHardcoverProgress(book: Book, progress: Double) async -> Bool {
        guard serverSyncEnabled() else { return false }
        return await HardcoverSyncService.shared.syncProgress(book: book, progress: progress)
    }
}
