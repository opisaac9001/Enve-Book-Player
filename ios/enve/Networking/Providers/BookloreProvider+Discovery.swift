import Foundation

extension BookloreProvider {

    struct Recommendation: Decodable, Sendable {
        struct RecommendedBook: Decodable, Sendable {
            let id: Int
            let title: String?
        }

        let book: RecommendedBook
        let similarityScore: Double?
    }

    func fetchRecommendations(bookId: String, limit: Int = 12) async throws -> [Recommendation] {
        guard let id = Int(bookId) else { throw ProviderError.invalidURL }
        let request = try makeRequest(
            path: "/api/v1/books/\(id)/recommendations",
            queryItems: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 25)))]
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode != 404, response.statusCode != 403 else { return [] }
        guard (200...299).contains(response.statusCode) else {
            throw ProviderError.serverError("Grimmory returned HTTP \(response.statusCode) for recommendations")
        }
        return try JSONDecoder().decode([Recommendation].self, from: data)
    }
}
