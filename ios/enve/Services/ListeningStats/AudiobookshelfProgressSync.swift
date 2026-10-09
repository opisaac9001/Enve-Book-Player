import Foundation
import Logging

final class AudiobookshelfProgressSync: ProgressSyncProtocol, @unchecked Sendable {
    let sourceType: ListeningSourceType = .audiobookshelf

    private let service: AudiobookshelfService
    private let storageService: StorageService

    var backend: BackendConfig?

    init(service: AudiobookshelfService = .shared, storageService: StorageService = StorageService()) {
        self.service = service
        self.storageService = storageService
    }

    private func getBackend() throws -> BackendConfig {
        if let backend = backend {
            return backend
        }

        let backends = AppState.shared.providerConnections.allBackends()
            .filter { $0.type == .audiobookshelf && $0.enabled }
        guard let first = backends.first else {
            throw ProgressSyncError.noBackendConfigured
        }
        return first
    }

    func testConnection() async throws -> Bool {
        let backend = try getBackend()
        return try await service.validateToken(backend: backend)
    }

    func fetchAllProgress() async throws -> [ServerBookProgress] {
        let backend = try getBackend()

        let allProgress = try await service.getAllProgress(backend: backend)

        return allProgress.compactMap { progress -> ServerBookProgress? in
            guard let libraryItemId = progress.libraryItemId else { return nil }

            return ServerBookProgress.fromAudiobookshelf(
                itemId: libraryItemId,
                currentTime: progress.currentTime ?? 0,
                duration: progress.duration ?? 0,
                progress: progress.progress ?? 0,
                isFinished: progress.resolvedIsFinished,
                lastUpdate: progress.lastUpdate,
                backendId: backend.id
            )
        }
    }

    func fetchProgress(serverItemId: String) async throws -> ServerBookProgress? {
        let backend = try getBackend()

        guard let progress = try await service.getProgress(libraryItemId: serverItemId, backend: backend) else {
            return nil
        }

        guard let libraryItemId = progress.libraryItemId else { return nil }

        return ServerBookProgress.fromAudiobookshelf(
            itemId: libraryItemId,
            currentTime: progress.currentTime ?? 0,
            duration: progress.duration ?? 0,
            progress: progress.progress ?? 0,
            isFinished: progress.resolvedIsFinished,
            lastUpdate: progress.lastUpdate,
            backendId: backend.id
        )
    }

    func reportProgress(serverItemId: String, position: TimeInterval, duration: TimeInterval, isFinished: Bool) async throws {
        let backend = try getBackend()

        try await service.updateProgress(
            libraryItemId: serverItemId,
            currentTime: position,
            duration: duration,
            isFinished: isFinished,
            backend: backend
        )

        AppLogger.player.info("Reported progress: \(serverItemId) at \(Int(position))s / \(Int(duration))s")
    }
}
