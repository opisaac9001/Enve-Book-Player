import Foundation

@MainActor
final class JellyfinDownloadPlanProvider: DownloadPlanProviding {
    let id = "jellyfin"

    func makePlan(for book: Book) throws -> DownloadPlan {
        DownloadPlan(
            providerId: id,
            files: [DownloadPlanFile(source: .providerSession, headers: [:], relativePath: nil)],
            destination: .audiobookDirectory,
            postProcessing: [.cacheOfflineAssets]
        ) { service, task, book in
            guard let backend = Self.resolveBackend(for: book, through: service.providerConnections),
                let token = backend.token, !token.isEmpty
            else {
                throw UnifiedDownloadService.DownloadError.missingCredentials("Jellyfin not configured")
            }
            let itemId = book.ratingKey.isEmpty ? book.id : book.ratingKey
            guard let url = Self.streamURL(baseURL: backend.url, itemId: itemId, token: token) else {
                throw UnifiedDownloadService.DownloadError.invalidURL
            }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            await service.startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
        }
    }

    static func streamURL(baseURL: String, itemId: String, token: String) -> URL? {
        let baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(baseURL)/Audio/\(itemId)/stream") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return components.url
    }

    private static func resolveBackend(
        for book: Book,
        through connections: any ProviderConnectionAccessing
    ) -> BackendConfig? {
        let enabled = connections.allBackends().filter { $0.type == .jellyfin && $0.enabled }
        if let backendId = book.backendId, let match = enabled.first(where: { $0.id == backendId }) {
            return match
        }
        if let first = enabled.first {
            return first
        }
        guard let credentials = try? SecureTokenStorage.shared.loadCredentials(forService: "jellyfin") else {
            return nil
        }
        return BackendConfig(
            id: "jellyfin_legacy",
            name: "Jellyfin",
            type: .jellyfin,
            url: credentials.serverUrl,
            token: credentials.token,
            enabled: true,
            username: credentials.username,
            password: nil,
            userId: nil,
            selectedLibraryIds: nil
        )
    }
}

@MainActor
final class EmbyDownloadPlanProvider: DownloadPlanProviding {
    let id = "emby"

    func makePlan(for book: Book) throws -> DownloadPlan {
        DownloadPlan(
            providerId: id,
            files: [DownloadPlanFile(source: .providerSession, headers: [:], relativePath: nil)],
            destination: book.mediaType == .ebook ? .readerAsset : .audiobookDirectory,
            postProcessing: book.mediaType == .ebook
                ? [.validateEbook, .persistReaderAsset, .cacheOfflineAssets]
                : [.cacheOfflineAssets]
        ) { service, task, book in
            if book.mediaType == .ebook {
                try await service.downloadEbookViaProvider(task: task, book: book)
                return
            }
            guard let backend = Self.resolveBackend(for: book, through: service.providerConnections),
                let token = backend.token, !token.isEmpty
            else {
                throw UnifiedDownloadService.DownloadError.missingCredentials("Emby not configured")
            }
            guard !book.ratingKey.isEmpty,
                let url = Self.streamURL(baseURL: backend.url, itemId: book.ratingKey, token: token)
            else {
                throw UnifiedDownloadService.DownloadError.invalidURL
            }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            await service.startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
        }
    }

    static func streamURL(baseURL: String, itemId: String, token: String) -> URL? {
        let normalized = EmbyProvider.normalizeServerURL(baseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(normalized)/Audio/\(itemId)/stream") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return components.url
    }

    private static func resolveBackend(
        for book: Book,
        through connections: any ProviderConnectionAccessing
    ) -> BackendConfig? {
        let enabled = connections.allBackends().filter { $0.type == .emby && $0.enabled }
        if let backendId = book.backendId, let match = enabled.first(where: { $0.id == backendId }) {
            return match
        }
        if let first = enabled.first {
            return first
        }
        guard let credentials = try? SecureTokenStorage.shared.loadCredentials(forService: "emby") else {
            return nil
        }
        return BackendConfig(
            id: "emby_legacy",
            name: "Emby",
            type: .emby,
            url: EmbyProvider.normalizeServerURL(credentials.serverUrl),
            token: credentials.token,
            enabled: true,
            username: credentials.username,
            password: nil,
            userId: nil,
            selectedLibraryIds: nil
        )
    }
}
