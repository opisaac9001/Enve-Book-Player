import Foundation

extension SiloProvider {

    struct SimilarItem: Decodable, Sendable {
        let mediaItemID: String
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case mediaItemID = "media_item_id"
            case reason
        }
    }

    func fetchSimilarItems(bookId: String, limit: Int = 12) async throws -> [SimilarItem] {
        guard !bookId.isEmpty else { return [] }
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let request = try makeRequest(
            path: "/recommendations/similar/\(bookId)",
            query: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        )
        let response = try await send(request, as: SimilarItemsResponse.self)
        return response.items
    }

    private struct SimilarItemsResponse: Decodable {
        let items: [SimilarItem]
    }
}
