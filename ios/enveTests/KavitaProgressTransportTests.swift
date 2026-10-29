import Foundation
import Testing

@testable import enve

private final class KavitaProgressTransportStub: KavitaProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var progressStatus = 200
    var loginStatus = 200
    var loginError: URLError?
    var volumeDelay: Duration = .zero
    var activeVolumeRequests = 0
    var peakVolumeRequests = 0
    var seriesJSON = #"[{"id":3,"name":"Fixture","libraryId":5,"format":1}]"#
    var volumesJSON = #"[{"id":7,"chapters":[{"id":11,"range":"1","pages":100,"pagesRead":42},{"id":12,"range":"2","pages":40,"pagesRead":10}]}]"#
    var librariesJSON = #"[{"id":5,"name":"Comics","type":1}]"#

    override func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data: Data
        let status: Int
        switch url.path {
        case "/api/Account/login":
            if let loginError { throw loginError }
            data = Data(#"{"token":"header.payload.signature","apiKey":"image-key"}"#.utf8)
            status = loginStatus
        case "/api/Account":
            data = Data(#"{"apiKey":"image-key"}"#.utf8)
            status = 200
        case "/api/Library/libraries":
            data = Data(librariesJSON.utf8)
            status = 200
        case "/api/image/series-cover":
            data = Data([0x89, 0x50, 0x4E, 0x47])
            status = 200
        case "/api/Series/3":
            data = Data(#"{"id":3,"name":"Fixture","libraryId":5,"format":1}"#.utf8)
            status = 200
        case "/api/Series/v2", "/api/Series/recently-added-v2":
            data = Data(seriesJSON.utf8)
            status = 200
        case "/api/Series/volumes":
            activeVolumeRequests += 1
            peakVolumeRequests = max(peakVolumeRequests, activeVolumeRequests)
            defer { activeVolumeRequests -= 1 }
            if volumeDelay > .zero { try await Task.sleep(for: volumeDelay) }
            data = Data(volumesJSON.utf8)
            status = 200
        case "/api/Reader/image":
            data = Data([1, 2, 3])
            status = progressStatus
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
    @Test(arguments: [401, 403, 404, 429, 500, 503])
    func failedLoginKeepsItsCauseAndCanRecover(status: Int) async throws {
        let provider = KavitaProgressTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://kavita.example.invalid", type: .kavita,
            username: "reader", password: "fixture-password"
        ))
        provider.loginStatus = status
        do {
            try await provider.ensureAuthenticated()
            Issue.record("Expected failed login")
        } catch ProviderError.unauthorized {
            #expect(status == 401)
        } catch ProviderError.serverError(let message) {
            #expect(status != 401)
            #expect(message.contains("HTTP \(status)"))
        }
        #expect(provider.connection.token == nil)
        provider.loginStatus = 200
        try await provider.ensureAuthenticated()
        #expect(provider.connection.token == "header.payload.signature")
        #expect(provider.requests.count == 2)
    }

    @Test func connectionFailureKeepsItsNetworkErrorAndCanRecover() async throws {
        let provider = KavitaProgressTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://kavita.example.invalid", type: .kavita,
            username: "reader", password: "fixture-password"
        ))
        provider.loginError = URLError(.cannotConnectToHost)
        await #expect(throws: URLError(.cannotConnectToHost)) {
            try await provider.ensureAuthenticated()
        }
        #expect(provider.connection.token == nil)
        provider.loginError = nil
        try await provider.ensureAuthenticated()
        #expect(provider.connection.token == "header.payload.signature")
    }

    @Test func comicPagesStreamTheSelectedIssueWithZeroBasedServerPages() async throws {
        let provider = makeProvider()
        let detail = try await provider.fetchFullBookDetails(bookId: "3:7:12", libraryId: "5")
        #expect(provider.capabilities.contains(.serverPageStreaming))
        #expect(try await provider.fetchPageCount(for: detail) == 40)
        #expect(try await provider.fetchPage(1, for: detail) == Data([1, 2, 3]))
        _ = try await provider.fetchPage(40, for: detail)

        let images = provider.requests.filter { $0.url?.path == "/api/Reader/image" }
        #expect(images.map { $0.url?.query } == ["chapterId=12&page=0&apiKey=fixture", "chapterId=12&page=39&apiKey=fixture"])
        #expect(images.allSatisfy { $0.value(forHTTPHeaderField: "X-API-Key") == "fixture" })
        #expect(provider.requests.filter { $0.url?.path == "/api/Series/volumes" }.count == 1)
        #expect(!provider.requests.contains { $0.url?.path.hasPrefix("/api/Download") == true })
        provider.progressStatus = 503
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetchPage(2, for: detail)
        }
    }

    @Test func passwordAndRestoredJWTConnectionsUseTheImageAPIKey() async throws {
        for restored in [false, true] {
            let provider = KavitaProgressTransportStub(connection: ServerConnection(
                name: "Fixture", url: "https://kavita.example.invalid", type: .kavita,
                username: "reader", password: "secret", token: restored ? "header.payload.signature" : nil
            ))
            let book = Book(id: "3:7:12", title: "Issue", source: .kavita,
                            providerId: provider.connection.id, libraryId: "5")
            #expect(try await provider.fetchPageCount(for: book) == 40)
            _ = try await provider.fetchPage(1, for: book)
            let image = try #require(provider.requests.last)
            #expect(image.url?.query == "chapterId=12&page=0&apiKey=image-key")
            #expect(image.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
            #expect(provider.requests.filter { $0.url?.path == "/api/Account" }.count == (restored ? 1 : 0))
        }
    }

    @Test func catalogLoadsVolumesWithBoundedConcurrencyAndKeepsSeriesOrder() async throws {
        let provider = makeProvider()
        provider.seriesJSON = "[" + (1...20).map {
            "{\"id\":\($0),\"name\":\"Series \($0)\",\"libraryId\":5,\"format\":1}"
        }.joined(separator: ",") + "]"
        provider.volumeDelay = .milliseconds(5)

        let books = try await provider.fetchBooks(libraryId: "5")

        #expect(books.count == 40)
        #expect(books.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element.id) == (1...20).map(String.init))
        #expect(provider.peakVolumeRequests > 1 && provider.peakVolumeRequests <= 6)
        #expect(provider.requests.filter { $0.url?.path == "/api/Series/volumes" }.count == 20)
    }

    @Test func batchedLegacyIdentitiesPreserveEarlierBindingsAndOtherConnections() throws {
        let suite = "KavitaIdentityBatch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KavitaIssueIdentityStore(defaults: defaults)
        let connection = UUID()
        #expect(store.legacyChapterIds(connectionId: connection, firstChapters: [(1, 11), (2, 22)]) == [1: 11, 2: 22])
        let reopened = KavitaIssueIdentityStore(defaults: defaults)
        #expect(reopened.legacyChapterIds(connectionId: connection, firstChapters: [(1, 99), (3, 33)]) == [1: 11, 3: 33])
        #expect(store.legacyChapterId(connectionId: connection, seriesId: 3, firstChapterId: 99) == 33)
        #expect(store.legacyChapterId(connectionId: UUID(), seriesId: 1, firstChapterId: 99) == 99)
    }

    @Test func catalogScopesLibraryAndUsesOneBasedQueryPagination() async throws {
        let provider = makeProvider()
        let source = try await provider.makeCatalogBatchSource(libraryId: "5", resumeAfter: nil, expectedSnapshotIdentifier: nil)
        let batch = try #require(try await source.next())
        #expect(batch.books.map(\.id) == ["3", "3:7:12"])
        let request = try #require(provider.requests.first { $0.url?.path == "/api/Series/v2" })
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
        #expect(books.map(\.libraryId) == ["5", "5"])
        let request = try #require(provider.requests.first { $0.url?.path == "/api/Series/recently-added-v2" })
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
        #expect(progress?.updatedAt == ISO8601Timestamp.parse("2026-08-30T18:30:00.123Z"))
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

    @Test func coverFetchUsesBearerAfterPasswordLogin() async throws {
        let provider = KavitaProgressTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://kavita.example.invalid", type: .kavita,
            username: "reader", password: "secret"
        ))
        let url = try #require(URL(string: "https://kavita.example.invalid/api/image/series-cover?seriesId=3"))

        _ = try await provider.fetchCoverImage(url: url)

        let request = try #require(provider.requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test func apiKeyCoverFetchUsesAPIKeyHeader() async throws {
        let provider = makeProvider()
        let url = try #require(URL(string: "https://kavita.example.invalid/api/image/series-cover?seriesId=3"))

        _ = try await provider.fetchCoverImage(url: url)

        let request = try #require(provider.requests.last)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "fixture")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func catalogSeparatesIssueIdentityFormatAndProgress() async throws {
        let provider = makeProvider()
        let books = try await provider.fetchBooks(libraryId: "5")
        #expect(books.map(\.id) == ["3", "3:7:12"])
        #expect(books.map(\.title) == ["Fixture · Issue 1", "Fixture · Issue 2"])
        #expect(books.map { $0.seriesInfo?.name } == ["Fixture", "Fixture"])
        #expect(books.map(\.ebookProgress) == [0.42, 0.25])
        #expect(books.allSatisfy { $0.isComic })
        #expect(books.map(\.comicMetadata) == [
            ComicMetadata(seriesID: "3", issueLabel: "Issue 1", pageCount: 100, resourceID: "11"),
            ComicMetadata(seriesID: "3", issueLabel: "Issue 2", pageCount: 40, resourceID: "12"),
        ])
        #expect(books[1].coverURL?.query == "chapterId=12")
        let detail = try await provider.fetchFullBookDetails(bookId: books[1].id, libraryId: "5")
        #expect(detail.id == books[1].id)
        try await provider.updateEbookProgress(for: detail, progress: 0.5, epubLocator: nil)
        let bodyData = try #require(provider.requests.last?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Int])
        #expect(body == ["seriesId": 3, "libraryId": 5, "volumeId": 7, "chapterId": 12, "pageNum": 20])
        _ = try await provider.fetchEbookProgress(for: detail)
        #expect(provider.requests.last?.url?.query == "chapterId=12")
    }

    @Test func identicallyNamedSeriesKeepSeparateIssueLists() async throws {
        let provider = makeProvider()
        provider.seriesJSON = #"[{"id":3,"name":"Fixture","libraryId":5,"format":1},{"id":4,"name":"Fixture","libraryId":5,"format":1}]"#
        let series = try await provider.fetchSeries(libraryId: "5")
        #expect(Set(series.map(\.id)) == ["kavita-series-3", "kavita-series-4"])
        #expect(series.allSatisfy { $0.bookCount == 2 })
        #expect(Set(series.flatMap(\.books)) == ["3", "3:7:12", "4", "4:7:12"])
    }

    @Test func legacyIdentityRemainsBoundWhenVolumesAreReordered() async throws {
        let provider = makeProvider()
        _ = try await provider.fetchBooks(libraryId: "5")
        provider.volumesJSON = #"[{"id":8,"chapters":[{"id":15,"range":"0","pages":20}]},{"id":7,"chapters":[{"id":12,"range":"2","pages":40},{"id":11,"range":"1","pages":100}]}]"#
        let books = try await provider.fetchBooks(libraryId: "5")
        #expect(books.map(\.id) == ["3:8:15", "3:7:12", "3"])
        let legacy = try #require(books.first { $0.id == "3" })
        try await provider.updateEbookProgress(for: legacy, progress: 0.5, epubLocator: nil)
        let bodyData = try #require(provider.requests.last?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Int])
        #expect(body["chapterId"] == 11)
    }

    @Test func removedIssueNeverOpensAnotherChapter() async throws {
        let provider = makeProvider()
        let books = try await provider.fetchBooks(libraryId: "5")
        provider.volumesJSON = #"[{"id":7,"chapters":[{"id":12,"range":"2","pages":40}]}]"#
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetchEbookProgress(for: books[0])
        }
        let wrongVolume = Book(id: "3:9:12", title: "Removed", source: .kavita, providerId: provider.connection.id, libraryId: "5")
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetchEbookProgress(for: wrongVolume)
        }
    }

    @Test func legacyIdentityStoreSurvivesReopeningAndSeparatesConnections() throws {
        let suite = "KavitaIssueIdentityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = KavitaIssueIdentityStore(defaults: defaults)
        let connection = UUID()
        #expect(first.legacyChapterId(connectionId: connection, seriesId: 3, firstChapterId: 11) == 11)
        let reopened = KavitaIssueIdentityStore(defaults: defaults)
        #expect(reopened.legacyChapterId(connectionId: connection, seriesId: 3, firstChapterId: 12) == 11)
        #expect(reopened.legacyChapterId(connectionId: UUID(), seriesId: 3, firstChapterId: 12) == 12)
    }

    private func makeProvider() -> KavitaProgressTransportStub {
        KavitaProgressTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://kavita.example.invalid", type: .kavita, token: "fixture"
        ))
    }
}
