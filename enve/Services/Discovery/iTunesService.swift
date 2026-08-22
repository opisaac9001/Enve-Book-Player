import Foundation
import Logging

struct iTunesAudiobook: Codable {
    let wrapperType: String?
    let artistId: Int?
    let collectionId: Int?
    let trackId: Int?
    let artistName: String?
    let collectionName: String?
    let trackName: String?
    let collectionCensoredName: String?
    let trackCensoredName: String?
    let artistViewUrl: String?
    let collectionViewUrl: String?
    let trackViewUrl: String?
    let previewUrl: String?
    let artworkUrl30: String?
    let artworkUrl60: String?
    let artworkUrl100: String?
    let collectionPrice: Double?
    let trackPrice: Double?
    let releaseDate: String?
    let collectionExplicitness: String?
    let trackExplicitness: String?
    let discCount: Int?
    let discNumber: Int?
    let trackCount: Int?
    let trackNumber: Int?
    let trackTimeMillis: Int?
    let country: String?
    let currency: String?
    let primaryGenreName: String?
    let description: String?
    let longDescription: String?
    let copyright: String?

    var id: Int? {
        return collectionId ?? trackId
    }
}

struct iTunesSearchResponse: Codable {
    let resultCount: Int
    let results: [iTunesAudiobook]
}

final class iTunesService {
    static let shared = iTunesService()
    private init() {}

    private let baseURL = "https://itunes.apple.com/search"

    private func upgradeToHTTPS(_ urlString: String?) -> String? {
        guard let s = urlString, !s.isEmpty else { return urlString }
        if s.hasPrefix("http://") {
            return "https://" + s.dropFirst("http://".count)
        }
        return s
    }

    private func getHighResArtwork(_ artworkUrl: String?) -> String? {
        guard let url = upgradeToHTTPS(artworkUrl) else { return nil }
        let highRes = url.replacingOccurrences(of: "100x100", with: "600x600")
        if !highRes.hasPrefix("https://") {
            return "https://" + highRes.dropFirst("http://".count)
        }
        return highRes
    }

    func search(query: String, limit: Int = 20, country: String = "US") async throws -> [iTunesAudiobook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        AppLogger.network.info("[Catalog-B] searching: \(trimmed)")

        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "media", value: "audiobook"),
            URLQueryItem(name: "entity", value: "audiobook"),
            URLQueryItem(name: "limit", value: String(min(limit, 200))),
            URLQueryItem(name: "country", value: country),
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
                AppLogger.network.error("[Catalog-B] search error: \(http.statusCode)")
                throw NSError(
                    domain: "iTunesService",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Search failed (\(http.statusCode)): \(snippet)"]
                )
            }
        }

        let decoded = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
        AppLogger.network.info("[Catalog-B] \(decoded.results.count) results")

        return decoded.results
    }

    func lookup(id: Int, country: String = "US") async throws -> iTunesAudiobook? {
        AppLogger.network.info("[Catalog-B] lookup: id=\(id)")

        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            throw URLError(.badURL)
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "audiobook"),
            URLQueryItem(name: "country", value: country),
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
                AppLogger.network.error("[Catalog-B] lookup error: \(http.statusCode)")
                throw NSError(
                    domain: "iTunesService",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Lookup failed (\(http.statusCode)): \(snippet)"]
                )
            }
        }

        let decoded = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
        AppLogger.network.info("[Catalog-B] lookup: \(decoded.resultCount) result(s)")

        return decoded.results.first
    }

    func toMetadataLayer(_ audiobook: iTunesAudiobook) -> iTunesMetadataLayer {
        let title = audiobook.trackCensoredName ?? audiobook.trackName ?? audiobook.collectionCensoredName ?? audiobook.collectionName

        let authors = audiobook.artistName.map { [$0] }

        let artworkURL = getHighResArtwork(audiobook.artworkUrl100 ?? audiobook.artworkUrl60 ?? audiobook.artworkUrl30)

        let durationSeconds = audiobook.trackTimeMillis.map { TimeInterval($0) / 1000.0 }

        let description = audiobook.longDescription ?? audiobook.description

        return iTunesMetadataLayer(
            trackId: audiobook.trackId,
            title: title,
            authors: authors,
            narrator: nil,
            description: description,
            publisher: nil,
            publishedDate: audiobook.releaseDate,
            duration: durationSeconds,
            artworkURL: artworkURL,
            previewURL: upgradeToHTTPS(audiobook.previewUrl),
            genre: audiobook.primaryGenreName,
            copyright: audiobook.copyright,
            trackViewUrl: upgradeToHTTPS(audiobook.trackViewUrl)
        )
    }
}
