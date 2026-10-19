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
        try await service.downloadAudiobookViaProvider(task: task, book: book)
    }

    static func requests(
        for book: Book,
        provider: any PlaybackSessionProvider
    ) async throws -> [(request: URLRequest, mimeType: String?)] {
        try Task.checkCancellation()
        let session = try await provider.startPlaybackSession(for: book)
        try Task.checkCancellation()
        guard !session.audioTracks.isEmpty else { throw UnifiedDownloadService.DownloadError.invalidURL }
        let headers = provider.getStreamingHeaders()
        return try session.audioTracks.sorted {
            $0.startOffset == $1.startOffset ? $0.index < $1.index : $0.startOffset < $1.startOffset
        }.map { track in
            guard let url = URL(string: track.contentUrl),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
            else { throw UnifiedDownloadService.DownloadError.invalidURL }
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            return (request, track.mimeType)
        }
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

}
