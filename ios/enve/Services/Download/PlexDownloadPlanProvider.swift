import Foundation
import Logging

@MainActor
final class PlexDownloadPlanProvider: DownloadPlanProviding {
    let id = "plex"

    func makePlan(for book: Book) throws -> DownloadPlan {
        DownloadPlan(
            providerId: id,
            files: [DownloadPlanFile(source: .providerSession, headers: [:], relativePath: nil)],
            destination: .audiobookDirectory,
            postProcessing: [.cacheOfflineAssets]
        ) { service, task, book in
            try await Self.execute(service: service, task: task, book: book)
        }
    }

    private static func execute(
        service: UnifiedDownloadService,
        task: BookDownloadTask,
        book: Book
    ) async throws {
        let connection = resolveConnection(for: book, from: service.providerConnections.connections)
        let serverURL = connection?.url ?? PlexAuthStore.shared.loadServerUrl()
        let token = connection?.token ?? PlexAuthStore.shared.tokenForServerRequests()

        guard let serverURL, let token else {
            throw UnifiedDownloadService.DownloadError.missingCredentials(
                "Plex credentials not found. Please ensure the server is connected."
            )
        }

        let streamPath = normalizedStreamPath(book.partKey ?? book.id)
        guard var components = URLComponents(string: serverURL) else {
            throw UnifiedDownloadService.DownloadError.invalidURL
        }
        components.path = streamPath
        components.queryItems = [
            URLQueryItem(name: "download", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        guard let url = components.url else {
            throw UnifiedDownloadService.DownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        AppLogger.network.debug(
            "Plex download diagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) pathKind=\(pathKind(book.partKey ?? book.id))"
        )
        await service.startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
    }

    private static func resolveConnection(
        for book: Book,
        from connections: [ServerConnection]
    ) -> ServerConnection? {
        let connected = connections.filter { $0.type == .plex && $0.isConnected }
        return connected.first(where: { $0.id == book.providerId }) ?? connected.first
    }

    static func normalizedStreamPath(_ partKey: String) -> String {
        if partKey.hasPrefix("/library/parts/") {
            return partKey
        }
        if partKey.hasPrefix("library/parts/") {
            return "/\(partKey)"
        }
        if partKey.allSatisfy(\.isNumber) {
            return "/library/parts/\(partKey)/file"
        }
        return partKey.hasPrefix("/") ? partKey : "/\(partKey)"
    }

    private static func pathKind(_ partKey: String) -> String {
        if partKey.hasPrefix("/library/parts/") { return "absolute" }
        if partKey.hasPrefix("library/parts/") { return "relative" }
        if partKey.allSatisfy(\.isNumber) { return "numeric" }
        return "other"
    }
}
