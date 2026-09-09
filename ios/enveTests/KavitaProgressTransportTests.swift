import Foundation
import Testing

@testable import enve

private final class KavitaProgressTransportStub: KavitaProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var progressStatus = 200

    override func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data: Data
        let status: Int
        switch url.path {
        case "/api/Series/v2", "/api/Series/recently-added-v2":
            data = Data(#"[{"id":3,"name":"Fixture","libraryId":5}]"#.utf8)
            status = 200
        case "/api/Series/volumes":
            data = Data(#"[{"id":7,"chapters":[{"id":11,"pages":100}]}]"#.utf8)
            status = 200
        case "/api/Reader/get-progress":
            data = Data(#"{"chapterId":11,"pageNum":42,"lastModifiedUtc":"2026-08-30T18:30:00.123Z"}"#.utf8)
            status = 200
        default:
            data = Data()
            status = progressStatus
        }
        return (data, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct KavitaProgressTransportTests {
    @Test func catalogScopesLibraryAndUsesOneBasedQueryPagination() async throws {
        let provider = makeProvider()
        let source = try await provider.makeCatalogBatchSource(libraryId: "5", resumeAfter: nil, expectedSnapshotIdentifier: nil)
        let batch = try #require(try await source.next())
        #expect(batch.books.map(\.id) == ["3"])
        let request = try #require(provider.requests.last)
        #expect(request.url?.query == "pageNumber=1&pageSize=100")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let statements = try #require(body["statements"] as? [[String: Any]])
        #expect(statements.first?["field"] as? Int == 19)
        #expect(statements.first?["value"] as? String == "5")
        #expect(body["pageNumber"] == nil)
    }

    @Test func recentlyAddedRequiresPostAndLibraryFilter() async throws {
        let provider = makeProvider()
        let books = try await provider.fetchRecentBooks(libraryId: "5", limit: 7)
        #expect(books.map(\.libraryId) == ["5"])
        let request = try #require(provider.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/Series/recently-added-v2")
        #expect(request.url?.query == "pageNumber=1&pageSize=7")
    }

    @Test func writesChapterProgressAndAllowsResetToPageZero() async throws {
        let provider = makeProvider()
        let book = Book(id: "3", title: "Fixture", source: .kavita, providerId: provider.connection.id, libraryId: "5")
        try await provider.updateEbookProgress(for: book, progress: 0.42, epubLocator: nil)
        let request = try #require(provider.requests.last)
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Int])
        #expect(request.url?.path == "/api/Reader/progress")
        #expect(body == ["seriesId": 3, "libraryId": 5, "volumeId": 7, "chapterId": 11, "pageNum": 42])

        try await provider.updateEbookProgress(for: book, progress: 0, epubLocator: nil)
        let resetData = try #require(provider.requests.last?.httpBody)
        let reset = try #require(JSONSerialization.jsonObject(with: resetData) as? [String: Int])
        #expect(reset["pageNum"] == 0)
    }

    @Test func readsTheSameChapterUsedForDownloadsAndUploads() async throws {
        let provider = makeProvider()
        let book = Book(id: "3", title: "Fixture", source: .kavita, providerId: provider.connection.id, libraryId: "5")
        let progress = try await provider.fetchEbookProgress(for: book)
        #expect(progress?.progress == 0.42)
        #expect(progress?.updatedAt == ProviderProgressDate.parse("2026-08-30T18:30:00.123Z"))
        #expect(provider.requests.last?.url?.query == "chapterId=11")
    }

    @Test func failedUploadThrowsForRetry() async throws {
        let provider = makeProvider()
        provider.progressStatus = 500
        let book = Book(id: "3", title: "Fixture", source: .kavita, providerId: provider.connection.id, libraryId: "5")
        await #expect(throws: (any Error).self) {
            try await provider.updateEbookProgress(for: book, progress: 0.5, epubLocator: nil)
        }
    }

    private func makeProvider() -> KavitaProgressTransportStub {
        KavitaProgressTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://kavita.example.invalid", type: .kavita, token: "fixture"
        ))
    }
}
