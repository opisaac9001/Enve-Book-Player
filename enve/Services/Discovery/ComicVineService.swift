import Foundation

private struct ComicVineResponse: Codable {
    let statusCode: Int
    let results: [ComicVineVolume]

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case results
    }
}

private struct ComicVineVolume: Codable {
    let id: Int
    let name: String?
    let description: String?
    let image: ComicVineImage?
    let publisher: ComicVinePublisher?
    let startYear: String?
    let countOfIssues: Int?
    let people: [ComicVinePerson]?

    let issueNumber: String?
    let volumeDetail: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, image, publisher, people
        case startYear = "start_year"
        case countOfIssues = "count_of_issues"
        case issueNumber = "issue_number"
        case volumeDetail = "volume"
    }
}

private struct ComicVineImage: Codable {
    let mediumUrl: String?
    let superUrl: String?
    let thumbUrl: String?

    enum CodingKeys: String, CodingKey {
        case mediumUrl = "medium_url"
        case superUrl = "super_url"
        case thumbUrl = "thumb_url"
    }
}

private struct ComicVinePublisher: Codable {
    let name: String?
}

private struct ComicVinePerson: Codable {
    let name: String?
    let role: String?
}

struct ComicVineMetadataLayer: Equatable, Sendable {
    let comicVineId: Int
    let title: String
    let authors: [String]
    let description: String?
    let coverUrl: String?
    let publisher: String?
    let startYear: String?
    let issueCount: Int?
}

final class ComicVineService: Sendable {
    static let shared = ComicVineService()
    private init() {}

    private let baseURL = URL(string: "https://comicvine.gamespot.com/api")!

    var hasApiKey: Bool {
        guard let key = SettingsManager.shared.comicVineApiKey else { return false }
        return !key.isEmpty
    }

    func validateAPIKey(_ apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ComicVineError.noApiKey
        }

        _ = try await performSearch(query: "Made in Abyss", limit: 1, apiKey: trimmed)
    }

    func search(query: String, limit: Int = 20) async throws -> [ComicVineMetadataLayer] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let apiKey = SettingsManager.shared.comicVineApiKey, !apiKey.isEmpty else {
            throw ComicVineError.noApiKey
        }

        return try await performSearch(query: trimmed, limit: limit, apiKey: apiKey)
    }

    private func performSearch(query: String, limit: Int, apiKey: String) async throws -> [ComicVineMetadataLayer] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appending(path: "volumes"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "filter", value: "name:\(trimmed)"),
            URLQueryItem(name: "limit", value: String(min(limit, 100))),
            URLQueryItem(name: "field_list", value: "id,name,description,image,publisher,start_year,count_of_issues"),
            URLQueryItem(name: "sort", value: "name:asc"),
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("enve/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "ComicVineService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ComicVine search failed"]
            )
        }

        let decoded = try JSONDecoder().decode(ComicVineResponse.self, from: data)
        guard decoded.statusCode == 1 else {
            throw NSError(
                domain: "ComicVineService",
                code: decoded.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ComicVine API error (code \(decoded.statusCode))"]
            )
        }

        return decoded.results.prefix(limit).map(toMetadataLayer)
    }

    private func toMetadataLayer(_ volume: ComicVineVolume) -> ComicVineMetadataLayer {
        let coverUrl = volume.image?.superUrl ?? volume.image?.mediumUrl ?? volume.image?.thumbUrl

        let authors = (volume.people ?? [])
            .compactMap { $0.name }

        let plainDescription = volume.description.map { stripHTML($0) }

        return ComicVineMetadataLayer(
            comicVineId: volume.id,
            title: volume.name ?? "",
            authors: authors,
            description: plainDescription,
            coverUrl: coverUrl,
            publisher: volume.publisher?.name,
            startYear: volume.startYear,
            issueCount: volume.countOfIssues
        )
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ComicVineError: LocalizedError {
        case noApiKey

        var errorDescription: String? {
            switch self {
            case .noApiKey:
                return "ComicVine API key not configured. Add your key in Settings → Metadata Hub."
            }
        }
    }
}
