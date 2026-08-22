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

    public var pendingTimeListened: TimeInterval = 0

    init(
        audiobookshelfService: AudiobookshelfService = AudiobookshelfService(),
        providerConnections: any ProviderConnectionAccessing
    ) {
        self.audiobookshelfService = audiobookshelfService
        self.providerConnections = providerConnections
    }

    public func startABSSession(for book: Book, startTime: TimeInterval) async throws -> ABSPlaySession {
        guard let backendId = book.backendId,
            let backend = providerConnections.backend(id: backendId)
        else {
            throw NSError(domain: "SessionService", code: -1)
        }

        let session = try await audiobookshelfService.startPlaySession(
            libraryItemId: book.partKey ?? book.id,
            episodeId: nil,
            backend: backend,
            forceDirectPlay: true
        )
        currentABSSessionId = session.id
        currentBook = book
        currentBackend = backend
        lastServerCurrentTime = session.currentTime
        lastSession = session
        pendingTimeListened = 0
        AppLogger.player.info("ABS session started. Server currentTime: \(session.currentTime ?? 0)s")
        return session
    }

    public func syncABSSession(progress: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async {
        guard let backend = currentBackend, duration > 0 else { return }

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
            }
        } else {
            await updateProgressDirectly(progress: progress, duration: duration, backend: backend)
        }
    }

    public func closeABSSession(progress: TimeInterval, duration: TimeInterval) async {
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
        guard let book = currentBook else { return }
        let libraryItemId = book.partKey ?? book.id
        do {
            try await audiobookshelfService.updateProgress(
                libraryItemId: libraryItemId,
                currentTime: progress,
                duration: duration,
                backend: backend
            )
            AppLogger.player.info("ABS progress updated directly: \(Int(progress))s")
        } catch {
            AppLogger.player.error("Direct progress update failed: \(error.localizedDescription)")
        }
    }

    public func syncHardcoverProgress(book: Book, progress: Double) async {
        await HardcoverSyncService.shared.syncProgress(book: book, progress: progress)
    }
}
