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

    func fetchListeningStats() async throws -> AudiobookshelfListeningStats {
        let backend = try getBackend()

        let url = try buildURL(backend: backend, path: "/api/me/listening-stats")
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProgressSyncError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AudiobookshelfListeningStats.self, from: data)
    }

    func fetchListeningSessions(page: Int = 0, itemsPerPage: Int = 50) async throws -> [AudiobookshelfListeningStats.AudiobookshelfSession]
    {
        let backend = try getBackend()

        let url = try buildURL(
            backend: backend,
            path: "/api/me/listening-sessions",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "itemsPerPage", value: String(itemsPerPage)),
            ]
        )
        let request = createRequest(url: url, backend: backend)

        let (data, response) = try await InsecureURLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProgressSyncError.invalidResponse
        }

        struct SessionsResponse: Codable {
            let total: Int
            let sessions: [AudiobookshelfListeningStats.AudiobookshelfSession]
        }

        let decoder = JSONDecoder()
        let sessionsResponse = try decoder.decode(SessionsResponse.self, from: data)
        return sessionsResponse.sessions
    }

    private func buildURL(backend: BackendConfig, path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        guard let baseURL = backend.baseURL else {
            throw ProgressSyncError.noBackendConfigured
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        components?.path = path
        components?.queryItems = queryItems?.isEmpty == true ? nil : queryItems

        guard let url = components?.url else {
            throw ProgressSyncError.invalidResponse
        }

        return url
    }

    private func createRequest(url: URL, backend: BackendConfig) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let token = backend.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }
}
