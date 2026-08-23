import Foundation

@MainActor
final class WebDAVDownloadPlanProvider: DownloadPlanProviding {
    let id: String

    init(id: String) {
        self.id = id
    }

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
        guard let connection = resolveConnection(for: book, from: service.providerConnections.connections) else {
            throw UnifiedDownloadService.DownloadError.missingCredentials("WebDAV connection not found")
        }

        var tracks = book.audioTracks ?? []
        if tracks.isEmpty,
            let filePath = book.filePath,
            let baseURL = URL(string: connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        {
            let relativePath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath
            let url = baseURL.appendingPathComponent(relativePath)
            tracks = [
                AudioTrack(
                    index: 0,
                    filePath: filePath,
                    contentUrl: url.absoluteString,
                    duration: 0,
                    startOffset: 0
                )
            ]
        }

        guard let contentURL = tracks.first?.contentUrl, let url = URL(string: contentURL) else {
            throw UnifiedDownloadService.DownloadError.invalidURL
        }

        let headers = authorizationHeaders(for: connection)
        if tracks.count <= 1 {
            try await service.rawHTTP11Download(
                taskId: task.id,
                bookId: task.bookId,
                url: url,
                headers: headers
            )
        } else {
            try await service.downloadMultipleRemoteFiles(task: task, tracks: tracks, headers: headers)
        }
    }

    private static func resolveConnection(
        for book: Book,
        from connections: [ServerConnection]
    ) -> ServerConnection? {
        let connected = connections.filter {
            ($0.type == .webdav || $0.type == .torbox || $0.type == .premiumize) && $0.isConnected
        }
        if let direct = connected.first(where: { $0.id == book.providerId }) {
            return direct
        }
        if let backendId = book.backendId {
            return connected.first {
                $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == backendId
            }
        }
        return connected.first
    }

    static func basicAuthorizationHeader(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private static func authorizationHeaders(for connection: ServerConnection) -> [String: String] {
        guard let username = connection.username, !username.isEmpty else { return [:] }
        let password = connection.password ?? connection.token ?? ""
        return ["Authorization": "Basic \(basicAuthorizationHeader(username: username, password: password))"]
    }
}
