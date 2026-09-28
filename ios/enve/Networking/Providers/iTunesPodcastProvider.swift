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

        return searchResponse.results.compactMap(Self.podcast(from:))
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

        return searchResponse.results.first.flatMap(Self.podcast(from:))
    }

    func topPodcasts(genreId: Int?, limit: Int = 40) async throws -> [iTunesPodcast] {
        let storefront = (Locale.current.region?.identifier ?? "US").lowercased()
        let genrePath = genreId.map { "/genre=\($0)" } ?? ""
        guard let chartURL = URL(string: "https://itunes.apple.com/\(storefront)/rss/toppodcasts/limit=\(limit)\(genrePath)/json") else {
            throw PodcastSearchError.invalidURL
        }
        let (chartData, chartResponse) = try await URLSession.shared.data(from: chartURL)
        guard (chartResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw PodcastSearchError.searchFailed
        }
        let ids = try JSONDecoder().decode(ChartResponse.self, from: chartData).feed.entry?.map(\.id.attributes.id) ?? []
        guard !ids.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: storefront),
        ]
        guard let lookupURL = components.url else { throw PodcastSearchError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: lookupURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PodcastSearchError.searchFailed
        }
        let shows = try makeDecoder().decode(iTunesSearchResponse.self, from: data).results.compactMap(Self.podcast(from:))
        let showsById = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { showsById[$0] }
    }

    private static func podcast(from result: iTunesResult) -> iTunesPodcast? {
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

    private struct ChartResponse: Decodable {
        let feed: Feed

        struct Feed: Decodable {
            let entry: [Entry]?
        }

        struct Entry: Decodable {
            let id: EntryID
        }

        struct EntryID: Decodable {
            let attributes: Attributes
        }

        struct Attributes: Decodable {
            let id: String

            enum CodingKeys: String, CodingKey {
                case id = "im:id"
            }
        }
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
