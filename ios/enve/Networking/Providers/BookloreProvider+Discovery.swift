import Foundation

extension BookloreProvider {

    struct Recommendation: Decodable, Sendable {
        struct RecommendedBook: Decodable, Sendable {
            let id: Int
            let title: String?
        }

        let book: RecommendedBook
        let similarityScore: Double?

        private enum CodingKeys: String, CodingKey {
            case book, similarityScore
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.book) {
                book = try container.decode(RecommendedBook.self, forKey: .book)
                similarityScore = try container.decodeIfPresent(Double.self, forKey: .similarityScore)
            } else {
                book = try RecommendedBook(from: decoder)
                similarityScore = nil
            }
        }
    }

    func fetchRecommendations(bookId: String, limit: Int = 12) async throws -> [Recommendation] {
        let (request, sourceId) = try makeRecommendationsRequest(bookId: bookId, limit: limit)
        let (data, response) = try await performAuthorizedRequest(request)
        return try Self.recommendations(from: data, statusCode: response.statusCode, excluding: sourceId)
    }

    func makeRecommendationsRequest(bookId: String, limit: Int) throws -> (URLRequest, sourceId: Int) {
        let numericId = bookId.hasPrefix(Self.companionAudiobookIDPrefix)
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId
        guard let id = Int(numericId) else { throw ProviderError.invalidURL }
        let request = try makeRequest(
            path: "/api/v1/books/\(id)/recommendations",
            queryItems: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 25)))]
        )
        return (request, id)
    }

    // Legacy wrappers carry scores and are re-ranked; plain books arrive already ordered by the server.
    static func recommendations(from data: Data, statusCode: Int, excluding sourceId: Int) throws -> [Recommendation] {
        guard statusCode != 404, statusCode != 403 else { return [] }
        guard (200...299).contains(statusCode) else {
            throw ProviderError.serverError("Grimmory returned HTTP \(statusCode) for recommendations")
        }
        var seen: Set<Int> = [sourceId]
        return try JSONDecoder().decode([Recommendation].self, from: data)
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.similarityScore ?? -.infinity
                let right = rhs.element.similarityScore ?? -.infinity
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { seen.insert($0.book.id).inserted }
    }
}
