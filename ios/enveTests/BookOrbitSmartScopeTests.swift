import Foundation
import Testing

@testable import enve

@MainActor
private final class SmartScopeSourceStub: BookOrbitSmartScopeSource {
    var scopeResults: [Result<[BookOrbitProvider.SmartScope], any Error>] = []
    var pageResults: [Result<BookOrbitProvider.CollectionPage, any Error>] = []
    private(set) var queries: [(scopeId: Int, query: BookOrbitProvider.SmartScopeQuery)] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    var holdsNextPage = false

    func fetchSmartScopes() async throws -> [BookOrbitProvider.SmartScope] {
        try scopeResults.removeFirst().get()
    }

    func fetchSmartScopeBooks(
        scopeId: Int,
        query: BookOrbitProvider.SmartScopeQuery
    ) async throws -> BookOrbitProvider.CollectionPage {
        queries.append((scopeId, query))
        let result = pageResults.removeFirst()
        if holdsNextPage {
            holdsNextPage = false
            await withCheckedContinuation { gates.append($0) }
        }
        return try result.get()
    }

    func release() {
        gates.forEach { $0.resume() }
        gates = []
    }

    static func scope(_ id: Int, _ name: String, count: Int?) -> BookOrbitProvider.SmartScope {
        .init(id: id, name: name, icon: nil, isOwner: true, displayOrder: id, bookCount: count)
    }

    static let providerId = UUID()

    static func page(_ ids: ClosedRange<Int>, total: Int, page: Int) -> BookOrbitProvider.CollectionPage {
        .init(
            books: ids.map { Book(id: String($0), title: "Book \($0)", providerId: providerId, source: .bookOrbit) },
            total: total,
            page: page,
            size: BookOrbitSmartScopesModel.pageSize
        )
    }
}

@MainActor
struct BookOrbitSmartScopeTests {
    @Test func scopesDecodeAndTheFirstPageUsesTheDocumentedQueryBody() async throws {
        let server = BookOrbitFixtureServer([
            .init(status: 200, json: """
            [{"id":9,"userId":1,"name":"Unread sci-fi","icon":"Rocket","filter":null,"defaultSort":[],"isPublic":false,
              "coverAspectRatio":"portrait","syncToKobo":false,"koboSyncEnabled":false,"isOwner":true,"displayOrder":2,
              "bookCount":61,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"},
             {"id":4,"userId":2,"name":"Shared picks","icon":null,"filter":null,"defaultSort":[],"isPublic":true,
              "coverAspectRatio":"portrait","syncToKobo":false,"koboSyncEnabled":false,"isOwner":false,"displayOrder":1,
              "bookCount":null,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}]
            """),
            .init(status: 200, json: """
            {"items":[{"id":301,"libraryId":2,"title":"Fixture Novel","authors":["A. Writer"],"files":[
              {"id":77,"format":"epub","role":"primary"}],"rating":4,"readingProgress":25,
              "readStatus":{"status":"reading","updatedAt":"2026-11-10T00:00:00Z"},"hasCover":false}],
             "total":61,"page":0,"size":50}
            """),
        ])
        defer { server.close() }

        let scopes = try await server.provider.fetchSmartScopes()
        #expect(scopes.map(\.id) == [4, 9])
        #expect(scopes.map(\.bookCount) == [nil, 61])
        #expect(scopes.last?.name == "Unread sci-fi")

        let page = try await server.provider.fetchSmartScopeBooks(scopeId: 9, query: .init())
        #expect(page.total == 61)
        #expect(page.hasMore)
        let book = try #require(page.books.first)
        #expect(book.id == "301")
        #expect(book.libraryId == "2")
        #expect(book.mediaType == .ebook)
        #expect(book.personalRating == 4)

        #expect(server.requests.map(\.url?.path) == ["/api/v1/smart-scopes", "/api/v1/smart-scopes/9/books/query"])
        #expect(server.requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        let body = try server.jsonBody(1)
        #expect(body.keys.sorted() == ["pagination", "sort"])
        #expect((body["sort"] as? [Any])?.isEmpty == true)
        #expect(body["pagination"] as? [String: Int] == ["page": 0, "size": 50])
    }

    @Test func laterPagesAndSearchTravelInTheQueryBody() throws {
        var query = BookOrbitProvider.SmartScopeQuery(page: 3, size: 50, search: "  dune ")
        #expect(query.body["pagination"] as? [String: Int] == ["page": 3, "size": 50])
        #expect(query.body["q"] as? String == "dune")
        query.search = "   "
        #expect(query.body["q"] == nil)
    }

    @Test func pendingEditsOverlayServerCardsOnlyForTheirOwnAccount() async throws {
        let cardPage = """
        {"items":[{"id":301,"libraryId":2,"title":"Fixture Novel","authors":[],"files":[
          {"id":77,"format":"epub","role":"primary"}],"rating":2,"readingProgress":40,
          "readStatus":{"status":"reading","updatedAt":"2026-11-10T00:00:00Z"},"hasCover":false}],
         "total":1,"page":0,"size":50}
        """
        let server = BookOrbitFixtureServer([.init(status: 200, json: cardPage), .init(status: 200, json: cardPage)])
        defer { server.close() }
        let connection = server.provider.connection
        func key(_ kind: PendingBookEditKind, account: ServerConnection) -> PendingBookEditKey {
            PendingBookEditKey(
                connectionId: connection.id,
                accountKey: ServerMirrorFingerprint.accountKey(for: account),
                bookId: "301",
                kind: kind
            )
        }
        var otherAccount = connection
        otherAccount.username = "another-reader"
        server.pendingEdits.enqueue(.rating(1), key: key(.rating, account: otherAccount))

        let untouched = try #require(try await server.provider.fetchSmartScopeBooks(scopeId: 9, query: .init()).books.first)
        #expect(untouched.personalRating == 2)
        #expect(untouched.serverReadStatus == "READING")

        server.pendingEdits.enqueue(.rating(5), key: key(.rating, account: connection))
        server.pendingEdits.enqueue(.readStatus("read"), key: key(.readStatus, account: connection))

        let overlaid = try #require(try await server.provider.fetchSmartScopeBooks(scopeId: 9, query: .init()).books.first)
        #expect(overlaid.personalRating == 5)
        #expect(overlaid.serverReadStatus == "READ")
        #expect(overlaid.isFinished)
        #expect(overlaid.ebookProgress == 1)
        #expect(server.provider.pendingEditBookIds(.readStatus) == ["301"])
        #expect(server.provider.pendingEditBookIds(.rating) == ["301"])
    }

    @Test func selectingAScopeLoadsItsFirstPageWithExactTotals() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [.success([SmartScopeSourceStub.scope(1, "First", count: 120), SmartScopeSourceStub.scope(2, "Second", count: 3)])]
        source.pageResults = [.success(SmartScopeSourceStub.page(1...50, total: 120, page: 0))]
        let model = BookOrbitSmartScopesModel(source: source)

        await model.loadScopes()
        await model.reloadTask?.value

        #expect(model.scopesState == .ready)
        #expect(model.selectedScopeId == 1)
        #expect(model.books.count == 50)
        #expect(model.total == 120)
        #expect(model.hasMore)
        #expect(source.queries.first?.query == .init(page: 0, size: 50, search: ""))
    }

    @Test func nextPagesAppendUntilTheTotalIsReached() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [.success([SmartScopeSourceStub.scope(1, "First", count: 120)])]
        source.pageResults = [
            .success(SmartScopeSourceStub.page(1...50, total: 120, page: 0)),
            .success(SmartScopeSourceStub.page(51...100, total: 120, page: 1)),
            .success(SmartScopeSourceStub.page(101...120, total: 120, page: 2)),
        ]
        let model = BookOrbitSmartScopesModel(source: source)
        await model.loadScopes()
        await model.reloadTask?.value

        await model.loadMore()
        #expect(model.books.count == 100)
        await model.loadMore()

        #expect(model.books.map(\.id) == (1...120).map(String.init))
        #expect(!model.hasMore)
        #expect(source.queries.map(\.query.page) == [0, 1, 2])
        await model.loadMore()
        #expect(source.queries.count == 3)
    }

    @Test func failedNextPageKeepsTheListAndRetriesTheSamePage() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [.success([SmartScopeSourceStub.scope(1, "First", count: 80)])]
        source.pageResults = [
            .success(SmartScopeSourceStub.page(1...50, total: 80, page: 0)),
            .failure(URLError(.timedOut)),
            .success(SmartScopeSourceStub.page(51...80, total: 80, page: 1)),
        ]
        let model = BookOrbitSmartScopesModel(source: source)
        await model.loadScopes()
        await model.reloadTask?.value

        await model.loadMore()
        #expect(model.books.count == 50)
        #expect(model.pageError != nil)
        #expect(model.hasMore)

        // Scrolling again must not hammer the failed page; only the explicit retry does.
        await model.loadMore()
        #expect(source.queries.count == 2)

        await model.loadMore(retry: true)
        #expect(model.pageError == nil)
        #expect(model.books.count == 80)
        #expect(source.queries.map(\.query.page) == [0, 1, 1])
    }

    @Test func changingScopeOrSearchStartsAgainFromTheFirstPage() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [.success([SmartScopeSourceStub.scope(1, "First", count: 120), SmartScopeSourceStub.scope(2, "Second", count: 2)])]
        source.pageResults = [
            .success(SmartScopeSourceStub.page(1...50, total: 120, page: 0)),
            .success(SmartScopeSourceStub.page(51...100, total: 120, page: 1)),
            .success(SmartScopeSourceStub.page(900...901, total: 2, page: 0)),
            .success(SmartScopeSourceStub.page(900...900, total: 1, page: 0)),
        ]
        let model = BookOrbitSmartScopesModel(source: source)
        await model.loadScopes()
        await model.reloadTask?.value
        await model.loadMore()
        model.search = "left over"

        model.select(scopeId: 2)
        #expect(model.books.isEmpty)
        #expect(model.search.isEmpty)
        await model.reloadTask?.value
        #expect(model.books.map(\.id) == ["900", "901"])
        #expect(model.total == 2)
        #expect(!model.hasMore)

        model.search = "nine"
        model.searchChanged()
        await model.reloadTask?.value
        #expect(model.books.map(\.id) == ["900"])
        #expect(source.queries.last?.scopeId == 2)
        #expect(source.queries.last?.query == .init(page: 0, size: 50, search: "nine"))

        // An unchanged query is not sent twice.
        model.searchChanged()
        await model.reloadTask?.value
        #expect(source.queries.count == 4)
    }

    @Test func aSupersededFetchNeverReplacesTheNewerSelection() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [.success([SmartScopeSourceStub.scope(1, "First", count: 1), SmartScopeSourceStub.scope(2, "Second", count: 1)])]
        source.pageResults = [
            .success(SmartScopeSourceStub.page(10...10, total: 1, page: 0)),
            .success(SmartScopeSourceStub.page(20...20, total: 1, page: 0)),
        ]
        source.holdsNextPage = true
        let model = BookOrbitSmartScopesModel(source: source)
        await model.loadScopes()
        while source.queries.isEmpty { await Task.yield() }

        model.select(scopeId: 2)
        await model.reloadTask?.value
        #expect(model.books.map(\.id) == ["20"])

        source.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.books.map(\.id) == ["20"])
        #expect(model.selectedScopeId == 2)
    }

    @Test func refreshFailuresKeepWhatWasAlreadyLoaded() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [
            .success([SmartScopeSourceStub.scope(1, "First", count: 2)]),
            .failure(URLError(.notConnectedToInternet)),
        ]
        source.pageResults = [
            .success(SmartScopeSourceStub.page(1...2, total: 2, page: 0)),
            .failure(URLError(.notConnectedToInternet)),
        ]
        let model = BookOrbitSmartScopesModel(source: source)
        await model.loadScopes()
        await model.reloadTask?.value

        await model.loadScopes()
        await model.reloadBooks()

        #expect(model.scopesState == .ready)
        #expect(model.scopes.count == 1)
        #expect(model.scopesRefreshError != nil)
        #expect(model.booksState == .ready)
        #expect(model.books.count == 2)
        #expect(model.booksRefreshError != nil)
    }

    @Test func emptyAndFailedStatesAreDistinct() async throws {
        let empty = SmartScopeSourceStub()
        empty.scopeResults = [.success([])]
        let emptyModel = BookOrbitSmartScopesModel(source: empty)
        await emptyModel.loadScopes()
        #expect(emptyModel.scopesState == .ready)
        #expect(emptyModel.scopes.isEmpty)
        #expect(emptyModel.booksState == .idle)

        let failing = SmartScopeSourceStub()
        failing.scopeResults = [.failure(ProviderError.serverError("BookOrbit returned HTTP 500 for /api/v1/smart-scopes"))]
        let failedModel = BookOrbitSmartScopesModel(source: failing)
        await failedModel.loadScopes()
        guard case .failed = failedModel.scopesState else {
            Issue.record("A failed first load must not look like an empty list")
            return
        }

        let unsupported = SmartScopeSourceStub()
        unsupported.scopeResults = [.failure(BookOrbitProvider.FeatureError.unavailable)]
        let unsupportedModel = BookOrbitSmartScopesModel(source: unsupported)
        await unsupportedModel.loadScopes()
        #expect(unsupportedModel.scopesState == .unavailable)
    }
    @Test func searchReloadCannotRaceTheNextPage() async throws {
        let source = SmartScopeSourceStub()
        source.scopeResults = [.success([SmartScopeSourceStub.scope(1, "All", count: 100)])]
        source.pageResults = [.success(SmartScopeSourceStub.page(1...50, total: 100, page: 0)),
                              .success(SmartScopeSourceStub.page(80...80, total: 1, page: 0))]
        let model = BookOrbitSmartScopesModel(source: source)
        await model.loadScopes()
        await model.reloadTask?.value
        source.holdsNextPage = true
        model.search = "specific book"
        model.searchChanged()
        await model.loadMore()
        while source.queries.count < 2 { await Task.yield() }
        #expect(!model.hasMore)
        #expect(source.queries.count == 2)
        source.release()
        await model.reloadTask?.value
        #expect(model.books.map(\.id) == ["80"])
        #expect(model.total == 1)
    }

}
