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

    nonisolated private static func catalogResponse(_ request: SiloV2Fixture.Recorded) -> (status: Int, payload: Any?)? {
        switch request.path {
        case "/api/v2/catalog/items/audiobook:a": return (200, detail("audiobook:a", "audiobook", container: "m4b"))
        case "/api/v2/catalog/items/ebook:b": return (200, detail("ebook:b", "ebook", container: "epub"))
        case "/api/v2/catalog":
            guard request.query("source").isEmpty else { return nil }
            let total: [String: Any] = ["total": 3, "total_exact": true, "window_cursor": "w"]
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
        #expect(batches.flatMap(\.books).first?.partKey == "120")

        let login = try #require(SiloV2Fixture.requests().first { $0.path == "/api/v2/auth/login" })
        #expect(login.body["username"] as? String == "reader")
        let catalog = SiloV2Fixture.requests().filter { $0.path == "/api/v2/catalog" }
        #expect(catalog.map { $0.query("cursor").first } == [nil, "c1", "c2"])
        #expect(catalog.allSatisfy {
            $0.query("sort") == ["title"] && $0.query("limit") == ["100"] && $0.query("library_id") == ["3"]
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
