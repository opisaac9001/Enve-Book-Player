import Foundation
import Testing

@testable import enve

nonisolated private final class SiloV2Fixture: URLProtocol, @unchecked Sendable {
    nonisolated struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: [String: Any]

        var path: String { url.path }

        func query(_ name: String) -> [String] {
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .filter { $0.name == name }
                .compactMap(\.value)
        }
    }

    // Status 0 fails the request as a lost connection.
    typealias Responder = @Sendable (_ request: Recorded, _ history: [Recorded]) -> (status: Int, payload: Any?)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var responder: Responder = { _, _ in (404, nil) }

    static func install(_ handler: @escaping Responder) {
        lock.lock()
        recorded = []
        responder = handler
        lock.unlock()
    }

    static func requests() -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bodyData.append(contentsOf: buffer.prefix(count))
            }
        }
        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        )
        Self.lock.lock()
        let history = Self.recorded
        Self.recorded.append(entry)
        let responder = Self.responder
        Self.lock.unlock()

        let (status, payload) = responder(entry, history)
        guard status != 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var headers = ["Content-Type": status >= 400 ? "application/problem+json" : "application/json"]
        if let object = payload as? [String: Any], let etag = object["etag"] as? String {
            headers["ETag"] = etag
        }
        if let object = payload as? [String: Any], let retryAfter = object["retry_after"] as? Int {
            headers["Retry-After"] = String(retryAfter)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = payload as? Data {
            client?.urlProtocol(self, didLoad: data)
        } else if let payload, let data = try? JSONSerialization.data(withJSONObject: payload) {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated private func problem(_ id: String, _ status: Int) -> [String: Any] {
    [
        "type": "https://siloserver.org/docs/api/v2/problems/\(id)",
        "title": id, "status": status, "detail": "Fixture problem.", "instance": "urn:silo:request:fixture",
    ]
}

nonisolated private func page(_ items: [[String: Any]], next: String?, extra: [String: Any] = [:]) -> [String: Any] {
    var info: [String: Any] = ["has_more": next != nil]
    if let next { info["next_cursor"] = next }
    return extra.merging(["items": items, "page": info]) { $1 }
}

nonisolated private func card(_ id: String, _ type: String) -> [String: Any] {
    ["content_id": id, "type": type, "title": id, "genres": [], "keywords": [], "status": "matched"]
}

nonisolated private func detail(_ id: String, _ type: String, container: String) -> [String: Any] {
    card(id, type).merging([
        "cast": [], "crew": [], "ratings": [], "subtitles": [],
        "versions": [["file_id": "120", "file_name": "\(id).\(container)", "container": container, "duration": 600,
                      "file_size": 2048, "bitrate": 64, "added_at": "2026-01-01T00:00:00.000Z",
                      "resolution": "", "codec_video": "", "codec_audio": "", "hdr": false]],
    ]) { $1 }
}

nonisolated private func annotation(_ id: String, text: String, etag: String, updatedAt: String = "2026-01-05T00:00:00.000Z") -> [String: Any] {
    [
        "id": id, "content_id": "ebook:b", "kind": "highlight", "cfi_range": "epubcfi(/6/4!/4/2)",
        "location": "epubcfi(/6/4!/4/2)", "selected_text": text, "note": "", "style": "highlight", "color": "#facc15",
        "metadata": [:], "created_at": "2026-01-04T00:00:00.000Z", "updated_at": updatedAt, "etag": etag,
    ]
}

private final class SingleProviderResolver: LibraryProviderResolving {
    let provider: LibraryProvider
    init(_ provider: LibraryProvider) { self.provider = provider }
    func provider(for providerId: UUID) -> LibraryProvider? { provider }
    func provider(for book: Book) -> LibraryProvider? { provider }
}

@MainActor
@Suite(.serialized)
struct SiloV2ContractTests {
    private struct Harness {
        let provider: SiloProvider
        let cleanup: () -> Void
    }

    private func makeHarness(token: String? = "access-1", username: String? = nil, password: String? = nil, profile: String? = "p-main") -> Harness {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloV2Fixture.self]
        let session = URLSession(configuration: config)
        let connection = ServerConnection(name: "Fixture", url: "https://silo.invalid", type: .silo,
                                          username: username, password: password, token: token, userId: token == nil ? nil : "7")
        let key = connection.id.uuidString
        if let profile {
            UserDefaults.standard.set(profile, forKey: "silo_profile_id_\(key)")
            UserDefaults.standard.set("7", forKey: "silo_profile_user_id_\(key)")
        }
        return Harness(provider: SiloProvider(connection: connection, session: session)) {
            for suffix in ["id", "name", "user_id"] {
                UserDefaults.standard.removeObject(forKey: "silo_profile_\(suffix)_\(key)")
            }
            KeychainHelper.shared.delete("silo_refresh_\(key)")
            KeychainHelper.shared.delete("silo_profile_token_\(key)")
            session.invalidateAndCancel()
        }
    }

    @Test func remoteCardsRetainAvailableMetadataAndServerProgressWithoutDetails() async throws {
        SiloV2Fixture.install { request, _ in
            guard request.path == "/api/v2/catalog" else { return (500, nil) }
            return (200, page([
                card("ebook:card", "ebook").merging([
                    "title": "Summary", "added_at": "2026-11-01T12:00:00.000Z",
                    "user_state": ["played": true, "is_favorite": false, "in_watchlist": false],
                    "sort_metrics": ["author": "Author", "narrator": "Narrator", "series_name": "Series", "progress_ratio": 0.75],
                ]) { $1 },
            ], next: nil))
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let result = try await harness.provider.fetchRemoteCatalogPage(libraryId: "3",
            request: RemoteCatalogRequest(search: nil, mediaType: .ebook, sort: .title), cursor: nil, limit: 50)
        let book = try #require(result.books.first)
        #expect(book.author == "Author" && book.narrator == "Narrator" && book.series == "Series")
        #expect(book.ebookProgress == 0.75 && book.isFinished)
        #expect(book.addedAt == ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        #expect(SiloV2Fixture.requests().count == 1)
    }

    @Test func aMalformedRemoteCardCannotMasqueradeAsAnEmptyCatalog() async throws {
        SiloV2Fixture.install { _, _ in
            (200, page([["content_id": "ebook:broken", "type": "ebook"]], next: nil))
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        await #expect(throws: (any Error).self) {
            _ = try await harness.provider.fetchRemoteCatalogPage(libraryId: "3",
                request: RemoteCatalogRequest(search: nil, mediaType: .ebook, sort: .title), cursor: nil, limit: 50)
        }
    }

    nonisolated private static func queryRules(_ request: SiloV2Fixture.Recorded) -> [[String]] {
        (request.body["groups"] as? [[String: Any]] ?? []).map { group in
            (group["rules"] as? [[String: Any]] ?? []).map {
                "\($0["field"] as? String ?? ""):\($0["op"] as? String ?? ""):\($0["value"] as? String ?? "")"
            }
        }
    }

    @Test func filteredCatalogPostsOrWithinGroupsAndAcrossGroupsWithoutDetails() async throws {
        SiloV2Fixture.install { request, _ in
            guard request.method == "POST", request.path == "/api/v2/catalog/query" else { return (500, nil) }
            return (200, page([
                card("audiobook:fr", "audiobook").merging(["original_language": "fr", "genres": ["Fantasy"]]) { $1 },
            ], next: "q2"))
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let result = try await harness.provider.fetchRemoteCatalogPage(
            libraryId: "3",
            request: RemoteCatalogRequest(search: "dune", mediaType: .audiobook, sort: .recentlyAdded,
                                          genres: ["Sci-Fi", "Fantasy"], languages: ["fr", "en"]),
            cursor: "q1",
            limit: 500
        )
        #expect(result.books.map(\.id) == ["audiobook:fr"])
        #expect(result.books.first?.language == "fr")
        #expect(result.nextCursor == "q2")

        let requests = SiloV2Fixture.requests()
        #expect(requests.count == 1)
        let query = try #require(requests.first)
        #expect(query.url.query == nil)
        #expect(query.headers["X-Profile-Id"] == "p-main" && query.headers["Authorization"] == "Bearer access-1")
        let body = query.body
        #expect(body["source"] as? String == "query")
        #expect(body["library_id"] as? String == "3")
        #expect(body["type"] as? String == "audiobook")
        #expect(body["q"] as? String == "dune")
        #expect(body["sort"] as? String == "added_at" && body["order"] as? String == "desc")
        #expect(body["limit"] as? Int == 100)
        #expect(body["skip_total"] as? Bool == true)
        #expect(body["cursor"] as? String == "q1")
        #expect(body["match"] as? String == "all")
        #expect((body["groups"] as? [[String: Any]])?.map { $0["match"] as? String } == ["any", "any"])
        #expect(Self.queryRules(query) == [
            ["genre:is:Fantasy", "genre:is:Sci-Fi"],
            ["original_language:is:en", "original_language:is:fr"],
        ])
    }

    @Test func singleGroupFilterIsStableAndUnfilteredBrowseStaysAGet() async throws {
        SiloV2Fixture.install { request, _ in
            switch (request.method, request.path) {
            case ("POST", "/api/v2/catalog/query"), ("GET", "/api/v2/catalog"):
                return (200, page([card("ebook:a", "ebook")], next: nil))
            default:
                return (500, nil)
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        var languages: Set<String> = []
        for language in ["ja", "de", "pt-BR"] { languages.insert(language) }
        for request in [
            RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title, languages: ["pt-BR", "ja", "de"]),
            RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title, languages: languages),
            RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title),
        ] {
            _ = try await harness.provider.fetchRemoteCatalogPage(libraryId: "3", request: request, cursor: nil, limit: 0)
        }

        let requests = SiloV2Fixture.requests()
        #expect(requests.map(\.method) == ["POST", "POST", "GET"])
        let posts = requests.prefix(2)
        #expect(posts.allSatisfy {
            $0.body["sort"] as? String == "title" && $0.body["order"] as? String == "asc"
                && $0.body["limit"] as? Int == 1 && $0.body["type"] == nil && $0.body["q"] == nil
                && $0.body["cursor"] == nil
        })
        #expect(posts.map(Self.queryRules) == Array(repeating: [[
            "original_language:is:de", "original_language:is:ja", "original_language:is:pt-BR",
        ]], count: 2))

        let browse = requests[2]
        #expect(browse.path == "/api/v2/catalog" && browse.body.isEmpty)
        #expect(browse.query("sort") == ["title"] && browse.query("limit") == ["1"] && browse.query("skip_total") == ["true"])
    }

    @Test func filterOptionsSearchFacetValuesAfterCachingTheCapability() async throws {
        SiloV2Fixture.install { request, _ in
            switch request.path {
            case "/api/v2/catalog/search/capabilities":
                return (200, ["facet_value_search": true])
            case "/api/v2/catalog/filters/search":
                switch request.query("facet").first {
                case "genre":
                    return (200, ["values": [["value": "Fantasy", "count": 3], ["value": "Science Fiction", "count": 1]],
                                  "values_has_more": false])
                case "original_language":
                    return (200, ["values": [["value": "en", "count": 4]], "values_has_more": true])
                default:
                    return (400, problem("invalid_facet", 400))
                }
            default:
                return (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let options = try await harness.provider.fetchRemoteCatalogFilterOptions(libraryId: "3", mediaType: .ebook, search: "sci")
        _ = try await harness.provider.fetchRemoteCatalogFilterOptions(libraryId: "3", mediaType: nil, search: "")

        #expect(options.genres == ["Fantasy", "Science Fiction"])
        #expect(options.languages == ["en"])
        #expect(options.hasMore)
        let requests = SiloV2Fixture.requests()
        #expect(requests.filter { $0.path == "/api/v2/catalog/search/capabilities" }.count == 1)
        #expect(!requests.contains { $0.path == "/api/v2/catalog/filters" })
        let searches = requests.filter { $0.path == "/api/v2/catalog/filters/search" }
        #expect(searches.count == 4)
        #expect(Set(searches.prefix(2).compactMap { $0.query("facet").first }) == ["genre", "original_language"])
        #expect(searches.prefix(2).allSatisfy {
            $0.method == "GET" && $0.query("library_id") == ["3"] && $0.query("type") == ["ebook"]
                && $0.query("q") == ["sci"] && $0.query("limit") == ["24"]
        })
        #expect(searches.suffix(2).allSatisfy { $0.query("type").isEmpty && $0.query("q").isEmpty })
    }

    @Test func filterOptionsRequireFacetValueSearchSupport() async throws {
        SiloV2Fixture.install { request, _ in
            guard request.path == "/api/v2/catalog/search/capabilities" else { return (500, nil) }
            return (200, ["facet_value_search": false])
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        for _ in 0..<2 {
            do {
                _ = try await harness.provider.fetchRemoteCatalogFilterOptions(libraryId: "3", mediaType: nil, search: "")
                Issue.record("An unsupported server returned filter options")
            } catch {
                #expect(error.localizedDescription.contains("Update"))
            }
        }
        let requests = SiloV2Fixture.requests()
        #expect(requests.map(\.path) == ["/api/v2/catalog/search/capabilities"])
    }

    @Test func detailMapsOriginalLanguageForOfflineFilters() async throws {
        SiloV2Fixture.install { request, _ in
            (200, detail(request.url.lastPathComponent, "ebook", container: "epub").merging(["original_language": "de"]) { $1 })
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let book = try await harness.provider.fetchFullBookDetails(bookId: "ebook:de", libraryId: "3")
        #expect(book.language == "de")
        #expect(RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title, languages: ["de"]).matchesAdvancedFilters(book))
    }

    nonisolated private static func catalogResponse(_ request: SiloV2Fixture.Recorded) -> (status: Int, payload: Any?)? {
        switch request.path {
        case "/api/v2/catalog/items/audiobook:a": return (200, detail("audiobook:a", "audiobook", container: "m4b"))
        case "/api/v2/catalog/items/ebook:b": return (200, detail("ebook:b", "ebook", container: "epub"))
        case "/api/v2/catalog":
            guard request.query("source").isEmpty else { return nil }
            let skipTotal = request.query("skip_total") == ["true"]
            let total: [String: Any] = ["total": skipTotal ? 0 : 3, "total_exact": !skipTotal, "window_cursor": "w"]
            switch request.query("cursor").first {
            case nil: return (200, page([card("audiobook:a", "audiobook")], next: "c1", extra: total))
            case "c1": return (200, page([], next: "c2", extra: total))
            case "c2": return (200, page([card("ebook:b", "ebook"), card("movie:x", "movie")], next: nil, extra: total))
            default: return (400, problem("invalid_cursor", 400))
            }
        default: return nil
        }
    }

    @Test func lockedProfileSelectionStoresProofAndNeverRebindsAnExistingConnection() async throws {
        SiloV2Fixture.install { request, _ in
            if request.path == "/api/v2/profiles/p-locked/verify-pin" {
                #expect(request.headers["X-Profile-Id"] == nil)
                #expect(request.body["pin"] as? String == "1234")
                return (200, ["valid": true, "profile_token": "proof-1", "expires_at": "2026-11-12T10:00:00.000Z"])
            }
            return (404, nil)
        }
        let harness = makeHarness(profile: nil)
        defer { harness.cleanup() }
        let profile = SiloProfile(id: "p-locked", name: "Locked", isPrimary: false, hasPIN: true)
        try await harness.provider.selectLoginProfile(profile, pin: "1234")
        #expect(try await harness.provider.ensureProfile() == "p-locked")
        let request = try harness.provider.makeRequest(path: "/catalog")
        #expect(request.value(forHTTPHeaderField: "X-Profile-Token") == "proof-1")
        #expect(request.value(forHTTPHeaderField: "X-Profile-Id") == "p-locked")
        await #expect(throws: (any Error).self) {
            try await harness.provider.selectLoginProfile(SiloProfile(id: "other", name: "Other", isPrimary: true, hasPIN: false), pin: nil)
        }
        #expect(try await harness.provider.ensureProfile() == "p-locked")
    }

    @Test func incorrectPINDoesNotPersistAProfileOrProof() async throws {
        SiloV2Fixture.install { _, _ in (200, ["valid": false, "expires_at": NSNull()]) }
        let harness = makeHarness(profile: nil)
        defer { harness.cleanup() }
        await #expect(throws: (any Error).self) {
            try await harness.provider.selectLoginProfile(SiloProfile(id: "locked", name: "Locked", isPrimary: true, hasPIN: true), pin: "0000")
        }
        let request = try harness.provider.makeRequest(path: "/catalog")
        #expect(request.value(forHTTPHeaderField: "X-Profile-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Profile-Token") == nil)
    }

    @Test func passwordLoginSelectsPrimaryProfileAndCatalogFollowsEveryCursor() async throws {
        SiloV2Fixture.install { request, _ in
            switch request.path {
            case "/api/v2/auth/login":
                return (200, ["access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600,
                              "user": ["id": "7", "username": "reader", "email": "", "role": "user", "permissions": [],
                                       "download_allowed": true, "password_change_required": false]])
            case "/api/v2/user/libraries":
                return (200, ["items": [
                    ["id": "3", "name": "Books", "type": "audiobooks", "sort_order": 0, "box_sets_enabled": false],
                    ["id": "4", "name": "Films", "type": "movies", "sort_order": 1, "box_sets_enabled": false],
                ]])
            case "/api/v2/profiles":
                return (200, ["items": [["id": "p-kid", "name": "Kid", "is_primary": false],
                                        ["id": "p-main", "name": "Reader", "is_primary": true]],
                              "avatar_upload_enabled": false, "max_advisory_age_supported": true,
                              "require_advisory_age_supported": true])
            default:
                return Self.catalogResponse(request) ?? (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness(token: nil, username: "reader", password: "secret", profile: nil)
        defer { harness.cleanup() }
        let provider = harness.provider

        let libraries = try await provider.fetchLibraries()
        #expect(libraries.map(\.id) == ["3"])
        let source = try await provider.makeCatalogBatchSource(libraryId: "3", resumeAfter: nil, expectedSnapshotIdentifier: nil)
        var batches: [LibraryCatalogBatch] = []
        while let batch = try await source.next() { batches.append(batch) }

        #expect(provider.connection.userId == "7")
        #expect(try await provider.ensureProfile() == "p-main")
        #expect(batches.flatMap(\.books).map(\.id) == ["audiobook:a", "ebook:b"])
        #expect(batches.map(\.resumeToken) == ["c1", "c2", ""])
        #expect(batches.map(\.completesSnapshot) == [false, false, true])
        #expect(batches.map(\.totalCount) == [3, 3, 3])
        #expect(batches.flatMap(\.books).first?.partKey == "120")

        let login = try #require(SiloV2Fixture.requests().first { $0.path == "/api/v2/auth/login" })
        #expect(login.body["username"] as? String == "reader")
        let catalog = SiloV2Fixture.requests().filter { $0.path == "/api/v2/catalog" }
        #expect(catalog.map { $0.query("cursor").first } == [nil, "c1", "c2"])
        #expect(catalog.map { $0.query("skip_total").first } == [nil, "true", "true"])
        #expect(catalog.allSatisfy {
            $0.query("sort") == ["title"] && $0.query("limit") == ["200"] && $0.query("library_id") == ["3"]
                && $0.query("type").isEmpty && $0.query("offset").isEmpty
                && $0.headers["X-Profile-Id"] == "p-main" && $0.headers["Authorization"] == "Bearer access-1"
        })
    }

    @Test func storedCatalogCursorResumesOnlyWhileTheServerAcceptsIt() async throws {
        SiloV2Fixture.install { request, _ in Self.catalogResponse(request) ?? (404, problem("not_found", 404)) }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let provider = harness.provider

        let fresh = try await provider.makeCatalogBatchSource(libraryId: "3", resumeAfter: nil, expectedSnapshotIdentifier: nil)
        let resumed = try await provider.makeCatalogBatchSource(
            libraryId: "3", resumeAfter: "c2", expectedSnapshotIdentifier: fresh.snapshotIdentifier
        )
        #expect(resumed.resumed)
        #expect(try await resumed.next()?.books.map(\.id) == ["ebook:b"])

        let rejected = try await provider.makeCatalogBatchSource(
            libraryId: "3", resumeAfter: "expired", expectedSnapshotIdentifier: fresh.snapshotIdentifier
        )
        #expect(!rejected.resumed)
        #expect(try await rejected.next()?.books.map(\.id) == ["audiobook:a"])
    }

    @Test func posterURLsPreserveSignedQueriesAndEscapedPaths() async throws {
        let posters = [
            ("/api/v2/artwork/local/books/a%20b/w500.rev.webp?exp=123&sig=a%2Bb%2Fc",
             "https://silo.invalid/api/v2/artwork/local/books/a%20b/w500.rev.webp?exp=123&sig=a%2Bb%2Fc"),
            ("artwork/cover.webp?exp=123&sig=abc", "https://silo.invalid/artwork/cover.webp?exp=123&sig=abc"),
            ("https://cdn.invalid/cover.webp?signature=a%2Fb", "https://cdn.invalid/cover.webp?signature=a%2Fb"),
        ]
        for (poster, expected) in posters {
            SiloV2Fixture.install { _, _ in
                var response = detail("ebook:cover", "ebook", container: "epub")
                response["poster_url"] = poster
                return (200, response)
            }
            let harness = makeHarness()
            defer { harness.cleanup() }
            let book = try await harness.provider.fetchFullBookDetails(bookId: "ebook:cover", libraryId: "1")
            #expect(book.coverURL?.absoluteString == expected)
        }
    }

    @Test func catalogImportEvictsOldDetailsAndKeepsTheLatestPageCached() async throws {
        SiloV2Fixture.install { request, _ in
            if request.path == "/api/v2/catalog" {
                let start = Int(request.query("cursor").first ?? "0") ?? 0
                let end = min(start + (Int(request.query("limit").first ?? "0") ?? 0), 300)
                let items = (start..<end).map { card("audiobook:\($0)", "audiobook") }
                return (200, page(items, next: end < 300 ? String(end) : nil,
                                  extra: ["total": 300, "total_exact": true, "window_cursor": "w"]))
            }
            if request.path.hasPrefix("/api/v2/catalog/items/") {
                return (200, detail(request.url.lastPathComponent, "audiobook", container: "m4b"))
            }
            return (404, nil)
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let source = try await harness.provider.makeCatalogBatchSource(
            libraryId: "3", resumeAfter: nil, expectedSnapshotIdentifier: nil
        )
        var imported = 0
        while let batch = try await source.next() { imported += batch.books.count }
        #expect(imported == 300)

        for index in 200..<300 {
            let book = try await harness.provider.fetchFullBookDetails(bookId: "audiobook:\(index)", libraryId: "3")
            #expect(book.id == "audiobook:\(index)")
        }
        #expect(SiloV2Fixture.requests().filter { $0.path.hasPrefix("/api/v2/catalog/items/") }.count == 300)

        for _ in 0..<2 {
            let book = try await harness.provider.fetchFullBookDetails(bookId: "audiobook:0", libraryId: "3")
            #expect(book.id == "audiobook:0")
        }
        #expect(SiloV2Fixture.requests().filter { $0.path == "/api/v2/catalog/items/audiobook:0" }.count == 2)
    }

    @Test func concurrentCatalogMappingPreservesOrderMetadataAndRejectedItems() async throws {
        SiloV2Fixture.install { request, _ in
            if request.path == "/api/v2/catalog" {
                return (200, page((0..<24).map { card("ebook:\($0)", "ebook") }, next: nil,
                                  extra: ["total": 24, "total_exact": true]))
            }
            let id = request.url.lastPathComponent
            if id == "ebook:7" { return (200, ["type": "ebook"]) }
            var response = detail(id, "ebook", container: "epub")
            response["ebook"] = ["authors": [["name": "Author \(id)"]]]
            response["series_title"] = "Complete Metadata"
            response["poster_url"] = "/cover/\(id).webp?exp=123&sig=abc"
            return (200, response)
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let source = try await harness.provider.makeCatalogBatchSource(
            libraryId: "1", resumeAfter: nil, expectedSnapshotIdentifier: nil
        )
        let batch = try #require(try await source.next())
        #expect(batch.books.map(\.id) == (0..<24).filter { $0 != 7 }.map { "ebook:\($0)" })
        #expect(!batch.completesSnapshot)
        #expect(batch.books.allSatisfy {
            $0.author == "Author \($0.id)" && $0.series == "Complete Metadata"
                && $0.coverURL?.query == "exp=123&sig=abc" && $0.partKey == "120"
        })
        #expect(SiloV2Fixture.requests().filter { $0.path.hasPrefix("/api/v2/catalog/items/") }.count == 24)
    }

    @Test func catalogDetailFailureDoesNotCommitAPartialPage() async throws {
        SiloV2Fixture.install { request, _ in
            if request.path == "/api/v2/catalog" {
                return (200, page((0..<24).map { card("ebook:\($0)", "ebook") }, next: nil,
                                  extra: ["total": 24, "total_exact": true]))
            }
            if request.url.lastPathComponent == "ebook:7" { return (403, problem("forbidden", 403)) }
            return (200, detail(request.url.lastPathComponent, "ebook", container: "epub"))
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        await #expect(throws: (any Error).self) {
            _ = try await harness.provider.makeCatalogBatchSource(
                libraryId: "1", resumeAfter: nil, expectedSnapshotIdentifier: nil
            )
        }
    }

    @Test func rateLimitedReadWaitsAndRetriesTheSameRequest() async throws {
        SiloV2Fixture.install { request, history in
            if history.isEmpty { return (429, ["retry_after": 1]) }
            return (200, detail(request.url.lastPathComponent, "ebook", container: "epub"))
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let start = ContinuousClock.now
        let book = try await harness.provider.fetchFullBookDetails(bookId: "ebook:a", libraryId: "1")
        #expect(book.id == "ebook:a")
        #expect(start.duration(to: .now) >= .seconds(1))
        let requests = SiloV2Fixture.requests()
        #expect(requests.count == 2)
        #expect(requests[0].url == requests[1].url)
        #expect(requests[0].headers == requests[1].headers)
    }

    @Test func persistentRateLimitStopsAfterFiveRetries() async throws {
        SiloV2Fixture.install { _, _ in (429, ["retry_after": 1]) }
        let harness = makeHarness()
        defer { harness.cleanup() }
        await #expect(throws: (any Error).self) {
            _ = try await harness.provider.fetchFullBookDetails(bookId: "ebook:a", libraryId: "1")
        }
        #expect(SiloV2Fixture.requests().count == 6)
    }

    @Test func cancellingRateLimitedReadDoesNotSendAnotherRequest() async throws {
        SiloV2Fixture.install { _, _ in (429, ["retry_after": 30]) }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let task = Task {
            try await harness.provider.fetchFullBookDetails(bookId: "ebook:a", libraryId: "1")
        }
        while SiloV2Fixture.requests().isEmpty { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled read unexpectedly completed")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(SiloV2Fixture.requests().count == 1)
    }

    @Test func rateLimitedWriteIsNeverReplayed() async throws {
        SiloV2Fixture.install { _, _ in (429, ["retry_after": 1]) }
        let harness = makeHarness()
        defer { harness.cleanup() }
        var request = URLRequest(url: URL(string: "https://silo.invalid/api/v2/playback/sessions")!)
        request.httpMethod = "POST"
        await #expect(throws: (any Error).self) {
            let _: [String: String] = try await harness.provider.send(request, as: [String: String].self)
        }
        #expect(SiloV2Fixture.requests().count == 1)
    }

    @Test func detailCacheEvictsLeastRecentlyUsedBook() async throws {
        SiloV2Fixture.install { request, _ in
            (200, detail(request.url.lastPathComponent, "audiobook", container: "m4b"))
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let provider = harness.provider
        for index in 0..<100 {
            _ = try await provider.fetchFullBookDetails(bookId: "audiobook:\(index)", libraryId: "3")
        }
        _ = try await provider.fetchFullBookDetails(bookId: "audiobook:0", libraryId: "3")
        _ = try await provider.fetchFullBookDetails(bookId: "audiobook:100", libraryId: "3")
        _ = try await provider.fetchFullBookDetails(bookId: "audiobook:0", libraryId: "3")
        _ = try await provider.fetchFullBookDetails(bookId: "audiobook:1", libraryId: "3")

        let requests = SiloV2Fixture.requests()
        #expect(requests.filter { $0.path == "/api/v2/catalog/items/audiobook:0" }.count == 1)
        #expect(requests.filter { $0.path == "/api/v2/catalog/items/audiobook:1" }.count == 2)
    }

    @Test func collectionsTraverseCursorPagesWithOpaqueIDs() async throws {
        SiloV2Fixture.install { request, _ in
            switch (request.path, request.query("cursor").first) {
            case ("/api/v2/user/libraries", _):
                return (200, ["items": [["id": "3", "name": "Books", "type": "audiobooks", "sort_order": 0, "box_sets_enabled": false]]])
            case ("/api/v2/collections", _):
                return (200, ["items": [["id": "01J9Z8C3W4R5T6Y7U8I9O0P1Q4", "profile_id": "p-main", "creator_profile_id": "p-main",
                                         "name": "Rainy", "description": "", "collection_type": "manual", "is_shared": false,
                                         "sort_order": 0, "group_id": NSNull(), "poster_url": "", "item_count": 2]],
                              "groups": []])
            case ("/api/v2/catalog", let cursor):
                let extra: [String: Any] = ["total": 2, "total_exact": true, "window_cursor": "w"]
                return cursor == nil
                    ? (200, page([], next: "m1", extra: extra))
                    : (200, page([card("audiobook:a", "audiobook"), card("movie:z", "movie")], next: nil, extra: extra))
            case ("/api/v2/library/3/collections", _):
                return (200, ["library_id": "3", "groups": [], "collections": [[
                    "id": "cur-1", "library_id": "3", "library_ids": ["3"], "slug": "curated", "title": "Curated",
                    "description": "", "collection_type": "manual", "visibility": "visible", "sort_order": 1,
                    "group_id": NSNull(), "featured": false, "poster_url": "", "backdrop_url": "", "item_count": 2,
                ]]])
            case ("/api/v2/library/3/collections/cur-1/items", let cursor):
                return cursor == nil
                    ? (200, page([card("ebook:b", "ebook")], next: "k1"))
                    : (200, page([card("audiobook:a", "audiobook")], next: nil))
            default:
                return (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }

        let collections = try await harness.provider.fetchCollections(libraryId: "3")
        #expect(collections.map(\.name) == ["Rainy", "Curated"])
        #expect(collections[0].books == ["audiobook:a"])
        #expect(collections[1].books == ["ebook:b", "audiobook:a"])
        let membership = SiloV2Fixture.requests().filter { $0.path == "/api/v2/catalog" }
        #expect(membership.map { $0.query("cursor").first } == [nil, "m1"])
        #expect(membership.allSatisfy {
            $0.query("source") == ["user_collection"] && $0.query("collection_id") == ["01J9Z8C3W4R5T6Y7U8I9O0P1Q4"]
                && $0.query("library_id") == ["3"]
        })
        #expect(SiloV2Fixture.requests().filter { $0.path.hasPrefix("/api/v2/library/3/collections/cur-1") }.map { $0.query("cursor").first } == [nil, "k1"])
    }

    @Test func progressListingPagesByCursorAndSyncBatchesUniqueLatestWrites() async throws {
        SiloV2Fixture.install { request, _ in
            switch request.path {
            case "/api/v2/progress":
                let entry: (String, Double) -> [String: Any] = { id, position in
                    ["media_item_id": id, "position_seconds": position, "duration_seconds": 600, "completed": false,
                     "updated_at": "2026-01-03T00:00:00.000Z"]
                }
                switch request.query("cursor").first {
                case nil: return (200, page([entry("audiobook:a", 30)], next: "p1"))
                case "p1": return (200, page([], next: "p2"))
                default: return (200, page([entry("audiobook:c", 90)], next: nil))
                }
            case "/api/v2/sync/progress":
                let items = (request.body["items"] as? [[String: Any]] ?? []).enumerated().map { index, item -> [String: Any] in
                    let id = item["media_item_id"] as? String ?? ""
                    guard id != "missing" else {
                        return ["index": index, "media_item_id": id, "status": "failure",
                                "failure": ["type": "https://siloserver.org/docs/api/v2/problems/not_found", "title": "Not found",
                                            "status": 404, "detail": "Catalog item not found."]]
                    }
                    return ["index": index, "media_item_id": id, "status": "success"]
                }
                return (200, ["items": items, "summary": ["total": items.count, "succeeded": items.count - 1, "failed": 1]])
            default:
                return (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let provider = harness.provider

        let progress = try await provider.fetchUserMediaProgress(libraryId: "")
        #expect(progress.map(\.libraryItemId) == ["audiobook:a", "audiobook:c"])
        let listing = SiloV2Fixture.requests().filter { $0.path == "/api/v2/progress" }
        #expect(listing.map { $0.query("cursor").first } == [nil, "p1", "p2"])
        #expect(listing.allSatisfy { $0.query("limit") == ["200"] && $0.query("status").isEmpty && $0.query("offset").isEmpty })

        func write(_ id: String, _ position: Double, at seconds: TimeInterval) -> UserMediaProgress {
            UserMediaProgress(id: id, libraryItemId: id, providerId: provider.connection.id, episodeId: nil,
                              currentTime: position, progress: 0, isFinished: false, duration: 600,
                              lastUpdate: Date(timeIntervalSince1970: seconds), ebookProgress: nil)
        }
        var updates = (0..<100).map { write("audiobook:\($0)", 1, at: 1_767_225_600) }
        updates.append(write("missing", 1, at: 1_767_225_600))
        updates.append(write("audiobook:0", 2.5, at: 1_767_225_601))
        updates.append(write("audiobook:0", 9, at: 1_767_225_599))

        let succeeded = try await provider.syncAudiobookProgress(updates)
        let batches = SiloV2Fixture.requests().filter { $0.path == "/api/v2/sync/progress" }.map { $0.body["items"] as? [[String: Any]] ?? [] }
        #expect(batches.map(\.count) == [100, 1])
        let first = try #require(batches.first?.first)
        #expect(first["media_item_id"] as? String == "audiobook:0")
        #expect(first["position_ms"] as? Int == 2_500)
        #expect(first["updated_at"] as? String == "2026-01-01T00:00:01.000Z")
        #expect(succeeded.count == 100)
        #expect(!succeeded.contains("missing"))
    }

    @Test func ebookProgressUsesEventTimeEnvelopeAndGuardsUnorderedResets() async throws {
        SiloV2Fixture.install { request, _ in
            switch (request.method, request.path) {
            case ("GET", "/api/v2/ebooks/ebook:b/progress"):
                return (200, ["progress": ["content_id": "ebook:b", "file_id": "120", "location": "epubcfi(/6/4!/4/2)",
                                           "progress": 0.4, "updated_at": "2026-01-10T00:00:00.000Z"]])
            case ("PUT", "/api/v2/ebooks/ebook:b/progress"):
                return (200, ["progress": ["content_id": "ebook:b", "file_id": "120", "location": "epubcfi(/6/4!/4/2)",
                                           "progress": 0.4, "updated_at": "2026-01-10T00:00:00.000Z"]])
            case ("DELETE", "/api/v2/watched/ebook:b"):
                return (204, nil)
            default:
                return Self.catalogResponse(request) ?? (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let provider = harness.provider
        var book = Book(id: "ebook:b", title: "B", mediaType: .ebook, lastUpdate: Date(timeIntervalSince1970: 1_767_571_200),
                        providerId: provider.connection.id, source: .silo)

        let fetched = try #require(try await provider.fetchEbookProgress(for: book))
        #expect(fetched.progress == 0.4)

        try await provider.updateEbookProgress(for: book, progress: 0.25, epubLocator: nil)
        let put = try #require(SiloV2Fixture.requests().first { $0.method == "PUT" })
        #expect(put.body["file_id"] as? String == "120")
        #expect(put.body["updated_at"] as? String == "2026-01-05T00:00:00.000Z")

        try await provider.updateEbookProgress(for: book, progress: 0, epubLocator: nil)
        #expect(!SiloV2Fixture.requests().contains { $0.path == "/api/v2/watched/ebook:b" })

        book.lastUpdate = Date(timeIntervalSince1970: 1_768_435_200)
        try await provider.updateEbookProgress(for: book, progress: 0, epubLocator: nil)
        #expect(!SiloV2Fixture.requests().contains { $0.method == "DELETE" && $0.path == "/api/v2/watched/ebook:b" })
        let reset = try #require(SiloV2Fixture.requests().last { $0.method == "PUT" })
        #expect(reset.body["progress"] as? Double == 0)
        #expect(reset.body["updated_at"] as? String == "2026-01-15T00:00:00.000Z")
    }

    @Test func audiobookDownloadsUseOriginalFilesWithoutStartingPlayback() async throws {
        SiloV2Fixture.install { request, _ in Self.catalogResponse(request) ?? (404, problem("not_found", 404)) }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let book = Book(id: "audiobook:a", title: "A", providerId: harness.provider.connection.id, source: .silo)
        let requests = try await UnifiedDownloadService.sessionTrackRequests(for: book, provider: harness.provider)
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.request.url?.path == "/api/v2/direct-download" })
        #expect(requests.allSatisfy { $0.request.value(forHTTPHeaderField: "X-Profile-Id") == "p-main" })
        #expect(!SiloV2Fixture.requests().contains { $0.path.contains("/playback/") })
    }

    @Test func downloadedEbookKeysPreserveOpaqueFileIdentifiers() {
        let connection = UUID()
        let book = Book(id: "ebook-with-hyphens", title: "B", mediaType: .ebook, providerId: connection, source: .silo)
        for fileID in ["120", "file-part-a-opaque"] {
            let url = URL(fileURLWithPath: "/tmp/silo-\(connection.uuidString)-\(book.id)-\(fileID).epub")
            #expect(EpubBridgeBookKey.make(for: book, fileURL: url) == "\(book.stableId)#file:\(fileID)")
        }
    }

    @Test func ebookDownloadReadsTheV2FileRoute() async throws {
        let bytes = Data("PK-epub".utf8)
        SiloV2Fixture.install { request, _ in
            switch request.path {
            case "/api/v2/ebooks/ebook:b/progress": return (200, [String: Any]())
            case "/api/v2/ebooks/ebook:b/files/120/read": return (200, bytes)
            default: return Self.catalogResponse(request) ?? (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }
        let book = Book(id: "ebook:b", title: "B", mediaType: .ebook, providerId: harness.provider.connection.id, source: .silo)

        let file = try await harness.provider.downloadEbook(for: book, onProgress: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(file.lastPathComponent.hasSuffix("-120.epub"))
        let read = try #require(SiloV2Fixture.requests().first { $0.path.hasSuffix("/read") })
        #expect(read.headers["Authorization"] == "Bearer access-1")
        #expect(read.headers["X-Profile-Id"] == "p-main")
    }

    private struct NotebookHarness {
        let sync: ProviderReaderNotebookSync
        let idMap: InMemorySiloIDMap
        let scope: SiloReaderArtifactScope
        let local: ReaderAnnotation
        let cleanup: () -> Void
    }

    private func makeNotebook() -> NotebookHarness {
        let harness = makeHarness()
        let book = Book(id: "ebook:b", title: "B", mediaType: .ebook, providerId: harness.provider.connection.id, source: .silo)
        let idMap = InMemorySiloIDMap()
        let sync = ProviderReaderNotebookSync(
            book: book,
            providerResolver: SingleProviderResolver(harness.provider),
            siloIDMap: idMap,
            bookOrbitQueue: nil
        )
        let local = ReaderAnnotation(
            id: "6b0f3c1a-9d2e-4f7a-8c3b-1e2d3c4b5a69",
            bookId: book.stableId,
            locator: #"{"href":"c.xhtml","locations":{"cfi":"epubcfi(/6/4!/4/2)"}}"#,
            text: "Local edit",
            createdAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let scope = SiloReaderArtifactScope(connectionID: harness.provider.connection.id, account: "7/p-main", bookID: book.stableId)
        return NotebookHarness(sync: sync, idMap: idMap, scope: scope, local: local, cleanup: harness.cleanup)
    }

    nonisolated private static func readerResponse(_ request: SiloV2Fixture.Recorded) -> (status: Int, payload: Any?)? {
        switch request.path {
        case "/api/v2/ebooks/ebook:b/progress": return (200, [String: Any]())
        default: return catalogResponse(request)
        }
    }

    private func mapRemote(_ notebook: NotebookHarness, remoteID: String, etag: String, state: SiloReaderArtifactGuard.State = .synced) {
        notebook.idMap.setAnnotationRemoteID(remoteID, connectionID: notebook.scope.connectionID, bookID: notebook.scope.bookID, localID: notebook.local.id)
        notebook.idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: etag, state: state, recordedAt: Date()), remoteID: remoteID, in: notebook.scope)
    }

    @Test func createUsesTheLocalIdentityAndRecordsTheValidator() async throws {
        SiloV2Fixture.install { request, _ in
            if request.method == "POST", request.path == "/api/v2/ebooks/ebook:b/annotations" {
                return (201, annotation(request.body["id"] as? String ?? "", text: "Local edit", etag: "\"e1\""))
            }
            return Self.readerResponse(request) ?? (404, problem("not_found", 404))
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }

        _ = await notebook.sync.annotationUpserted(notebook.local)

        let create = try #require(SiloV2Fixture.requests().first { $0.method == "POST" })
        #expect(create.body["id"] as? String == notebook.local.id)
        #expect(create.body["cfi_range"] as? String == "epubcfi(/6/4!/4/2)")
        #expect(notebook.idMap.annotationRemoteID(connectionID: notebook.scope.connectionID, bookID: notebook.scope.bookID, localID: notebook.local.id) == notebook.local.id)
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)[notebook.local.id]?.etag == "\"e1\"")
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)[notebook.local.id]?.state == .synced)
    }

    @Test func staleValidatorParksTheEditWithoutWildcardOrFreshRetry() async throws {
        SiloV2Fixture.install { request, _ in
            if request.method == "PATCH" { return (412, problem("precondition_failed", 412)) }
            return Self.readerResponse(request) ?? (404, problem("not_found", 404))
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }
        mapRemote(notebook, remoteID: "srv-1", etag: "\"e1\"")

        _ = await notebook.sync.annotationUpserted(notebook.local)
        _ = await notebook.sync.annotationUpserted(notebook.local)

        let requests = SiloV2Fixture.requests()
        let patches = requests.filter { $0.method == "PATCH" }
        #expect(patches.count == 1)
        #expect(patches[0].path == "/api/v2/ebooks/ebook:b/annotations/srv-1")
        #expect(patches[0].headers["If-Match"] == "\"e1\"")
        #expect(!requests.contains { $0.headers["If-Match"] == "*" })
        #expect(!requests.contains { $0.method == "GET" && $0.path.hasSuffix("/annotations") })
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.state == .conflict)
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.etag == "\"e1\"")
    }

    @Test func offlineEditSurvivesPullAndRetriesUnderItsOriginalValidator() async throws {
        SiloV2Fixture.install { request, history in
            switch (request.method, request.path) {
            case ("PATCH", _):
                return history.contains { $0.method == "PATCH" }
                    ? (200, annotation("srv-1", text: "Local edit", etag: "\"e2\""))
                    : (0, nil)
            case ("GET", "/api/v2/ebooks/ebook:b/annotations"):
                return (200, page([annotation("srv-1", text: "Server text", etag: "\"e1\"", updatedAt: "2099-01-01T00:00:00.000Z")], next: nil))
            default:
                return Self.readerResponse(request) ?? (404, problem("not_found", 404))
            }
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }
        mapRemote(notebook, remoteID: "srv-1", etag: "\"e1\"")

        _ = await notebook.sync.annotationUpserted(notebook.local)
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.state == .pendingUpdate)

        let outcome = await notebook.sync.pull { .init(bookmarks: [], annotations: [notebook.local]) }
        guard case .replace(_, let annotations) = outcome else {
            Issue.record("Expected a merged notebook")
            return
        }
        #expect(annotations.map(\.text) == ["Local edit"])
        let patches = SiloV2Fixture.requests().filter { $0.method == "PATCH" }
        #expect(patches.map { $0.headers["If-Match"] } == ["\"e1\"", "\"e1\""])
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.state == .synced)
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.etag == "\"e2\"")
    }

    @Test func failedDeletionKeepsATombstoneUntilTheServerConfirms() async throws {
        SiloV2Fixture.install { request, history in
            switch (request.method, request.path) {
            case ("DELETE", _):
                return history.contains { $0.method == "DELETE" } ? (204, nil) : (0, nil)
            case ("GET", "/api/v2/ebooks/ebook:b/annotations"):
                return (200, page([annotation("srv-1", text: "Still on server", etag: "\"e1\"")], next: nil))
            default:
                return Self.readerResponse(request) ?? (404, problem("not_found", 404))
            }
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }
        mapRemote(notebook, remoteID: "srv-1", etag: "\"e1\"")

        _ = await notebook.sync.annotationRemoved(notebook.local)
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.state == .pendingDelete)

        let outcome = await notebook.sync.pull { .init(bookmarks: [], annotations: []) }
        guard case .replace(_, let annotations) = outcome else {
            Issue.record("Expected a merged notebook")
            return
        }
        #expect(annotations.isEmpty)
        let deletes = SiloV2Fixture.requests().filter { $0.method == "DELETE" }
        #expect(deletes.count == 2)
        #expect(deletes.allSatisfy { $0.headers["If-Match"] == "\"e1\"" && $0.path == "/api/v2/ebooks/ebook:b/annotations/srv-1" })
        #expect(notebook.idMap.artifactGuards(in: notebook.scope).isEmpty)
    }
    @Test func existingCreateNeverUsesServerClocksToOverwriteAnotherRevision() async throws {
        SiloV2Fixture.install { request, _ in
            if request.method == "POST" {
                return (200, annotation(request.body["id"] as? String ?? "", text: "Other device", etag: "\"e2\"", updatedAt: "2026-01-04T00:00:00.000Z"))
            }
            return Self.readerResponse(request) ?? (404, problem("not_found", 404))
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }
        _ = await notebook.sync.annotationUpserted(notebook.local)
        #expect(!SiloV2Fixture.requests().contains { $0.method == "PATCH" })
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)[notebook.local.id]?.state == .conflict)
    }

    @Test func missingValidatorPreservesLocalEditWithoutPatchingFreshlyFetchedRevision() async throws {
        SiloV2Fixture.install { request, _ in
            if request.method == "GET", request.path.hasSuffix("/annotations") {
                return (200, page([annotation("srv-1", text: "Other device", etag: "\"e2\"")], next: nil))
            }
            return Self.readerResponse(request) ?? (404, problem("not_found", 404))
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }
        mapRemote(notebook, remoteID: "srv-1", etag: "")
        _ = await notebook.sync.annotationUpserted(notebook.local)
        let outcome = await notebook.sync.pull { .init(bookmarks: [], annotations: [notebook.local]) }
        guard case .replace(_, let annotations) = outcome else {
            Issue.record("Expected a merged notebook")
            return
        }
        #expect(annotations.map(\.text) == ["Local edit"])
        #expect(!SiloV2Fixture.requests().contains { $0.method == "PATCH" })
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.state == .conflict)
    }

    @Test func deletionConflictRetainsTombstoneAndOriginalValidator() async throws {
        SiloV2Fixture.install { request, _ in
            if request.method == "DELETE" { return (412, problem("precondition_failed", 412)) }
            if request.method == "GET", request.path.hasSuffix("/annotations") {
                return (200, page([annotation("srv-1", text: "Other device", etag: "\"e2\"")], next: nil))
            }
            return Self.readerResponse(request) ?? (404, problem("not_found", 404))
        }
        let notebook = makeNotebook()
        defer { notebook.cleanup() }
        mapRemote(notebook, remoteID: "srv-1", etag: "\"e1\"")
        _ = await notebook.sync.annotationRemoved(notebook.local)
        let outcome = await notebook.sync.pull { .init(bookmarks: [], annotations: []) }
        guard case .replace(_, let annotations) = outcome else {
            Issue.record("Expected a merged notebook")
            return
        }
        #expect(annotations.isEmpty)
        #expect(notebook.idMap.artifactGuards(in: notebook.scope)["srv-1"]?.state == .pendingDelete)
        #expect(SiloV2Fixture.requests().filter { $0.method == "DELETE" }.allSatisfy { $0.headers["If-Match"] == "\"e1\"" })
    }

}
