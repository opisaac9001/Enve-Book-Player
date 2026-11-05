import Foundation
import Testing

@testable import enve

nonisolated private final class BookOrbitConnectionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let files: [[String: Any]] = [
            ["id": 99, "format": "jpg", "role": "primary"],
            ["id": 98, "format": "mp3", "role": "supplementary"],
            ["id": 10, "format": "EPUB", "role": "content",
             "mediaOverlay": ["available": true, "durationSeconds": 120]]
        ]
        let narrated: [String: Any] = ["id": 1, "title": "Narrated", "files": files]
        let mixed: [String: Any] = ["id": 2, "title": "Mixed", "files": [
            ["id": 20, "format": "m4b", "role": "primary"],
            ["id": 21, "format": "epub", "role": "content"]
        ]]
        let plain: [String: Any] = ["id": 3, "title": "Plain", "files": [
            ["id": 30, "format": "pdf", "role": "primary"],
            ["id": 31, "format": "epub", "role": "content", "mediaOverlay": ["available": true]]
        ]]
        func collection(_ id: Int, owner: Bool) -> [String: Any] {
            ["id": id, "name": "Enve Favorites", "displayOrder": 0, "bookCount": 0, "syncToKobo": false, "isOwner": owner]
        }
        var status = 200
        let payload: Any
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/api/v1/auth/me"):
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale-fixture" { status = 401 }
            payload = ["id": 1, "username": "reader", "isSuperuser": false]
        case ("POST", "/api/v1/auth/refresh"):
            guard request.value(forHTTPHeaderField: "Cookie") == "CF_Authorization=access-fixture; refresh_token=refresh-fixture" else {
                client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                return
            }
            payload = ["accessToken": "refreshed-fixture"]
        case ("GET", "/api/v1/collections"):
            payload = [collection(90, owner: false), collection(91, owner: true)]
        case ("POST", "/api/v1/collections"):
            status = 201
            payload = collection(92, owner: true)
        case ("PATCH", "/api/v1/collections/90"):
            status = 403
            payload = ["message": "Forbidden"]
        case ("POST", "/api/v1/collections/91/books"):
            payload = [:] as [String: String]
        case ("POST", "/api/v1/libraries/1/books"):
            let body = bodyJSON()
            if body["sort"] != nil {
                let sort = body["sort"] as? [[String: String]]
                let pagination = body["pagination"] as? [String: Int]
                guard (sort == [["field": "addedAt", "dir": "desc"]] || sort == [["field": "addedAt", "dir": "asc"]]), pagination?["page"] == 0 else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
            }
            payload = ["items": [narrated, mixed, plain], "total": (body["sort"] as? [[String: String]])?.first?["dir"] == "asc" ? 3 : 203, "page": 0, "size": 200]
        case ("GET", "/api/v1/books/1"): payload = narrated
        case ("GET", "/api/v1/books/2"): payload = mixed
        case ("GET", "/api/v1/books/3"): payload = plain
        case (_, "/api/v1/books/files/21/progress"):
            payload = ["percentage": 42]
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func bodyJSON() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    override func stopLoading() {}
}

@MainActor
struct BookOrbitConnectionContractTests {
    private func provider() -> (BookOrbitProvider, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitConnectionProtocol.self]
        let session = URLSession(configuration: configuration)
        return (BookOrbitProvider(connection: ServerConnection(
            name: "Fixture", url: "https://bookorbit.invalid", type: .bookOrbit, token: "fixture-token"
        ), session: session), session)
    }

    @Test func contentRolesAndSelectedOverlayMatchCardsAndDetails() async throws {
        let (provider, session) = provider()
        defer { session.invalidateAndCancel() }
        let cards = try await provider.fetchRecentBooks(libraryId: "1", limit: 3)
        #expect(cards.map(\.id) == ["1", "2", "3"])
        for card in cards {
            let detail = try await provider.fetchFullBookDetails(bookId: card.id, libraryId: "1")
            for book in [card, detail] {
                switch book.id {
                case "1":
                    #expect(book.mediaType == .ebook)
                    #expect(book.audioFileIno == "10")
                    #expect(book.ebookFormat == "epub")
                    #expect(book.epub3Features?.hasMediaOverlay == true)
                case "2":
                    #expect(book.mediaType == .audiobook)
                    #expect(book.audioFileIno == "20")
                    #expect(book.hasAlternateFormat)
                    #expect(book.ebookFormat == "epub")
                    #expect(book.epub3Features?.hasMediaOverlay != true)
                default:
                    #expect(book.ebookFormat == "pdf")
                    #expect(book.epub3Features?.hasMediaOverlay != true)
                }
            }
        }
    }

    @Test func catalogImportsUseStableAddedDateOrder() async throws {
        let (provider, session) = provider()
        defer { session.invalidateAndCancel() }
        #expect(try await provider.fetchBooks(libraryId: "1").map(\.id) == ["1", "2", "3"])
    }

    @Test func mixedBookReadingProgressUsesEbookFile() async throws {
        let (provider, session) = provider()
        defer { session.invalidateAndCancel() }
        let book = try await provider.fetchFullBookDetails(bookId: "2", libraryId: "1")
        #expect(try await provider.fetchEbookProgress(for: book)?.progress == 0.42)
        try await provider.updateEbookProgress(for: book, progress: 0.42, epubLocator: nil)
    }

    @Test func personalCollectionsDoNotRequireAdministratorAndRespectOwnership() async throws {
        let (provider, session) = provider()
        defer { session.invalidateAndCancel() }
        #expect(try await provider.canSyncSavedBooks())
        let collections = try await provider.fetchCollections(libraryId: nil)
        #expect(collections.first { $0.remoteId == "90" }?.isServerEditable == false)
        #expect(collections.first { $0.remoteId == "91" }?.isServerEditable == true)
        let edit = BookOrbitProvider.CollectionEdit(name: "Fixture", description: nil, icon: "folder", syncToKobo: false)
        #expect(try await provider.createCollection(edit).isServerEditable)
        await #expect(throws: (any Error).self) { try await provider.updateCollection(id: "90", edit: edit) }
        let book = try await provider.fetchFullBookDetails(bookId: "2", libraryId: "1")
        try await provider.setSavedBook(book, list: .favorites, saved: true)
    }

    @Test func ssoRefreshPreservesTheAccessCookieWhenRetryingUnauthorizedRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitConnectionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connection = ServerConnection(name: "Fixture", url: "https://bookorbit.invalid", type: .bookOrbit,
            token: "stale-fixture", customHeaders: ["Cookie": "refresh_token=outdated; CF_Authorization=access-fixture"], authMode: .sso)
        let key = "bookorbit_refresh_" + connection.id.uuidString
        KeychainHelper.shared.set("refresh-fixture", key: key)
        defer { KeychainHelper.shared.delete(key) }
        let provider = BookOrbitProvider(connection: connection, session: session)

        #expect(try await provider.validateConnection())
        #expect(provider.connection.token == "refreshed-fixture")
    }
}
