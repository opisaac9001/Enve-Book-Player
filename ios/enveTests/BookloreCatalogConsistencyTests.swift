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

    var paths: [String] { lock.withLock { requestedPaths } }
    var targets: [String] { lock.withLock { requestedTargets } }

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
        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        guard let url = URL(string: "http://127.0.0.1" + target) else { return }
        let mode = lock.withLock {
            requestedPaths.append(url.path)
            requestedTargets.append(target)
            return self.mode
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = query.first { $0.name == "page" }?.value ?? "0"
        var code = 200
        let payload: String
        if mode == "recent-unsupported", url.path == "/api/v1/app/books" {
            code = 404
            payload = "{}"
        } else if mode == "recent", url.path == "/api/v1/app/books" {
            let id = page == "0" ? 42 : 43
            payload = "{\"content\":[{\"id\":\(id),\"title\":\"Recent\",\"primaryFileType\":\"EPUB\"}],\"page\":\(page),\"size\":50,\"totalElements\":51,\"totalPages\":2,\"hasNext\":\(page == "0"),\"hasPrevious\":\(page != "0")}"
        } else if mode == "recent", url.path == "/api/v1/books/batch" {
            let id = query.first { $0.name == "ids" }?.value ?? "42"
            payload = "[{\"id\":\(id),\"metadata\":{\"title\":\"Recent\"},\"primaryFile\":{\"bookType\":\"EPUB\",\"fileName\":\"recent.epub\"}}]"
        } else if mode == "recent-legacy", url.path == "/api/v1/libraries/1/book/42" {
            payload = "{\"id\":42,\"metadata\":{\"title\":\"Recent\"},\"primaryFile\":{\"bookType\":\"EPUB\",\"fileName\":\"recent.epub\"}}"
        } else if url.path == "/api/v1/app/books" {
            if mode == "unsupported-empty" { code = 404 }
            if mode == "page-failure" && page == "1" { code = 503 }
            let content = mode == "empty" ? "[]" : mode == "partial" ?
                "[{\"id\":42,\"title\":\"Fixture\",\"primaryFileType\":\"EPUB\"},{\"id\":43,\"title\":\"Second\",\"primaryFileType\":\"EPUB\"}]" :
                "[{\"id\":42,\"title\":\"Fixture\",\"primaryFileType\":\"EPUB\"}]"
            let pages = mode == "page-failure" ? 2 : 1
            let count = mode == "empty" ? 0 : mode == "partial" || mode == "page-failure" ? 2 : 1
            payload = "{\"content\":\(content),\"page\":0,\"size\":500,\"totalElements\":\(count),\"totalPages\":\(pages),\"hasNext\":\(pages > 1),\"hasPrevious\":false}"
        } else if url.path == "/api/v1/books/batch" {
            code = 404
            payload = "{}"
        } else if url.path == "/api/v1/libraries/1/book" {
            if mode == "failure" { code = 503 }
            payload = mode == "healthy" || mode == "partial" ?
                "[{\"id\":42,\"metadata\":{\"title\":\"Fixture\"},\"primaryFile\":{\"bookType\":\"EPUB\",\"fileName\":\"fixture.epub\"}}]" : "[]"
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

    @Test func recentAdditionsUseSmallNewestFirstPagesAndBatchFormats() async throws {
        let (provider, server) = try await fixture(mode: "recent")
        defer { server.stop() }
        let first = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        let second = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 1, size: 50)
        #expect(first.books.map(\.id) == ["42"])
        #expect(!first.isLast)
        #expect(second.books.map(\.id) == ["43"])
        #expect(second.isLast)
        let requests = server.targets.filter { $0.hasPrefix("/api/v1/app/books?") }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.contains("size=50") && $0.contains("sort=addedOn") && $0.contains("dir=desc") })
        #expect(!server.paths.contains("/api/v1/libraries/1/book"))
        await provider.retire()
    }

    @Test func unsupportedRecentEndpointNeverFallsBackToFullLibrary() async throws {
        let (provider, server) = try await fixture(mode: "recent-unsupported")
        defer { server.stop() }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        }
        #expect(server.paths == ["/api/v1/app/books"])
        #expect(!provider.useLegacyCatalogFallback)
        await provider.retire()
    }

    @Test func emptyRecentPageDoesNotFetchTheLegacyCatalog() async throws {
        let (provider, server) = try await fixture(mode: "empty")
        defer { server.stop() }
        let page = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        #expect(page.books.isEmpty)
        #expect(page.isLast)
        #expect(server.paths == ["/api/v1/app/books"])
        await provider.retire()
    }

    @Test func recentFormatsUseIndividualRecordsWhenBatchIsUnavailable() async throws {
        let (provider, server) = try await fixture(mode: "recent-legacy")
        defer { server.stop() }
        let page = try await provider.fetchRecentCatalogPage(libraryId: "1", page: 0, size: 50)
        #expect(page.books.map(\.id) == ["42"])
        #expect(server.paths.contains("/api/v1/libraries/1/book/42"))
        #expect(!server.paths.contains("/api/v1/libraries/1/book"))
        await provider.retire()
    }

    @Test(arguments: ["conflict", "partial", "failure", "page-failure"])
    func incompleteFallbackCannotBecomeAnAuthoritativeSnapshot(mode: String) async throws {
        let (provider, server) = try await fixture(mode: mode)
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchBooks(libraryId: "1")
        }
        #expect(!provider.useLegacyCatalogFallback)
        #expect(server.paths.contains("/api/v1/libraries/1/book"))
        #expect(mode == "page-failure" || server.paths.contains("/api/v1/books/batch"))
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
        server.setMode("healthy")
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["42"])
        #expect(provider.useLegacyCatalogFallback)
        server.setMode("conflict")
        await #expect(throws: ProviderError.self) {
            _ = try await provider.fetchBooks(libraryId: "1")
        }
        server.setMode("healthy")
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["42"])
        await provider.retire()
    }

    @Test
    func failedTransactionalFallbackDoesNotDemoteTheNextRetry() async throws {
        let (provider, server) = try await fixture(mode: "conflict")
        defer { server.stop(); provider.completeCatalogSync(libraryId: "1") }
        let session = try await provider.openCatalogImport(libraryId: "1")
        await #expect(throws: ProviderError.self) {
            _ = try await provider.nextCatalogImportBatch(session)
        }
        #expect(provider.supportsTransactionalCatalogImport)
        server.setMode("healthy")
        await #expect(throws: ProviderError.self) {
            _ = try await provider.nextCatalogImportBatch(session)
        }
        #expect(!provider.supportsTransactionalCatalogImport)
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["42"])
        await provider.retire()
    }
}
