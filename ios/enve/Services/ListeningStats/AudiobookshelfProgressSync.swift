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
                isFinished: progress.isFinished ?? false,
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
            isFinished: progress.isFinished ?? false,
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

    func fetchItemListeningSessions(libraryItemId: String, page: Int = 0, itemsPerPage: Int = 20) async throws -> [HistorySession] {
        let backend = try getBackend()

        let url = try buildURL(
            backend: backend,
            path: "/api/me/item/listening-sessions/\(libraryItemId)",
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

        struct ABSSessionDetail: Codable {
            let id: String
            let libraryItemId: String?
            let timeListening: TimeInterval?
            let currentTime: TimeInterval?
            let startedAt: TimeInterval?
            let updatedAt: TimeInterval?
            let displayTitle: String?
            let duration: TimeInterval?
            let startTime: TimeInterval?
        }

        struct ABSSessionsResponse: Codable {
            let total: Int
            let sessions: [ABSSessionDetail]
        }

        let decoder = JSONDecoder()
        let sessionsResponse = try decoder.decode(ABSSessionsResponse.self, from: data)

        return sessionsResponse.sessions.compactMap { s -> HistorySession? in
            let sessionDuration = Int(s.timeListening ?? 0)
            guard sessionDuration > 0 else { return nil }

            let startDate: Date
            if let st = s.startedAt ?? s.startTime {
                startDate = Date(timeIntervalSince1970: st / 1000.0)
            } else {
                startDate = Date()
            }

            let endDate: Date
            if let ut = s.updatedAt {
                endDate = Date(timeIntervalSince1970: ut / 1000.0)
            } else {
                endDate = startDate.addingTimeInterval(TimeInterval(sessionDuration))
            }

            let progress: Double? = {
                guard let dur = s.duration, dur > 0, let ct = s.currentTime else { return nil }
                return ct / dur
            }()

            return HistorySession(
                id: s.id,
                bookId: s.libraryItemId ?? libraryItemId,
                mediaType: "audiobook",
                startTime: startDate,
                endTime: endDate,
                durationSeconds: sessionDuration,
                startProgress: nil,
                endProgress: progress,
                progressDelta: nil,
                startLocation: nil,
                endLocation: nil,
                pagesRead: nil,
                source: .audiobookshelf
            )
        }
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
