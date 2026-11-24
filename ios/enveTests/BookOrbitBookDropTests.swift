import Foundation
import Testing

@testable import enve

@MainActor
private final class BookDropSourceStub: BookOrbitBookDropSource {
    var access = BookOrbitProvider.BookDockAccess(canUse: true, canFinalize: true, managesAll: false)
    var pages: [Result<BookOrbitProvider.BookDockPage, any Error>] = []
    var finalizeResults: [Result<BookOrbitProvider.BookDockFinalizeResult, any Error>] = []
    var updateError: (any Error)?
    private(set) var queries: [BookOrbitProvider.BookDockQuery] = []
    private(set) var updates: [(id: Int, selected: [String: Any]?, target: (libraryId: Int, folderId: Int)?)] = []
    private(set) var finalized: [[Int]] = []
    private(set) var discarded: [[Int]] = []
    var holdsFinalize = false
    private var gate: CheckedContinuation<Void, Never>?

    func fetchBookDockAccess() async throws -> BookOrbitProvider.BookDockAccess { access }

    func fetchBookDockFiles(_ query: BookOrbitProvider.BookDockQuery) async throws -> BookOrbitProvider.BookDockPage {
        queries.append(query)
        guard !pages.isEmpty else { return .init(items: [], total: 0, page: query.page, size: query.limit) }
        return try pages.removeFirst().get()
    }

    func fetchBookDockSummary() async throws -> BookOrbitProvider.BookDockSummary {
        throw BookOrbitProvider.FeatureError.unavailable
    }

    func fetchBookDockDestinations() async throws -> [BookOrbitProvider.BookDockDestination] { [] }

    func uploadBookDockFile(at fileURL: URL, filename: String) async throws -> BookOrbitProvider.BookDockFile {
        throw ProviderError.notImplemented
    }

    func updateBookDockFile(
        id: Int,
        selectedMetadata: [String: Any]?,
        target: (libraryId: Int, folderId: Int)?
    ) async throws -> BookOrbitProvider.BookDockFile {
        updates.append((id, selectedMetadata, target))
        if let updateError { throw updateError }
        return try BookOrbitBookDropTests.file(id: id, title: selectedMetadata?["title"] as? String ?? "Saved")
    }

    func setBookDockTarget(ids: [Int], libraryId: Int, folderId: Int) async throws -> BookOrbitProvider.BookDockTargetResult {
        .init(total: ids.count, updated: ids.count, failed: 0)
    }

    func applyFetchedBookDockMetadata(ids: [Int]) async throws -> BookOrbitProvider.BookDockApplyResult {
        .init(total: ids.count, applied: 0, skipped: 0, skippedEdited: ids.count)
    }

    func refetchBookDockMetadata(id: Int) async throws {}

    func finalizeBookDockFiles(ids: [Int]) async throws -> BookOrbitProvider.BookDockFinalizeResult {
        finalized.append(ids)
        if holdsFinalize {
            holdsFinalize = false
            await withCheckedContinuation { gate = $0 }
        }
        return try finalizeResults.removeFirst().get()
    }

    func discardBookDockFiles(ids: [Int]) async throws {
        discarded.append(ids)
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
struct BookOrbitBookDropTests {
    static func fileJSON(id: Int, title: String, status: String = "ready", extra: String = "") -> String {
        """
        {"id":\(id),"fileName":"upload-\(id).epub","fileSize":2048,"format":"epub","status":"\(status)",
         "embeddedMetadata":{"title":"Embedded \(id)","authors":["File Author"],"language":"en"},
         "selectedMetadata":{"title":"\(title)","goodreadsId":"gr-\(id)","seriesIndex":2.5},
         "fetchedMetadata":{"title":"Fetched \(id)","publisher":"Fixture House","publishedYear":1999},
         "targetLibraryId":3,"targetFolderId":8,"confidence":72,"fetchedMetadataSources":null,"errorMessage":null,
         "metadataEditedAt":"2026-11-19T10:00:00.000Z","createdAt":"2026-11-19T09:00:00.000Z",
         "updatedAt":"2026-11-19T10:00:00.000Z","unitFiles":[]\(extra)}
        """
    }

    static func file(id: Int, title: String, status: String = "ready") throws -> BookOrbitProvider.BookDockFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var json = fileJSON(id: id, title: title, status: status)
        json = json.replacingOccurrences(of: ".000Z", with: "Z")
        return try decoder.decode(BookOrbitProvider.BookDockFile.self, from: Data(json.utf8))
    }

    static func page(_ ids: ClosedRange<Int>, total: Int, page: Int) throws -> BookOrbitProvider.BookDockPage {
        .init(items: try ids.map { try file(id: $0, title: "Title \($0)") }, total: total, page: page, size: 50)
    }

    @Test func stagedFilesDecodeWithLayeredMetadataAndHoldDetails() async throws {
        let hold = #","dockId":4,"holdReason":"duplicate","holdDetail":{"libraryName":"Fiction","bookId":90},"alsoIn":["Archive"]"#
        let server = BookOrbitFixtureServer([
            .init(status: 200, json: """
            {"items":[\(Self.fileJSON(id: 11, title: "Chosen Title", extra: hold)),
                      \(Self.fileJSON(id: 12, title: "Second", status: "fetching"))],"total":57,"page":1,"size":50}
            """)
        ])
        defer { server.close() }

        let page = try await server.provider.fetchBookDockFiles(.init(status: "ready", search: " dune "))

        #expect(page.total == 57)
        #expect(page.hasMore)
        let file = try #require(page.items.first)
        #expect(file.holdReason == "duplicate")
        #expect(file.holdDetail?.libraryName == "Fiction")
        #expect(file.alsoIn == ["Archive"])
        #expect(file.metadataEditedAt != nil)
        // Chosen over fetched over embedded, field by field.
        #expect(file.metadata.title == "Chosen Title")
        #expect(file.metadata.publisher == "Fixture House")
        #expect(file.metadata.authors == ["File Author"])
        #expect(file.metadata.seriesIndex == "2.5")
        #expect(BookOrbitBookDropFormat.status(file) == "Needs review: this book is already in Fiction")
        #expect(page.items.last?.isSettled == false)
        let raw = try #require(file.selectedMetadataJSON)
        let selected = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(selected["goodreadsId"] as? String == "gr-11")

        let request = try #require(server.requests.first)
        #expect(request.url?.path == "/api/v1/book-dock/files")
        let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) }) == [
            "page": "1", "limit": "50", "status": "ready", "search": "dune",
        ])
    }

    @Test func forbiddenRequestsThrowAccessDeniedInsteadOfAnEmptyInbox() async throws {
        let server = BookOrbitFixtureServer([
            .init(status: 403, json: #"{"statusCode":403,"message":"Missing permission: book_dock_access"}"#)
        ])
        defer { server.close() }

        do {
            _ = try await server.provider.fetchBookDockFiles(.init())
            Issue.record("A 403 must not decode as an empty page")
        } catch BookOrbitProvider.BookDockError.accessDenied(let message) {
            #expect(message == "Missing permission: book_dock_access")
        }
    }

    @Test func accountPermissionsDecideWhatTheInboxOffers() async throws {
        let server = BookOrbitFixtureServer([
            .init(status: 200, json: #"{"id":2,"isSuperuser":false,"permissions":["book_dock_access"]}"#),
            .init(status: 200, json: #"{"id":2,"isSuperuser":false,"permissions":["book_dock_access","library_upload","manage_book_dock"]}"#),
            .init(status: 200, json: #"{"id":2,"isSuperuser":false,"permissions":["library_upload"]}"#),
            .init(status: 200, json: #"{"id":1,"isSuperuser":true,"permissions":["*"]}"#),
        ])
        defer { server.close() }

        #expect(try await server.provider.fetchBookDockAccess() == .init(canUse: true, canFinalize: false, managesAll: false))
        #expect(try await server.provider.fetchBookDockAccess() == .init(canUse: true, canFinalize: true, managesAll: true))
        #expect(try await server.provider.fetchBookDockAccess() == .init(canUse: false, canFinalize: false, managesAll: false))
        #expect(try await server.provider.fetchBookDockAccess() == .init(canUse: true, canFinalize: true, managesAll: true))
    }

    @Test func mutationsSendTheDocumentedBodies() async throws {
        let server = BookOrbitFixtureServer([
            .init(status: 200, json: Self.fileJSON(id: 11, title: "Edited")),
            .init(status: 200, json: #"{"total":2,"applied":1,"skipped":0,"skippedEdited":1}"#),
            .init(status: 201, json: """
            {"total":2,"succeeded":1,"failed":1,"results":[
              {"fileId":11,"fileName":"upload-11.epub","newName":"Edited.epub","success":true,"bookId":500},
              {"fileId":12,"fileName":"upload-12.epub","success":false,"isDuplicate":true,"existingBookId":90,
               "message":"Already in Fiction"}]}
            """),
            .init(status: 204, json: ""),
            .init(status: 200, json: #"{"total":2,"updated":2,"failed":0}"#),
        ])
        defer { server.close() }

        _ = try await server.provider.updateBookDockFile(
            id: 11, selectedMetadata: ["title": "Edited", "subtitle": NSNull()], target: (libraryId: 3, folderId: 8)
        )
        let applied = try await server.provider.applyFetchedBookDockMetadata(ids: [11, 12])
        let finalized = try await server.provider.finalizeBookDockFiles(ids: [11, 12])
        try await server.provider.discardBookDockFiles(ids: [12])
        _ = try await server.provider.setBookDockTarget(ids: [11, 12], libraryId: 3, folderId: 8)

        #expect(applied == .init(total: 2, applied: 1, skipped: 0, skippedEdited: 1))
        #expect(finalized.succeeded == 1)
        #expect(finalized.failed == 1)
        #expect(finalized.results.map(BookOrbitBookDropFormat.outcome) == ["Filed as Edited.epub", "Already in Fiction"])

        #expect(server.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PATCH /api/v1/book-dock/files/11",
            "POST /api/v1/book-dock/files/apply-fetched",
            "POST /api/v1/book-dock/finalize",
            "POST /api/v1/book-dock/files/discard",
            "POST /api/v1/book-dock/files/set-target",
        ])
        let update = try server.jsonBody(0)
        #expect(update["targetLibraryId"] as? Int == 3)
        #expect(update["targetFolderId"] as? Int == 8)
        let selected = try #require(update["selectedMetadata"] as? [String: Any])
        #expect(selected["title"] as? String == "Edited")
        #expect(selected["subtitle"] is NSNull)
        #expect(try server.jsonBody(1)["fileIds"] as? [Int] == [11, 12])
        // Destinations ride on each staged file; finalize names only the chosen files.
        #expect(try server.jsonBody(2).keys.sorted() == ["fileIds"])
        #expect(try server.jsonBody(3)["fileIds"] as? [Int] == [12])
        let target = try server.jsonBody(4)
        #expect(target["targetLibraryId"] as? Int == 3)
        #expect(target["targetFolderId"] as? Int == 8)
    }

    @Test func metadataEditsSendOnlyWhatChangedAndClearWithNull() throws {
        let file = try Self.file(id: 11, title: "Chosen")
        var edited = file.metadata
        edited.title = "Renamed"
        edited.publisher = nil
        edited.authors = ["File Author"]

        let changes = edited.changes(from: file.metadata)

        #expect(changes.keys.sorted() == ["publisher", "title"])
        #expect(changes["title"] as? String == "Renamed")
        #expect(changes["publisher"] is NSNull)
    }

    @Test func accountWithoutAccessSeesADeniedStateNotAnEmptyInbox() async throws {
        let source = BookDropSourceStub()
        source.access = .init(canUse: false, canFinalize: false, managesAll: false)
        let model = BookOrbitBookDropModel(source: source)

        await model.load()

        #expect(model.state == .denied(BookOrbitBookDropModel.deniedMessage))
        #expect(source.queries.isEmpty)

        let refused = BookDropSourceStub()
        refused.pages = [.failure(BookOrbitProvider.BookDockError.accessDenied(nil))]
        let refusedModel = BookOrbitBookDropModel(source: refused)
        await refusedModel.load()
        #expect(refusedModel.state == .denied(BookOrbitBookDropModel.deniedMessage))
    }

    @Test func pagesAppendAndAFailedPageCanBeRetried() async throws {
        let source = BookDropSourceStub()
        source.pages = [
            .success(try Self.page(1...50, total: 70, page: 1)),
            .failure(URLError(.timedOut)),
            .success(try Self.page(51...70, total: 70, page: 2)),
        ]
        let model = BookOrbitBookDropModel(source: source)
        await model.load()
        #expect(model.files.count == 50)
        #expect(model.hasMore)

        await model.loadMore()
        #expect(model.pageError != nil)
        #expect(model.hasMore)
        await model.loadMore()
        #expect(source.queries.count == 2)

        await model.loadMore(retry: true)
        #expect(model.files.count == 70)
        #expect(!model.hasMore)
        #expect(source.queries.map(\.page) == [1, 2, 2])
    }

    @Test func filterAndSearchRestartFromTheFirstPage() async throws {
        let source = BookDropSourceStub()
        source.pages = [.success(try Self.page(1...50, total: 70, page: 1)), .success(try Self.page(51...70, total: 70, page: 2))]
        let model = BookOrbitBookDropModel(source: source)
        await model.load()
        await model.loadMore()

        model.select(.error)
        await model.reloadTask?.value
        model.search = "dune"
        model.searchChanged()
        await model.reloadTask?.value

        #expect(source.queries.suffix(2) == [
            .init(page: 1, limit: 50, status: "error", search: ""),
            .init(page: 1, limit: 50, status: "error", search: "dune"),
        ])
        #expect(model.files.isEmpty)
    }

    @Test func savingMergesEditsIntoTheServerSelectionWithoutDroppingUnknownFields() async throws {
        let source = BookDropSourceStub()
        source.pages = [.success(try Self.page(11...11, total: 1, page: 1))]
        let model = BookOrbitBookDropModel(source: source)
        await model.load()
        var file = try #require(model.files.first)
        file.selectedMetadataJSON = Data(#"{"title":"Title 11","goodreadsId":"gr-11"}"#.utf8)
        var edited = file.metadata
        edited.title = "Renamed"

        let saved = await model.save(file, metadata: edited, target: (libraryId: 3, folderId: 8))

        #expect(saved?.metadata.title == "Renamed")
        let update = try #require(source.updates.first)
        #expect(update.selected?["title"] as? String == "Renamed")
        #expect(update.selected?["goodreadsId"] as? String == "gr-11")
        #expect(update.selected?["authors"] as? [String] == ["File Author"])
        #expect(update.selected?["language"] as? String == "en")
        #expect(update.selected?["publisher"] as? String == "Fixture House")
        // The destination did not change, so it is not re-sent and the server keeps its hold decisions.
        #expect(update.target == nil)
        #expect(model.files.first?.metadata.title == "Renamed")
    }

    @Test func aRefusedSaveKeepsTheStagedFileAndReportsTheError() async throws {
        let source = BookDropSourceStub()
        source.pages = [.success(try Self.page(11...11, total: 1, page: 1))]
        source.updateError = BookOrbitProvider.BookDockError.accessDenied("Not your upload")
        let model = BookOrbitBookDropModel(source: source)
        await model.load()
        let file = try #require(model.files.first)
        var edited = file.metadata
        edited.title = "Renamed"

        let saved = await model.save(file, metadata: edited, target: nil)

        #expect(saved == nil)
        #expect(model.files.first?.metadata.title == "Title 11")
        #expect(model.notice?.isError == true)
        #expect(model.notice?.text.contains("Not your upload") == true)
    }

    @Test func partialApprovalReportsEachFileAndKeepsFailuresSelected() async throws {
        let source = BookDropSourceStub()
        source.pages = [
            .success(try Self.page(11...12, total: 2, page: 1)),
            .success(try Self.page(12...12, total: 1, page: 1)),
        ]
        source.finalizeResults = [.success(.init(total: 2, succeeded: 1, failed: 1, results: [
            .init(fileId: 11, fileName: "upload-11.epub", newName: "A.epub", success: true, bookId: 500,
                  isDuplicate: nil, existingBookId: nil, message: nil, errorCode: nil),
            .init(fileId: 12, fileName: "upload-12.epub", newName: nil, success: false, bookId: nil,
                  isDuplicate: true, existingBookId: 90, message: "Already in Fiction", errorCode: nil),
        ]))]
        let model = BookOrbitBookDropModel(source: source)
        await model.load()
        model.toggleSelecting()
        model.toggleSelected(11)
        model.toggleSelected(12)

        await model.finalize(ids: [11, 12])

        #expect(source.finalized == [[11, 12]])
        #expect(model.finalizeResult?.succeeded == 1)
        #expect(model.finalizeResult?.failed == 1)
        #expect(model.selection == [12])
        #expect(model.files.map(\.id) == [12])
    }

    @Test func approvalIsNeverSentWithoutPermissionOrTwiceWhileInFlight() async throws {
        let unprivileged = BookDropSourceStub()
        unprivileged.access = .init(canUse: true, canFinalize: false, managesAll: false)
        unprivileged.pages = [.success(try Self.page(11...11, total: 1, page: 1))]
        let restricted = BookOrbitBookDropModel(source: unprivileged)
        await restricted.load()
        await restricted.finalize(ids: [11])
        #expect(unprivileged.finalized.isEmpty)

        let source = BookDropSourceStub()
        source.pages = [.success(try Self.page(11...11, total: 1, page: 1))]
        source.finalizeResults = [.success(.init(total: 1, succeeded: 1, failed: 0, results: []))]
        source.holdsFinalize = true
        let model = BookOrbitBookDropModel(source: source)
        await model.load()

        let first = Task { await model.finalize(ids: [11]) }
        while source.finalized.isEmpty { await Task.yield() }
        #expect(model.isBusy([11]))
        await model.finalize(ids: [11])
        await model.discard(ids: [11])
        #expect(source.finalized.count == 1)
        #expect(source.discarded.isEmpty)

        source.release()
        await first.value
        #expect(!model.isBusy([11]))
    }

    @Test func applyFetchedReportsSkippedFilesTruthfully() async throws {
        let source = BookDropSourceStub()
        source.pages = [.success(try Self.page(11...11, total: 1, page: 1))]
        let model = BookOrbitBookDropModel(source: source)
        await model.load()

        await model.applyFetched(ids: [11])

        #expect(model.notice == .init(
            text: "Fetched metadata applied to 0 files. 1 file kept edits made by hand.", isError: true
        ))
    }
    @Test func explicitlyClearedMetadataDoesNotReappearFromLowerLayers() throws {
        let embedded = try JSONDecoder().decode(BookOrbitProvider.BookDockMetadata.self,
            from: Data(#"{"title":"Embedded","publisher":"Old Publisher","authors":["Writer"]}"#.utf8))
        let selected = try JSONDecoder().decode(BookOrbitProvider.BookDockMetadata.self,
            from: Data(#"{"publisher":null,"authors":[],"title":"Chosen"}"#.utf8))
        let merged = embedded.merging(selected)
        #expect(merged.title == "Chosen")
        #expect(merged.publisher == nil)
        #expect(merged.authors == [])
    }

}
