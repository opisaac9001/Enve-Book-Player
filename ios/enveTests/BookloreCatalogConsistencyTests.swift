import Foundation
import Network
import Testing

@testable import enve

nonisolated private final class CatalogConsistencyServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CatalogConsistencyServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var received: [ObjectIdentifier: Data] = [:]
    private var mode: String
    private var requestedPaths: [String] = []
    private var requestedTargets: [String] = []
    private var requestedLines: [String] = []

    var paths: [String] { lock.withLock { requestedPaths } }
    var targets: [String] { lock.withLock { requestedTargets } }
    var requestLines: [String] { lock.withLock { requestedLines } }

    init(mode: String) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func setMode(_ value: String) { lock.withLock { mode = value } }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                lock.withLock { connections.append(connection) }
                connection.start(queue: queue)
                receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            guard let data, error == nil else { return }
            let request = lock.withLock {
                let key = ObjectIdentifier(connection)
                received[key, default: Data()].append(data)
                let value = String(decoding: received[key]!, as: UTF8.self)
                if value.contains("\r\n\r\n") { received.removeValue(forKey: key) }
                return value
            }
            guard request.contains("\r\n\r\n") else {
                if !complete { receive(connection) }
                return
            }
            respond(connection, request: request)
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let requestLine = request.split(separator: " ")
        let method = requestLine.first.map(String.init) ?? "GET"
        let target = requestLine.dropFirst().first.map(String.init) ?? "/"
        guard let url = URL(string: "http://127.0.0.1" + target) else { return }
        let mode = lock.withLock {
            requestedPaths.append(url.path)
            requestedTargets.append(target)
            requestedLines.append("\(method) \(url.path)")
            return self.mode
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = query.first { $0.name == "page" }?.value ?? "0"
        func record(_ id: Int, library: Int = 1, title: String = "Fixture") -> String {
            "{\"id\":\(id),\"libraryId\":\(library),\"metadata\":{\"title\":\"\(title)\"},\"primaryFile\":{\"bookType\":\"EPUB\",\"fileName\":\"\(title).epub\"}}"
        }
        func browsePage(_ content: [String], size: Int, total: Int, pages: Int) -> String {
            "{\"content\":[\(content.joined(separator: ","))],\"page\":{\"number\":\(page),\"size\":\(size),\"totalElements\":\(total),\"totalPages\":\(pages)}}"
        }
        var code = 200
        let payload: String
        if url.path == "/api/v1/books/page" {
            switch mode {
            case "recent":
                payload = browsePage([record(page == "0" ? 42 : 43, title: "Recent")], size: 50, total: 51, pages: 2)
            case "recent-unsupported", "unsupported-empty":
                code = 404
                payload = "{}"
            case "failure", "legacy-only":
                code = 503
                payload = "{}"
            case "conflict":
                payload = browsePage([record(42, library: 2)], size: 100, total: 1, pages: 1)
            case "rejected-delta":
                payload = browsePage([record(42), "{}"], size: 100, total: 2, pages: 1)
            case "empty":
                payload = browsePage([], size: 100, total: 0, pages: 0)
            case "page-failure" where page == "1":
                code = 503
                payload = "{}"
            default:
                payload = browsePage([record(page == "0" ? 42 : 43)], size: 1, total: 2, pages: 2)
            }
        } else if url.path == "/api/v1/libraries/1/book" {
            if mode == "failure" { code = 503 }
            payload = mode == "legacy-only" ? "[\(record(42))]" : "[]"
        } else if url.path == "/api/v1/books/42" {
            payload = record(42).replacingOccurrences(of: "EPUB", with: "MOBI")
                .replacingOccurrences(of: ".epub", with: ".mobi")
        } else if url.path == "/api/v1/notebook" {
            let id = page == "0" ? 1 : 2
            let entry = "{\"id\":\(id),\"type\":\"HIGHLIGHT\",\"bookId\":42,\"bookTitle\":\"Fixture\",\"text\":\"Quote \(id)\",\"note\":null,"
                + "\"color\":\"#FFFF00\",\"style\":\"highlight\",\"chapterTitle\":\"One\",\"primaryBookType\":\"EPUB\","
                + "\"createdAt\":\"2026-11-01T10:00:00\",\"updatedAt\":\"2026-11-01T10:00:00\"}"
            payload = "{\"content\":[\(entry)],\"page\":{\"size\":1,\"number\":\(page),\"totalElements\":2,\"totalPages\":2}}"
        } else if url.path == "/api/v1/books/batch" {
            let ids = (query.first { $0.name == "ids" }?.value ?? "")
                .split(separator: ",").compactMap { Int($0) }
            if mode == "batch-failure" || ids.count > 500 {
                code = 503
                payload = "{}"
            } else {
                payload = "[" + ids.filter { $0 != 3 }
                    .map { record($0, library: 2, title: "Shelf \($0)") }.joined(separator: ",") + "]"
            }
        } else if url.path == "/api/v1/books/status" {
            payload = "[{\"bookId\":42,\"readStatus\":\"READING\"}]"
        } else if url.path == "/api/v1/shelves" {
            payload = "[{\"id\":5,\"name\":\"Favorites\",\"userId\":1,\"publicShelf\":false,\"bookCount\":2}]"
        } else if url.path == "/api/magic-shelves" {
            payload = "[{\"id\":9,\"name\":\"Unread\",\"filterJson\":\"{}\",\"isPublic\":false}]"
        } else if url.path == "/api/v1/books/ids" {
            let facet = query.first { $0.name == "facet" }?.value
            payload = facet == "shelf:5" ? "[42,43]" : facet == "shelf:magic:9" ? "[44]" : "[]"
        } else {
            code = 404
            payload = "{}"
        }
        let body = Data(payload.utf8)
        var data = Data("HTTP/1.1 \(code) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    func stop() {
        listener.cancel()
        listener.newConnectionHandler = nil
        let values = lock.withLock {
            let values = connections
            connections.removeAll()
            return values
        }
        values.forEach { $0.cancel() }
    }
}

@MainActor
@Suite(.serialized)
struct BookloreCatalogConsistencyTests {
    private func fixture(mode: String) async throws -> (BookloreProvider, CatalogConsistencyServer) {
        let server = try CatalogConsistencyServer(mode: mode)
        let port = try await server.start()
        return (BookloreProvider(connection: ServerConnection(
            name: "Fixture", url: "http://127.0.0.1:\(port)", type: .booklore, token: "fixture-token"
        )), server)
    }

    @Test func recentAdditionsUseSmallNewestFirstLibraryPages() async throws {
        let (provider, server) = try await fixture(mode: "recent")
        defer { server.stop() }
        let first = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        let second = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 1, size: 50)
        #expect(first.books.map(\.id) == ["42"])
        #expect(!first.isLast)
        #expect(second.books.map(\.id) == ["43"])
        #expect(second.isLast)
        let requests = server.targets.filter { $0.hasPrefix("/api/v1/books/page?") }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.contains("facet=library:1") && $0.contains("sort=-addedOn") && $0.contains("size=50")
                && !$0.contains("sort=id") && !$0.contains("libraryId=")
        })
        #expect(!server.paths.contains("/api/v1/books/batch"))
        #expect(!server.paths.contains("/api/v1/libraries/1/book"))
        await provider.retire()
    }

    @Test func unsupportedRecentEndpointNeverFallsBackToFullLibrary() async throws {
        let (provider, server) = try await fixture(mode: "recent-unsupported")
        defer { server.stop() }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        }
        #expect(server.paths == ["/api/v1/books/page"])
        #expect(!provider.useLegacyCatalogFallback)
        await provider.retire()
    }

    @Test func emptyRecentPageDoesNotFetchTheLegacyCatalog() async throws {
        let (provider, server) = try await fixture(mode: "empty")
        defer { server.stop() }
        let page = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        #expect(page.books.isEmpty)
        #expect(page.isLast)
        #expect(server.paths == ["/api/v1/books/page"])
        await provider.retire()
    }

    @Test func pageItemsFromAnotherLibraryAreRejected() async throws {
        let (provider, server) = try await fixture(mode: "conflict")
        defer { server.stop() }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        }
        await provider.retire()
    }

    @Test func rejectedDeltaDoesNotAdvanceTheCatalogCursor() async throws {
        let (provider, server) = try await fixture(mode: "rejected-delta")
        defer { server.stop() }
        #expect(try await provider.fetchBooksDelta(libraryId: "1", since: .distantPast) == nil)
        await provider.retire()
    }

    @Test func catalogPagesCarryFormatIdentityWithoutBatchRequests() async throws {
        let (provider, server) = try await fixture(mode: "pages")
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["42", "43"])
        #expect(server.paths.allSatisfy { $0 == "/api/v1/books/page" })
        #expect(server.targets.allSatisfy { $0.contains("size=100") })
        #expect(!provider.useLegacyCatalogFallback)
        await provider.retire()
    }

    @Test(arguments: ["conflict", "failure", "page-failure"])
    func incompleteFallbackCannotBecomeAnAuthoritativeSnapshot(mode: String) async throws {
        let (provider, server) = try await fixture(mode: mode)
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchBooks(libraryId: "1")
        }
        #expect(!provider.useLegacyCatalogFallback)
        #expect(server.paths.contains("/api/v1/libraries/1/book"))
        await provider.retire()
    }

    @Test(arguments: ["empty", "unsupported-empty"])
    func completeEmptyCatalogRemainsAllowed(mode: String) async throws {
        let (provider, server) = try await fixture(mode: mode)
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        #expect(try await provider.fetchBooks(libraryId: "1").isEmpty)
        #expect(try await provider.fetchBooks(libraryId: "1").isEmpty)
        await provider.retire()
    }

    @Test
    func retryRecoversAndRememberedLegacyTierStillChecksEmptyResponses() async throws {
        let (provider, server) = try await fixture(mode: "conflict")
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchBooks(libraryId: "1")
        }
        server.setMode("legacy-only")
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["42"])
        #expect(provider.useLegacyCatalogFallback)
        server.setMode("conflict")
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchBooks(libraryId: "1")
        }
        server.setMode("legacy-only")
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["42"])
        await provider.retire()
    }

    @Test
    func failedImportBatchDoesNotDemoteTheNextRetry() async throws {
        let (provider, server) = try await fixture(mode: "page-failure")
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        let session = try await provider.openCatalogImport(libraryId: "1")
        await #expect(throws: ProviderError.self) {
            _ = try await provider.nextCatalogImportBatch(session)
        }
        #expect(provider.supportsTransactionalCatalogImport)
        server.setMode("pages")
        let batch = try await provider.nextCatalogImportBatch(session)
        #expect(batch?.books.map(\.id) == ["42", "43"])
        #expect(provider.supportsTransactionalCatalogImport)
        #expect(!server.paths.contains("/api/v1/libraries/1/book"))
        await provider.retire()
    }
}

@MainActor
@Suite(.serialized)
struct GrimmoryEndpointContractTests {
    private func fixture() async throws -> (BookloreProvider, CatalogConsistencyServer) {
        let server = try CatalogConsistencyServer(mode: "contract")
        let port = try await server.start()
        return (BookloreProvider(connection: ServerConnection(
            name: "Fixture", url: "http://127.0.0.1:\(port)", type: .booklore, token: "fixture-token"
        )), server)
    }

    private let book = Book(id: "42", title: "Fixture", source: .booklore, mediaType: .ebook, providerId: UUID(), libraryId: "1")

    @Test func nonEpubDetailsDoNotRequestEpubMetadata() async throws {
        let (provider, server) = try await fixture()
        defer { server.stop() }
        let loaded = try await provider.fetchFullBookDetails(bookId: "42", libraryId: "1")
        #expect(loaded.ebookFormat == EbookFormat.mobi.rawValue)
        #expect(server.paths == ["/api/v1/books/42"])
        await provider.retire()
    }

    @Test func notebookEntriesPageThroughTheNotebookEndpointWithExplicitTypes() async throws {
        let (provider, server) = try await fixture()
        defer { server.stop() }
        let entries = try await provider.fetchNotebookEntries(for: book)
        #expect(entries.map(\.id) == [1, 2])
        #expect(entries.allSatisfy { $0.type == .highlight && $0.bookId == 42 })
        let requests = server.targets.filter { $0.hasPrefix("/api/v1/notebook?") }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.contains("bookId=42") && $0.contains("types=HIGHLIGHT") && $0.contains("types=NOTE")
                && $0.contains("types=BOOKMARK")
        })
        #expect(requests.last?.contains("page=1") == true)
        await provider.retire()
    }

    @Test func readStatusUsesTheBulkStatusEndpoint() async throws {
        let (provider, server) = try await fixture()
        defer { server.stop() }
        try await provider.updateReadStatus(for: book, status: .reading)
        #expect(server.requestLines == ["POST /api/v1/books/status"])
        await provider.retire()
    }

    @Test func shelfMembershipUsesBrowseFacets() async throws {
        let (provider, server) = try await fixture()
        defer { server.stop() }
        let collections = try await provider.fetchCollections(libraryId: nil)
        #expect(collections.map(\.id) == ["5", "magic-9"])
        #expect(collections.map(\.books) == [["42", "43"], ["44"]])
        #expect(server.targets.contains("/api/v1/books/ids?facet=shelf:5"))
        #expect(server.targets.contains("/api/v1/books/ids?facet=shelf:magic:9"))
        #expect(!server.paths.contains { $0.hasPrefix("/api/v1/app/") })
        await provider.retire()
    }

    @Test func shelfBooksLoadBeyondTheLocalCatalogInBoundedBatches() async throws {
        let (provider, server) = try await fixture()
        defer { server.stop() }
        let ids = (1...501).reversed().map(String.init)
        let books = try await provider.fetchShelfBooks(ids: ids)
        #expect(books.map(\.id) == ids.filter { $0 != "3" })
        #expect(books.allSatisfy { $0.libraryId == "2" && $0.title == "Shelf \($0.id)" })
        #expect(server.paths == ["/api/v1/books/batch", "/api/v1/books/batch"])
        await provider.retire()
    }

    @Test func shelfBookFailureIsReportedInsteadOfAnEmptyShelf() async throws {
        let (provider, server) = try await fixture()
        defer { server.stop() }
        server.setMode("batch-failure")
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchShelfBooks(ids: ["42"])
        }
        await provider.retire()
    }
}
