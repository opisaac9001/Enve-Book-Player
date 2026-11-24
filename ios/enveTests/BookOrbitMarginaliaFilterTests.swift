import Foundation
import Testing

@testable import enve

@MainActor
private final class MarginaliaSourceStub: BookOrbitMarginaliaSource {
    var pages: [Result<BookOrbitProvider.AnnotationHubPage, any Error>] = []
    private(set) var queries: [BookOrbitProvider.AnnotationHubQuery] = []
    private(set) var exports: [BookOrbitProvider.AnnotationHubQuery] = []

    func fetchAnnotations(_ query: BookOrbitProvider.AnnotationHubQuery) async throws -> BookOrbitProvider.AnnotationHubPage {
        queries.append(query)
        return try pages.removeFirst().get()
    }

    func fetchAnnotationBooks(trashed: Bool, search: String?) async throws -> [BookOrbitProvider.AnnotationHubBookFacet] { [] }
    func trashAnnotations(ids: [Int]) async throws {}
    func restoreAnnotations(ids: [Int]) async throws {}
    func purgeAnnotation(id: Int) async throws {}

    func exportAnnotations(_ query: BookOrbitProvider.AnnotationHubQuery, format: String) async throws -> URL {
        exports.append(query)
        return URL(fileURLWithPath: "/dev/null")
    }

    static func page(_ ids: ClosedRange<Int>, total: Int) throws -> BookOrbitProvider.AnnotationHubPage {
        let items = ids.map {
            #"{"id":\#($0),"bookId":7,"text":"Line \#($0)","note":"n","chapterTitle":null,"origin":"web","createdAt":"2026-11-01T00:00:00Z","bookTitle":"Fixture","author":null}"#
        }
        let json = #"{"items":[\#(items.joined(separator: ","))],"total":\#(total),"stats":{"books":1,"withNotes":\#(total)}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookOrbitProvider.AnnotationHubPage.self, from: Data(json.utf8))
    }
}

@MainActor
struct BookOrbitMarginaliaFilterTests {
    private func names(_ query: BookOrbitProvider.AnnotationHubQuery) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: query.queryItems.map { ($0.name, $0.value) })
    }

    @Test func hasNoteIsSentOnlyWhenTheFilterIsOn() {
        var query = BookOrbitProvider.AnnotationHubQuery(page: 2, pageSize: 50, bookId: 7, search: " whale ", trashed: true)
        #expect(names(query)["hasNote"] == nil)
        #expect(names(query) == ["page": "2", "pageSize": "50", "status": "trashed", "bookId": "7", "search": "whale"])

        query.hasNote = true
        #expect(names(query)["hasNote"] == "true")
        #expect(names(query).count == 6)
    }

    @Test func notesOnlyQueryKeepsBookAndSearchScopeAndRestartsPaging() async throws {
        let source = MarginaliaSourceStub()
        source.pages = [
            .success(try MarginaliaSourceStub.page(1...50, total: 120)),
            .success(try MarginaliaSourceStub.page(1...50, total: 120)),
            .success(try MarginaliaSourceStub.page(51...100, total: 120)),
            .success(try MarginaliaSourceStub.page(1...3, total: 3)),
            .success(try MarginaliaSourceStub.page(1...50, total: 120)),
        ]
        let model = BookOrbitMarginaliaModel(source: source)
        model.search = "whale"
        await model.reload()
        model.select(bookId: 7)
        await model.reloadTask?.value
        await model.loadMore()
        #expect(model.items.count == 100)

        model.select(onlyWithNotes: true)
        await model.reloadTask?.value

        let filtered = try #require(source.queries.last)
        #expect(filtered.hasNote)
        #expect(filtered.page == 1)
        #expect(filtered.bookId == 7)
        #expect(filtered.search == "whale")
        #expect(filtered.trashed == false)
        #expect(model.onlyWithNotes)
        #expect(model.items.count == 3)
        #expect(!model.canLoadMore)

        _ = await model.export(format: "csv")
        #expect(source.exports.last?.hasNote == true)
        #expect(source.exports.last?.bookId == 7)

        model.select(onlyWithNotes: false)
        await model.reloadTask?.value
        #expect(source.queries.last?.hasNote == false)
        #expect(source.queries.last?.page == 1)
        #expect(source.queries.map(\.page) == [1, 1, 2, 1, 1])
    }

    @Test func aFailedNextPageDoesNotExhaustTheListAndCanBeRetried() async throws {
        let source = MarginaliaSourceStub()
        source.pages = [
            .success(try MarginaliaSourceStub.page(1...50, total: 80)),
            .failure(URLError(.timedOut)),
            .success(try MarginaliaSourceStub.page(51...80, total: 80)),
        ]
        let model = BookOrbitMarginaliaModel(source: source)
        await model.reload()

        await model.loadMore()
        #expect(model.items.count == 50)
        #expect(model.loadMoreError != nil)
        #expect(model.canLoadMore)

        // Scrolling again must not hammer the failed page; only the explicit retry does.
        await model.loadMore()
        #expect(source.queries.count == 2)

        await model.loadMore(retry: true)
        #expect(model.loadMoreError == nil)
        #expect(model.items.count == 80)
        #expect(!model.canLoadMore)
        #expect(source.queries.map(\.page) == [1, 2, 2])
    }
}
