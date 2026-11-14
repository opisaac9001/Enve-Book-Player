import Foundation
import Testing
@testable import enve

@MainActor
struct BookloreRecommendationTests {
    @Test func decodesLegacyRecommendations() throws {
        let result = try decode(#"[{"book":{"id":42,"title":"Next"},"similarityScore":0.9}]"#)
        #expect(result.map { $0.book.id } == [42])
        #expect(result.first?.similarityScore == 0.9)
    }

    @Test func ranksLegacyRecommendationsByScoreKeepingTiesInServerOrder() throws {
        let result = try decode(#"""
            [{"book":{"id":1},"similarityScore":0.2},{"book":{"id":2},"similarityScore":0.8},
             {"book":{"id":3}},{"book":{"id":4},"similarityScore":0.8},{"book":{"id":5},"similarityScore":0.5}]
            """#)
        #expect(result.map { $0.book.id } == [2, 4, 5, 1, 3])
    }

    @Test func decodesPlainBooksInServerOrder() throws {
        let result = try decode(#"[{"id":43,"metadata":{"title":"First"}},{"id":42},{"id":44}]"#)
        #expect(result.map { $0.book.id } == [43, 42, 44])
        #expect(result.allSatisfy { $0.similarityScore == nil })
    }

    @Test func decodesEmptyRecommendations() throws {
        #expect(try decode("[]").isEmpty)
    }

    @Test func dropsDuplicatesAndTheSourceBook() throws {
        #expect(try decode(#"[{"id":7},{"id":43},{"id":7},{"id":99}]"#).map { $0.book.id } == [43, 99])
        let legacy = try decode(#"[{"book":{"id":43},"similarityScore":0.1},{"book":{"id":43},"similarityScore":0.6}]"#)
        #expect(legacy.map { $0.book.id } == [43])
        #expect(legacy.first?.similarityScore == 0.6)
    }

    @Test func rejectsMalformedPayloads() {
        for payload in [#"[{}]"#, #"[{"book":null,"id":42}]"#, #"[{"id":"invalid"}]"#, #"{"content":[]}"#, ""] {
            #expect(throws: DecodingError.self) { try decode(payload) }
        }
    }

    @Test func treatsMissingOrForbiddenRecommendationsAsEmpty() throws {
        for status in [403, 404] {
            #expect(try BookloreProvider.recommendations(from: Data("oops".utf8), statusCode: status, excluding: 7).isEmpty)
        }
    }

    @Test func surfacesOtherHTTPErrors() {
        for status in [401, 500, 503] {
            #expect(throws: ProviderError.self) {
                try BookloreProvider.recommendations(from: Data("[]".utf8), statusCode: status, excluding: 7)
            }
        }
    }

    @Test func requestsAreScopedToTheirConnectionAndUnwrapCompanionAudiobooks() throws {
        let first = BookloreProvider(connection: connection("first.example.invalid"))
        let second = BookloreProvider(connection: connection("second.example.invalid"))

        let (ebook, ebookSource) = try first.makeRecommendationsRequest(bookId: "42", limit: 99)
        let (audiobook, audiobookSource) = try second.makeRecommendationsRequest(
            bookId: BookloreProvider.companionAudiobookIDPrefix + "42", limit: 0)

        #expect(ebookSource == 42 && audiobookSource == 42)
        #expect(ebook.url?.host == "first.example.invalid")
        #expect(audiobook.url?.host == "second.example.invalid")
        #expect(ebook.url?.path == "/api/v1/books/42/recommendations")
        #expect(audiobook.url?.path == "/api/v1/books/42/recommendations")
        #expect(ebook.url?.query == "limit=25")
        #expect(audiobook.url?.query == "limit=1")
    }

    @Test func rejectsNonNumericBookIds() {
        let provider = BookloreProvider(connection: connection("first.example.invalid"))
        for id in ["", "abc", BookloreProvider.companionAudiobookIDPrefix] {
            #expect(throws: ProviderError.self) { try provider.makeRecommendationsRequest(bookId: id, limit: 12) }
        }
    }

    private func decode(_ payload: String) throws -> [BookloreProvider.Recommendation] {
        try BookloreProvider.recommendations(from: Data(payload.utf8), statusCode: 200, excluding: 7)
    }

    private func connection(_ host: String) -> ServerConnection {
        ServerConnection(name: host, url: "https://\(host)", type: .booklore, token: "header.payload.signature")
    }
}
