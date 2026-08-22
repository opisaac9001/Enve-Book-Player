import Foundation

actor iTunesPodcastProvider {

    static let shared = iTunesPodcastProvider()

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    struct iTunesPodcast: Identifiable, Codable, Equatable {
        let id: String
        let title: String
        let author: String?
        let feedURL: String
        let coverURL: URL?
        let genres: [String]
        let trackCount: Int
        let releaseDate: Date?

        var asSubscription: PodcastSubscription {
            PodcastSubscription(
                id: feedURL,
                title: title,
                author: author,
                coverURL: coverURL,
                feedURL: feedURL,
                dateSubscribed: Date()
            )
        }
    }

    func search(term: String, limit: Int = 25) async throws -> [iTunesPodcast] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "entity", value: "podcast"),
        ]

        guard let url = components.url else {
            throw PodcastSearchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw PodcastSearchError.searchFailed
        }

        let searchResponse = try makeDecoder().decode(iTunesSearchResponse.self, from: data)

        return searchResponse.results.compactMap { result -> iTunesPodcast? in
            guard let feedURL = result.feedUrl, !feedURL.isEmpty else { return nil }

            return iTunesPodcast(
                id: String(result.collectionId ?? result.trackId ?? 0),
                title: result.collectionName ?? result.trackName ?? "Unknown",
                author: result.artistName,
                feedURL: feedURL,
                coverURL: result.artworkUrl600.flatMap { URL(string: $0) }
                    ?? result.artworkUrl100.flatMap { URL(string: $0) },
                genres: result.genres ?? [],
                trackCount: result.trackCount ?? 0,
                releaseDate: result.releaseDate
            )
        }
    }

    func lookup(collectionId: String) async throws -> iTunesPodcast? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: collectionId),
            URLQueryItem(name: "entity", value: "podcast"),
        ]

        guard let url = components.url else { return nil }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }

        let searchResponse = try makeDecoder().decode(iTunesSearchResponse.self, from: data)

        guard let result = searchResponse.results.first,
            let feedURL = result.feedUrl, !feedURL.isEmpty
        else { return nil }

        return iTunesPodcast(
            id: String(result.collectionId ?? 0),
            title: result.collectionName ?? "Unknown",
            author: result.artistName,
            feedURL: feedURL,
            coverURL: result.artworkUrl600.flatMap { URL(string: $0) },
            genres: result.genres ?? [],
            trackCount: result.trackCount ?? 0,
            releaseDate: result.releaseDate
        )
    }

    private struct iTunesSearchResponse: Codable {
        let resultCount: Int
        let results: [iTunesResult]
    }

    private struct iTunesResult: Codable {
        let collectionId: Int?
        let trackId: Int?
        let collectionName: String?
        let trackName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl100: String?
        let artworkUrl600: String?
        let genres: [String]?
        let trackCount: Int?
        let releaseDate: Date?
        let collectionExplicitness: String?
    }

    enum PodcastSearchError: Error, LocalizedError {
        case invalidURL
        case searchFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid search URL"
            case .searchFailed: return "Podcast search failed"
            }
        }
    }
}
