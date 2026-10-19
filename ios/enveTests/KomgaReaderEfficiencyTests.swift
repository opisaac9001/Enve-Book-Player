import Foundation
import Testing

@testable import enve

@MainActor
struct KomgaReaderEfficiencyTests {
    @Test func readerMetadataAvoidsRepeatingBookAndPageListRequests() async throws {
        let provider = KomgaReaderTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://komga.example.invalid", type: .komga
        ))
        let book = try await provider.fetchFullBookDetails(bookId: "issue", libraryId: "comics")

        #expect(book.comicMetadata == ComicMetadata(seriesID: "series", pageCount: 24))
        #expect(try await provider.fetchPageCount(for: book) == 24)
        #expect(try await provider.fetchComicReadingDirection(for: book) == .rightToLeft)
        #expect(provider.requests.compactMap { $0.url?.path } == ["/api/v1/books/issue", "/api/v1/series/series"])

        _ = try await provider.fetchEbookProgress(for: book)
        #expect(provider.requests.filter { $0.url?.path == "/api/v1/books/issue" }.count == 2)
    }

    @Test func pageListStillWorksWithoutBookMetadata() async throws {
        let provider = KomgaReaderTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://komga.example.invalid", type: .komga
        ))
        let book = Book(id: "issue", title: "Issue", source: .komga, mediaType: .ebook,
                        ebookFormat: "cbz", providerId: provider.connection.id, libraryId: "comics")

        #expect(try await provider.fetchPageCount(for: book) == 2)
        #expect(try await provider.fetchPage(2, for: book) == Data([1, 2, 3]))
        #expect(provider.requests.compactMap { $0.url?.path } == ["/api/v1/books/issue/pages", "/api/v1/books/issue/pages/2"])
    }
}

private final class KomgaReaderTransportStub: KomgaProvider, @unchecked Sendable {
    var requests: [URLRequest] = []

    override func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data: Data
        switch url.path {
        case "/api/v1/books/issue":
            data = Data(#"{"id":"issue","name":"Issue","seriesId":"series","media":{"pagesCount":24,"mediaType":"application/zip"}}"#.utf8)
        case "/api/v1/series/series":
            data = Data(#"{"id":"series","name":"Series","metadata":{"readingDirection":"RIGHT_TO_LEFT"}}"#.utf8)
        case "/api/v1/books/issue/pages":
            data = Data(#"[{"number":1},{"number":2}]"#.utf8)
        case "/api/v1/books/issue/pages/2":
            data = Data([1, 2, 3])
        default:
            throw ProviderError.invalidResponse
        }
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
