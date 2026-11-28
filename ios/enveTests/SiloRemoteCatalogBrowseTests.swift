import Foundation
import Testing

@testable import enve

nonisolated private final class SiloBrowseFixture: URLProtocol, @unchecked Sendable {
    nonisolated struct Recorded {
        let url: URL
        let headers: [String: String]
        let body: Data?

        var json: [String: Any] { (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }

        var path: String { url.path }

        func query(_ name: String) -> [String] {
            if let value = json[name] { return [String(describing: value)] }
            return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .filter { $0.name == name }
                .compactMap(\.value)
        }
    }

    // Status 0 fails the request as a lost connection.
    typealias Responder = @Sendable (_ request: Recorded) -> (status: Int, payload: Any?, delay: TimeInterval)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var responder: Responder = { _ in (404, nil, 0) }

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

    static func catalogRequests() -> [Recorded] { requests().filter { $0.path == "/api/v2/catalog" || $0.path == "/api/v2/catalog/query" } }
    static func detailRequests() -> [Recorded] { requests().filter { $0.path.hasPrefix("/api/v2/catalog/items/") } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    // Delivery and cancellation share one lock, so a stopped load never reaches its client.
    private let deliveryLock = NSRecursiveLock()
    private var isStopped = false
    private var pendingDelivery: DispatchWorkItem?

    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        let entry = Recorded(url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.lock.lock()
        Self.recorded.append(entry)
        let responder = Self.responder
        Self.lock.unlock()

        let (status, payload, delay) = responder(entry)
        let responseBody = (payload as? Data) ?? payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        guard delay > 0 else {
            deliver(status: status, body: responseBody, url: url)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.deliver(status: status, body: responseBody, url: url) }
        deliveryLock.lock()
        pendingDelivery = work
        deliveryLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() {
        deliveryLock.lock()
        isStopped = true
        pendingDelivery?.cancel()
        pendingDelivery = nil
        deliveryLock.unlock()
    }

    private func deliver(status: Int, body: Data?, url: URL) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !isStopped else { return }
        pendingDelivery = nil
        guard status != 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let headers = ["Content-Type": status >= 400 ? "application/problem+json" : "application/json"]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !isStopped else { return }
        if let body {
            client?.urlProtocol(self, didLoad: body)
        }
        if !isStopped { client?.urlProtocolDidFinishLoading(self) }
    }
}

nonisolated private func problem(_ id: String, _ status: Int) -> [String: Any] {
    [
        "type": "https://siloserver.org/docs/api/v2/problems/\(id)",
        "title": id, "status": status, "detail": "Fixture problem.", "instance": "urn:silo:request:fixture",
    ]
}

nonisolated private func card(_ id: String, _ type: String, title: String? = nil) -> [String: Any] {
    [
        "content_id": id, "type": type, "title": title ?? id, "poster_url": "/api/v2/artwork/\(id).webp?sig=abc",
        "overview": "About \(id)", "runtime": 10, "duration_seconds": 600.5, "genres": ["Fiction"],
        "keywords": [], "status": "matched",
    ]
}

nonisolated private func detail(_ id: String) -> [String: Any] {
    card(id, "audiobook").merging([
        "cast": [], "crew": [], "ratings": [], "subtitles": [],
        "versions": [["file_id": "120", "file_name": "\(id).m4b", "container": "m4b", "duration": 600,
                      "file_size": 2048, "bitrate": 64, "added_at": "2026-01-01T00:00:00.000Z",
                      "resolution": "", "codec_video": "", "codec_audio": "", "hdr": false]],
    ]) { $1 }
}

// Applies type and q before the limit, as Silo does, and pages by an opaque offset cursor.
nonisolated private func catalog(_ request: SiloBrowseFixture.Recorded, items: [[String: Any]]) -> (status: Int, payload: Any?, delay: TimeInterval) {
    let type = request.query("type").first
    let search = request.query("q").first?.lowercased()
    let groups = request.json["groups"] as? [[String: Any]] ?? []
    let filtered = items.filter { item in
        groups.allSatisfy { group in
            (group["rules"] as? [[String: String]] ?? []).contains { rule in
                switch rule["field"] {
                case "genre": (item["genres"] as? [String] ?? []).contains(rule["value"] ?? "")
                case "original_language": item["original_language"] as? String == rule["value"]
                default: false
                }
            }
        } && (type == nil || item["type"] as? String == type)
            && (search == nil || (item["title"] as? String)?.lowercased().contains(search!) == true)
    }
    let start = request.query("cursor").first.flatMap(Int.init) ?? 0
    guard start <= filtered.count else { return (400, problem("invalid_cursor", 400), 0) }
    let end = min(start + (Int(request.query("limit").first ?? "") ?? 50), filtered.count)
    var page: [String: Any] = ["has_more": end < filtered.count]
    if end < filtered.count { page["next_cursor"] = String(end) }
    var payload: [String: Any] = ["items": Array(filtered[start..<end]), "page": page]
    if request.query("skip_total") != ["true"] {
        payload["total"] = filtered.count
        payload["total_exact"] = true
    }
    return (200, payload, 0)
}

@MainActor
private final class RemoteBrowseHarness {
    let fixture: OfflineAvailabilityFixture
    let provider: SiloProvider
    private let urlSession: URLSession

    init(selectedLibraryIds: Set<String>? = nil, libraries: [String] = ["3"]) throws {
        let fixture = try OfflineAvailabilityFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloBrowseFixture.self]
        let urlSession = URLSession(configuration: config)
        let connection = ServerConnection(
            id: fixture.providerID, name: "Fixture", url: "https://silo.invalid", type: .silo,
            token: "access-1", userId: "7", isConnected: true, selectedLibraryIds: selectedLibraryIds
        )
        UserDefaults.standard.set("p-main", forKey: "silo_profile_id_\(connection.id.uuidString)")
        UserDefaults.standard.set("7", forKey: "silo_profile_user_id_\(connection.id.uuidString)")
        let provider = SiloProvider(connection: connection, session: urlSession)
        fixture.session.providerConnections[fixture.providerID] = provider
        fixture.session.catalog.libraries = libraries.map {
            Library(id: $0, name: "Library \($0)", type: "audiobooks", providerId: fixture.providerID)
        }
        self.fixture = fixture
        self.urlSession = urlSession
        self.provider = provider
        providers = [provider]
    }

    private var providers: [SiloProvider]

    @discardableResult
    func addSilo(host: String, libraryId: String) -> UUID {
        let connection = ServerConnection(
            name: host, url: "https://\(host)", type: .silo, token: "access-2", userId: "7", isConnected: true
        )
        UserDefaults.standard.set("p-main", forKey: "silo_profile_id_\(connection.id.uuidString)")
        UserDefaults.standard.set("7", forKey: "silo_profile_user_id_\(connection.id.uuidString)")
        let added = SiloProvider(connection: connection, session: urlSession)
        providers.append(added)
        fixture.session.providerConnections[connection.id] = added
        fixture.session.catalog.libraries.append(
            Library(id: libraryId, name: host, type: "audiobooks", providerId: connection.id)
        )
        return connection.id
    }

    func model(source: LibrarySourceFilter, media: LibraryMediaFilter = .audiobooks) -> LibraryModel {
        fixture.defaults.set(source.rawValue, forKey: "imagine.library.source")
        fixture.defaults.set(media.rawValue, forKey: "imagine.library.source.media.\(source.rawValue)")
        return LibraryModel(profileSession: fixture.session)
    }

    func book(_ id: String, libraryId: String = "3", providerId: UUID? = nil) -> Book {
        Book(id: id, title: "Stored \(id)", libraryId: libraryId, providerId: providerId ?? fixture.providerID, source: .silo)
    }

    func saveAudioFile(for book: Book) throws {
        let folder = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 110_000).write(to: folder.appendingPathComponent("chapter_0.m4b"))
    }

    func close() async {
        for key in providers.map(\.connection.id.uuidString) {
            for suffix in ["id", "name", "user_id"] {
                UserDefaults.standard.removeObject(forKey: "silo_profile_\(suffix)_\(key)")
            }
            KeychainHelper.shared.delete("silo_refresh_\(key)")
            KeychainHelper.shared.delete("silo_profile_token_\(key)")
        }
        urlSession.invalidateAndCancel()
        await fixture.close()
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for the library model")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SiloRemoteCatalogBrowseTests {
    @Test func recentWindowsDoNotLimitBrowsingAfterReturningToTheLibrary() async throws {
        SiloBrowseFixture.install { request in
            switch request.path {
            case "/api/v2/user/libraries":
                return (200, ["items": ["3", "4"].map {
                    ["id": $0, "name": "Library \($0)", "type": "audiobooks"]
                }], 0)
            case "/api/v2/catalog":
                let library = request.query("library_id").first ?? "3"
                return catalog(request, items: (0..<120).map { card("audiobook:\(library)-\($0)", "audiobook") })
            default:
                return (200, ["items": [], "collections": []], 0)
            }
        }
        let harness = try RemoteBrowseHarness(libraries: ["3", "4"])
        for id in ["3", "4"] {
            await harness.fixture.session.catalog.refreshLibrary(providerId: harness.fixture.providerID, libraryId: id)
        }
        #expect(await harness.fixture.session.bookStore.bookCount(providerId: harness.fixture.providerID, mediaType: nil) == 24)

        let model = harness.model(source: .connection(harness.fixture.providerID))
        await model.reload()
        #expect(model.books.count == 100)
        while let page = model.loadMoreRemote() { await page.value }
        #expect(model.books.count == 240)
        await model.reload()
        #expect(model.books.count == 240)
        #expect(model.remoteCatalog == .loaded(hasMore: false))
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        await harness.close()
    }

    @Test(arguments: ["/api/v2/catalog", "/api/v2/user/libraries"])
    func refreshFailurePreservesSavedBooksAndClearsAfterRetry(failedPath: String) async throws {
        let responder: SiloBrowseFixture.Responder = { request in
            switch request.path {
            case "/api/v2/user/libraries":
                return (200, ["items": [["id": "3", "name": "Books", "type": "audiobooks"]]], 0)
            case "/api/v2/catalog":
                return catalog(request, items: [card("audiobook:fresh", "audiobook")])
            default:
                return (200, ["items": [], "collections": []], 0)
            }
        }
        SiloBrowseFixture.install { request in
            request.path == failedPath ? (503, problem("unavailable", 503), 0) : responder(request)
        }
        let harness = try RemoteBrowseHarness()
        let saved = harness.book("audiobook:saved")
        await harness.fixture.session.bookStore.upsertBooks([saved])
        let source = LibrarySourceFilter.library(providerId: harness.fixture.providerID, libraryId: "3")
        await harness.fixture.session.catalog.refreshLibrary(providerId: harness.fixture.providerID, libraryId: "3")
        #expect(harness.fixture.session.catalog.refreshFailure(for: source) != nil)
        #expect(await harness.fixture.session.bookStore.book(uniqueId: saved.uniqueId) != nil)

        SiloBrowseFixture.install(responder)
        await harness.fixture.session.catalog.refreshLibrary(providerId: harness.fixture.providerID, libraryId: "3")
        #expect(harness.fixture.session.catalog.refreshFailure(for: source) == nil)
        #expect(await harness.fixture.session.bookStore.bookCount(providerId: harness.fixture.providerID, mediaType: nil) == 2)
        await harness.close()
    }

    @Test func paginationOutageShowsDownloadsAndAnOrdinaryReloadStartsAFreshSession() async throws {
        let responder: SiloBrowseFixture.Responder = { request in
            catalog(request, items: (0..<120).map { card("audiobook:\($0)", "audiobook") })
        }
        SiloBrowseFixture.install(responder)
        let harness = try RemoteBrowseHarness()
        let pagedSaved = harness.book("audiobook:4")
        let laterSaved = harness.book("audiobook:saved")
        await harness.fixture.session.bookStore.upsertBooks([pagedSaved, laterSaved])
        try harness.saveAudioFile(for: pagedSaved)
        try harness.saveAudioFile(for: laterSaved)
        let model = harness.model(source: .library(providerId: harness.fixture.providerID, libraryId: "3"))
        await model.reload()
        #expect(model.remoteCatalog == .loaded(hasMore: true))
        #expect(model.books.count == 50)

        SiloBrowseFixture.install { _ in (0, nil, 0) }
        let page = try #require(model.loadMoreRemote())
        await page.value
        #expect(model.remoteCatalog == .onDeviceOnly)
        #expect(Set(model.books.map(\.uniqueId)) == [pagedSaved.uniqueId, laterSaved.uniqueId])
        #expect(model.remotePageError == nil)
        let outageRequests = SiloBrowseFixture.requests().count
        try await Task.sleep(for: .milliseconds(300))
        #expect(SiloBrowseFixture.requests().count == outageRequests)

        SiloBrowseFixture.install(responder)
        await model.reload()
        #expect(model.remoteCatalog == .loaded(hasMore: true))
        #expect(model.books.count == 50)
        #expect(SiloBrowseFixture.catalogRequests().map { $0.query("cursor").first } == [nil])
        await harness.close()
    }

    @Test func sameQueryRefetchesWhenTheSourceScopeChanges() async throws {
        SiloBrowseFixture.install { request in
            guard request.path == "/api/v2/catalog" else { return (500, problem("unexpected", 500), 0) }
            let id = request.url.host == "silo.invalid" ? "audiobook:\(request.query("library_id").first ?? "")" : "audiobook:b"
            return catalog(request, items: [card(id, "audiobook")])
        }
        let harness = try RemoteBrowseHarness(libraries: ["3", "4"])
        let otherId = harness.addSilo(host: "silo-b.invalid", libraryId: "9")
        let model = harness.model(source: .all)
        await model.reload()
        #expect(Set(model.books.map(\.id)) == ["audiobook:3", "audiobook:4", "audiobook:b"])

        harness.provider.connection.selectedLibraryIds = ["4"]
        await model.reload()
        #expect(Set(model.books.map(\.id)) == ["audiobook:4", "audiobook:b"])

        harness.fixture.session.providerConnections[otherId] = nil
        harness.fixture.session.catalog.libraries.removeAll { $0.providerId == otherId }
        await model.reload()
        #expect(model.books.map(\.id) == ["audiobook:4"])
        #expect(model.remoteCatalog == .loaded(hasMore: false))
        await harness.close()
    }

    @Test func delayedResponsesCannotRestoreCardsAfterScopeChangeOrRetirement() async throws {
        let responder: SiloBrowseFixture.Responder = { request in
            let library = request.query("library_id").first ?? ""
            let response = catalog(request, items: [card("audiobook:\(library)", "audiobook")])
            return (response.status, response.payload, library == "3" ? 0.5 : 0)
        }
        SiloBrowseFixture.install(responder)
        let harness = try RemoteBrowseHarness(libraries: ["3", "4"])
        let model = harness.model(source: .connection(harness.fixture.providerID))
        let first = Task { await model.reload() }
        try await waitUntil { model.books.map(\.id) == ["audiobook:4"] }
        harness.provider.connection.selectedLibraryIds = ["4"]
        await first.value
        try await waitUntil { !model.isLoadingRemotePage && model.remoteCatalog == .loaded(hasMore: false) }
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.books.map(\.id) == ["audiobook:4"])
        #expect(SiloBrowseFixture.catalogRequests().last?.query("library_id") == ["4"])

        harness.provider.connection.selectedLibraryIds = nil
        SiloBrowseFixture.install(responder)
        let pending = Task { await model.reload() }
        try await waitUntil {
            model.books.map(\.id) == ["audiobook:4"] && SiloBrowseFixture.catalogRequests().contains { $0.query("library_id") == ["3"] }
        }
        await harness.fixture.session.retire()
        await pending.value
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.books.map(\.id) == ["audiobook:4"])
        #expect(model.remoteCatalog == .loaded(hasMore: true))
        await harness.close()
    }

    @Test func detailSnapshotKeepsCardLanguageWhenTheCachedRecordOmitsIt() async throws {
        let harness = try RemoteBrowseHarness()
        let stored = harness.book("audiobook:language")
        await harness.fixture.session.bookStore.upsertBooks([stored])
        var summary = stored
        summary.language = "en"
        let snapshot = await harness.fixture.session.engine.library.detailSnapshot(for: summary, current: stored)
        #expect(snapshot.book.language == "en")
        await harness.close()
    }

    @Test func advancedFiltersPageServerResultsAndSkipUnmatchedLocalPages() async throws {
        SiloBrowseFixture.install { request in
            guard request.path == "/api/v2/catalog/query" else { return (500, problem("unexpected", 500), 0) }
            let items = (0..<160).map { index in
                card("audiobook:live\(index)", "audiobook").merging([
                    "genres": index < 80 ? ["History"] : ["Fiction"], "original_language": "en"
                ]) { $1 }
            }
            return catalog(request, items: items)
        }
        let harness = try RemoteBrowseHarness()
        let localId = UUID()
        let local = (0..<170).map { index in
            var book = Book(id: "local\(index)", title: String(format: "%03d", index), libraryId: "abs", providerId: localId, source: .audiobookshelf)
            book.genres = index < 160 ? ["History"] : ["Fiction"]
            book.language = "en"
            return book
        }
        await harness.fixture.session.bookStore.upsertBooks(local + [harness.book("audiobook:cached")])
        let filters = LibraryAdvancedFilters(genres: ["Fiction"], languages: ["en"])
        harness.fixture.defaults.set(try JSONEncoder().encode(filters), forKey: "imagine.library.advancedFilters")
        let model = harness.model(source: .all)
        await model.reload()
        #expect(model.remoteCatalog == .loaded(hasMore: true))
        #expect(model.books.count == 50)
        #expect(model.books.allSatisfy { $0.id.hasPrefix("audiobook:live") })
        for _ in 0..<5 where model.remoteCatalog == .loaded(hasMore: true) {
            model.loadMoreRemote()
            try await waitUntil { !model.isLoadingRemotePage }
        }
        #expect(model.remoteCatalog == .loaded(hasMore: false))
        #expect(model.books.count == 90)
        #expect(Set(model.books.filter { $0.providerId == localId }.map(\.id)) == Set((160..<170).map { "local\($0)" }))
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        await harness.close()
    }

    @Test func filterOptionsSearchDropsSlowerResponsesAndHonorsLibraryScope() async throws {
        SiloBrowseFixture.install { request in
            if request.path == "/api/v2/catalog/search/capabilities" {
                return (200, ["facet_value_search": true], 0)
            }
            guard request.path == "/api/v2/catalog/filters/search" else { return (500, problem("unexpected", 500), 0) }
            let old = request.query("q") == ["old"]
            let values = request.query("facet") == ["genre"] ? [["value": old ? "Old genre" : "New genre", "count": 1001]] : []
            return (200, ["values": values, "values_has_more": true], old ? 0.3 : 0)
        }
        let harness = try RemoteBrowseHarness(selectedLibraryIds: ["3"], libraries: ["3", "4"])
        let model = harness.model(source: .connection(harness.fixture.providerID))
        let old = Task { await model.loadAdvancedFilterOptions(search: "old") }
        try await Task.sleep(for: .milliseconds(50))
        await model.loadAdvancedFilterOptions(search: "new")
        await old.value
        #expect(model.advancedFilterOptions.genres == ["New genre"])
        #expect(model.hasMoreAdvancedFilterOptions)
        #expect(model.advancedFilterOptionsError == nil)
        let requests = SiloBrowseFixture.requests().filter { $0.path == "/api/v2/catalog/filters/search" }
        #expect(requests.allSatisfy { $0.query("library_id") == ["3"] && $0.query("type") == ["audiobook"] })
        await harness.close()
    }

    @Test func offlineAdvancedFiltersKeepOnlyMatchingFiles() async throws {
        SiloBrowseFixture.install { _ in (0, nil, 0) }
        let harness = try RemoteBrowseHarness()
        var saved = harness.book("audiobook:saved")
        saved.genres = ["Fiction"]
        saved.language = "en"
        var wrong = harness.book("audiobook:wrong")
        wrong.genres = ["Fiction"]
        wrong.language = "fr"
        var cached = harness.book("audiobook:cached")
        cached.genres = ["Fiction"]
        cached.language = "en"
        await harness.fixture.session.bookStore.upsertBooks([saved, wrong, cached])
        try harness.saveAudioFile(for: saved)
        try harness.saveAudioFile(for: wrong)
        harness.fixture.defaults.set(try JSONEncoder().encode(LibraryAdvancedFilters(genres: ["Fiction"], languages: ["en"])), forKey: "imagine.library.advancedFilters")
        let model = harness.model(source: .connection(harness.fixture.providerID))
        await model.reload()
        #expect(model.remoteCatalog == .onDeviceOnly)
        #expect(model.books.map(\.uniqueId) == [saved.uniqueId])
        await harness.close()
    }

    @Test func aSlowLibraryDoesNotDelayResultsFromAFastLibrary() async throws {
        SiloBrowseFixture.install { request in
            let slow = request.query("library_id") == ["3"]
            let response = catalog(request, items: [card(slow ? "slow" : "fast", "audiobook")])
            return (response.status, response.payload, slow ? 1.5 : 0)
        }
        let harness = try RemoteBrowseHarness(libraries: ["3", "4"])
        let model = harness.model(source: .connection(harness.fixture.providerID))
        let reload = Task { await model.reload() }
        try await waitUntil { model.books.contains { $0.id == "fast" } }
        #expect(!model.books.contains { $0.id == "slow" })
        #expect(model.isLoadingRemotePage)
        await reload.value
        #expect(Set(model.books.map(\.id)) == ["fast", "slow"])
        #expect(!model.isLoadingRemotePage)
        await harness.close()
    }

    @Test func downloadedSearchDoesNotLoseAMatchBehindCachedRemoteRows() async throws {
        let harness = try RemoteBrowseHarness()
        let cached = (0..<250).map { index in
            Book(id: "cached-\(index)", title: "Dune A \(index)", libraryId: "3",
                 providerId: harness.fixture.providerID, source: .silo)
        }
        let saved = Book(id: "saved", title: "Dune Z saved", libraryId: "3",
                         providerId: harness.fixture.providerID, source: .silo)
        await harness.fixture.session.bookStore.upsertBooks(cached + [saved])
        try harness.saveAudioFile(for: saved)
        harness.fixture.defaults.set("downloaded", forKey: "imagine.library.status")
        let model = harness.model(source: .all)
        await model.reload()
        model.updateSearch("Dune")
        try await waitUntil { model.searchQuery == "Dune" }
        await model.reload()
        #expect(model.books.map(\.uniqueId) == [saved.uniqueId])
        await harness.close()
    }

    @Test func firstPageMapsSummaryCardsWithoutDetailRequests() async throws {
        SiloBrowseFixture.install { request in
            guard request.path == "/api/v2/catalog" else { return (500, problem("unexpected", 500), 0) }
            return catalog(request, items: [card("audiobook:a", "audiobook"), card("movie:x", "movie"), card("ebook:b", "ebook")])
        }
        let harness = try RemoteBrowseHarness()
        let page = try await harness.provider.fetchRemoteCatalogPage(
            libraryId: "3", request: RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title), cursor: nil, limit: 50
        )

        #expect(page.books.map(\.id) == ["audiobook:a", "ebook:b"])
        #expect(page.books.map(\.mediaType) == [.audiobook, .ebook])
        #expect(page.nextCursor == nil)
        let first = try #require(page.books.first)
        #expect(first.uniqueId == "\(harness.fixture.providerID)_audiobook:a")
        #expect(first.libraryId == "3" && first.source == .silo && first.providerId == harness.fixture.providerID)
        #expect(first.coverURL?.absoluteString == "https://silo.invalid/api/v2/artwork/audiobook:a.webp?sig=abc")
        #expect(first.description == "About audiobook:a")
        #expect(first.duration == 600.5)
        #expect(first.genres == ["Fiction"])
        #expect(first.author == nil && first.chapters == nil)

        let requests = SiloBrowseFixture.catalogRequests()
        #expect(requests.count == 1)
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        let request = try #require(requests.first)
        #expect(request.query("library_id") == ["3"])
        #expect(request.query("sort") == ["title"])
        #expect(request.query("limit") == ["50"])
        #expect(request.query("skip_total") == ["true"])
        #expect(request.query("cursor").isEmpty && request.query("q").isEmpty && request.query("type").isEmpty)
        await harness.close()
    }

    @Test func searchFiltersOnTheServerBeforeTheLimitAndFollowsTheCursor() async throws {
        SiloBrowseFixture.install { request in
            let items = (0..<130).map { index in
                index.isMultiple(of: 2)
                    ? card("ebook:\(index)", "ebook", title: "Dune \(index)")
                    : card("audiobook:\(index)", "audiobook", title: "Dune \(index)")
            } + [card("ebook:other", "ebook", title: "Other")]
            return request.path == "/api/v2/catalog" ? catalog(request, items: items) : (500, problem("unexpected", 500), 0)
        }
        let harness = try RemoteBrowseHarness()
        let request = RemoteCatalogRequest(search: "dune", mediaType: .ebook, sort: .recentlyAdded)
        var cursor: String?
        var ids: [String] = []
        repeat {
            let page = try await harness.provider.fetchRemoteCatalogPage(libraryId: "3", request: request, cursor: cursor, limit: 50)
            ids.append(contentsOf: page.books.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        #expect(ids == (0..<130).filter { $0.isMultiple(of: 2) }.map { "ebook:\($0)" })
        let requests = SiloBrowseFixture.catalogRequests()
        #expect(requests.map { $0.query("cursor").first } == [nil, "50"])
        #expect(requests.allSatisfy {
            $0.query("q") == ["dune"] && $0.query("type") == ["ebook"] && $0.query("sort") == ["-added_at"]
                && $0.query("library_id") == ["3"] && $0.query("limit") == ["50"] && $0.query("skip_total") == ["true"]
        })
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        await harness.close()
    }

    @Test func expiredCursorIsAnErrorRatherThanAnEmptyPage() async throws {
        SiloBrowseFixture.install { _ in (400, problem("invalid_cursor", 400), 0) }
        let harness = try RemoteBrowseHarness()
        await #expect(throws: ProviderError.self) {
            _ = try await harness.provider.fetchRemoteCatalogPage(
                libraryId: "3", request: RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title), cursor: "stale", limit: 50
            )
        }
        await harness.close()
    }

    @Test func connectivityFailuresAreDistinguishedFromAuthenticationAndDecoding() async throws {
        let harness = try RemoteBrowseHarness()
        let request = RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title)
        func failure(_ responder: @escaping SiloBrowseFixture.Responder) async -> (any Error)? {
            SiloBrowseFixture.install(responder)
            do {
                _ = try await harness.provider.fetchRemoteCatalogPage(libraryId: "3", request: request, cursor: nil, limit: 50)
                return nil
            } catch {
                return error
            }
        }

        let offline = try #require(await failure({ _ in (0, nil, 0) }))
        #expect(RemoteCatalogConnectivity.isUnavailable(offline))
        let forbidden = try #require(await failure({ _ in (403, problem("forbidden", 403), 0) }))
        #expect(!RemoteCatalogConnectivity.isUnavailable(forbidden))
        let malformed = try #require(await failure({ _ in (200, ["items": "not-a-list"], 0) }))
        #expect(!RemoteCatalogConnectivity.isUnavailable(malformed))
        #expect(RemoteCatalogConnectivity.isUnavailable(URLError(.timedOut)))
        #expect(!RemoteCatalogConnectivity.isUnavailable(URLError(.serverCertificateUntrusted)))
        await harness.close()
    }

    @Test func onDeviceMatchesKeepOnlyScopedBooksWhoseFilesExist() {
        let provider = UUID()
        func book(_ id: String, title: String = "Dune", mediaType: AppMediaType = .audiobook,
                  libraryId: String = "3", providerId: UUID? = nil) -> Book {
            Book(id: id, title: title, author: "Frank Herbert", mediaType: mediaType,
                 libraryId: libraryId, providerId: providerId ?? provider, source: .silo)
        }
        let downloaded = book("a", title: "Dune Messiah")
        let metadataOnly = book("b")
        let otherLibrary = book("c", libraryId: "4")
        let otherSource = book("d", providerId: UUID())
        let ebook = book("e", mediaType: .ebook)
        let unmatched = book("f", title: "Children of Time")
        let candidates = [metadataOnly, downloaded, otherLibrary, otherSource, ebook, unmatched, downloaded]
        let onDisk = Set(candidates.filter { $0.id != metadataOnly.id }.map(\.uniqueId))
        let request = RemoteCatalogRequest(search: "herbert dune", mediaType: .audiobook, sort: .title)

        let matches = request.onDeviceBooks(
            from: candidates, providerId: provider, libraryId: "3", isOnDevice: { onDisk.contains($0.uniqueId) }
        )
        #expect(matches.map(\.uniqueId) == [downloaded.uniqueId])

        let unfiltered = RemoteCatalogRequest(search: nil, mediaType: nil, sort: .title).onDeviceBooks(
            from: candidates, providerId: provider, libraryId: nil, isOnDevice: { onDisk.contains($0.uniqueId) }
        )
        #expect(Set(unfiltered.map(\.id)) == ["a", "c", "e", "f"])
    }

    @Test func pagingPastFiftyFollowsCursorsWithTheServerTypeFilterAndKeepsLocalState() async throws {
        SiloBrowseFixture.install { request in
            let items = (0..<180).map { index in
                index % 3 == 2 ? card("ebook:\(index)", "ebook") : card("audiobook:\(index)", "audiobook")
            }
            return request.path == "/api/v2/catalog" ? catalog(request, items: items) : (500, problem("unexpected", 500), 0)
        }
        let harness = try RemoteBrowseHarness()
        var stored = harness.book("audiobook:4")
        stored.currentTime = 42
        await harness.fixture.session.bookStore.upsertBooks([stored])
        let model = harness.model(source: .library(providerId: harness.fixture.providerID, libraryId: "3"))
        await model.reload()

        #expect(model.books.count == 50)
        #expect(model.remoteCatalog == .loaded(hasMore: true))
        let merged = try #require(model.books.first { $0.id == "audiobook:4" })
        #expect(merged.currentTime == 42 && merged.title == "audiobook:4")

        model.loadNextPageIfNeeded(currentBookId: try #require(model.displayBooks.last).uniqueId)
        try await waitUntil { model.books.count == 100 && !model.isLoadingRemotePage }
        model.loadNextPageIfNeeded(currentBookId: model.displayBooks[model.displayBooks.count - 40].uniqueId)
        try await waitUntil { model.books.count == 120 && !model.isLoadingRemotePage }

        #expect(model.remoteCatalog == .loaded(hasMore: false))
        #expect(Set(model.books.map(\.uniqueId)).count == 120)
        #expect(model.books.allSatisfy { $0.mediaType == .audiobook })
        let requests = SiloBrowseFixture.catalogRequests()
        #expect(requests.map { $0.query("cursor").first } == [nil, "50", "100"])
        #expect(requests.allSatisfy {
            $0.query("type") == ["audiobook"] && $0.query("limit") == ["50"] && $0.query("skip_total") == ["true"]
                && $0.query("sort") == ["-added_at"]
        })
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        #expect(model.resultSummary == "120 books")
        await harness.close()
    }

    @Test func offlineFallbackShowsOnlyDownloadedFilesFromTheSource() async throws {
        SiloBrowseFixture.install { _ in (0, nil, 0) }
        let harness = try RemoteBrowseHarness()
        let saved = harness.book("audiobook:saved")
        let metadataOnly = harness.book("audiobook:metadata")
        let elsewhere = harness.book("audiobook:elsewhere", providerId: UUID())
        await harness.fixture.session.bookStore.upsertBooks([saved, metadataOnly, elsewhere])
        try harness.saveAudioFile(for: saved)
        try harness.saveAudioFile(for: elsewhere)

        let model = harness.model(source: .library(providerId: harness.fixture.providerID, libraryId: "3"))
        await model.reload()

        #expect(model.remoteCatalog == .onDeviceOnly)
        #expect(model.books.map(\.uniqueId) == [saved.uniqueId])
        #expect(model.isDownloaded(saved))

        SiloBrowseFixture.install { request in catalog(request, items: [card("audiobook:fresh", "audiobook")]) }
        await model.refreshFromServer()
        #expect(model.remoteCatalog == .loaded(hasMore: false))
        #expect(model.books.map(\.id) == ["audiobook:fresh"])
        await harness.close()
    }

    @Test func authenticationFailureIsReportedInsteadOfOfflineOrEmptyResults() async throws {
        SiloBrowseFixture.install { _ in (403, problem("forbidden", 403), 0) }
        let harness = try RemoteBrowseHarness()
        let saved = harness.book("audiobook:saved")
        await harness.fixture.session.bookStore.upsertBooks([saved])
        try harness.saveAudioFile(for: saved)

        let model = harness.model(source: .library(providerId: harness.fixture.providerID, libraryId: "3"))
        await model.reload()

        guard case .failed = model.remoteCatalog else {
            Issue.record("Expected a reported failure, got \(String(describing: model.remoteCatalog))")
            return await harness.close()
        }
        #expect(model.books.isEmpty)
        #expect(model.resultSummary == "Unavailable")
        await harness.close()
    }

    @Test func newerSearchIsNotReplacedByASlowerOlderResponse() async throws {
        SiloBrowseFixture.install { request in
            let items = [
                card("audiobook:old1", "audiobook", title: "old one"), card("audiobook:old2", "audiobook", title: "old two"),
                card("audiobook:new1", "audiobook", title: "new one"),
            ]
            let response = catalog(request, items: items)
            return request.query("q") == ["old"] ? (response.status, response.payload, 1.0) : response
        }
        let harness = try RemoteBrowseHarness()
        let model = harness.model(source: .library(providerId: harness.fixture.providerID, libraryId: "3"))
        await model.reload()

        model.updateSearch("old")
        try await waitUntil { SiloBrowseFixture.catalogRequests().contains { $0.query("q") == ["old"] } }
        model.updateSearch("new")
        #expect(model.books.isEmpty)
        #expect(model.remoteCatalog == .loading)
        try await waitUntil { model.books.map(\.id) == ["audiobook:new1"] }
        try await Task.sleep(for: .milliseconds(1300))

        #expect(model.books.map(\.id) == ["audiobook:new1"])
        #expect(model.remoteCatalog == .loaded(hasMore: false))
        await harness.close()
    }

    @Test func browsingIsScopedToTheOwningProfileAndSelectedLibraries() async throws {
        SiloBrowseFixture.install { request in
            request.path == "/api/v2/catalog"
                ? catalog(request, items: [card("audiobook:\(request.query("library_id").first ?? "")", "audiobook")])
                : (500, problem("unexpected", 500), 0)
        }
        let harness = try RemoteBrowseHarness(selectedLibraryIds: ["3"], libraries: ["3", "4"])
        let other = try OfflineAvailabilityFixture()
        let source = LibrarySourceFilter.connection(harness.fixture.providerID)
        #expect(!other.session.engine.library.supportsRemoteCatalog(source))
        #expect(harness.fixture.session.engine.library.supportsRemoteCatalog(source))

        let model = harness.model(source: source)
        await model.reload()

        #expect(model.books.map(\.id) == ["audiobook:3"])
        let requests = SiloBrowseFixture.catalogRequests()
        #expect(requests.map { $0.query("library_id") } == [["3"]])
        #expect(requests.allSatisfy { $0.headers["X-Profile-Id"] == "p-main" && $0.headers["Authorization"] == "Bearer access-1" })
        await other.close()
        await harness.close()
    }

    // Depends on the coordinator staging summary pages directly (no item details) and never overwriting richer rows.
    @Test func refreshStagesRecentSummariesWithoutDetailsOrAFullSiloImport() async throws {
        SiloBrowseFixture.install { request in
            let items = [card("audiobook:legacy", "audiobook", title: "Fresh title")]
                + (0..<40).map { card("audiobook:\($0)", "audiobook") }
            switch request.path {
            case "/api/v2/user/libraries":
                return (200, ["items": [["id": "3", "name": "Books", "type": "audiobooks", "sort_order": 0, "box_sets_enabled": false]]], 0)
            case "/api/v2/catalog":
                return catalog(request, items: items)
            case "/api/v2/collections":
                return (200, ["items": []], 0)
            case "/api/v2/library/3/collections":
                return (200, ["collections": []], 0)
            default:
                guard request.path.hasPrefix("/api/v2/catalog/items/") else { return (404, problem("not_found", 404), 0) }
                return (200, detail(request.url.lastPathComponent), 0)
            }
        }
        let harness = try RemoteBrowseHarness()
        var legacy = harness.book("audiobook:legacy")
        legacy.author = "Rich Author"
        legacy.currentTime = 321
        await harness.fixture.session.bookStore.upsertBooks([legacy])

        await harness.fixture.session.catalog.refreshLibrary(providerId: harness.fixture.providerID, libraryId: "3")

        let requests = SiloBrowseFixture.catalogRequests()
        #expect(requests.count == 1)
        #expect(requests.allSatisfy {
            $0.query("sort") == ["-added_at"] && (Int($0.query("limit").first ?? "") ?? .max) <= 50
        })
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        let kept = try #require(await harness.fixture.session.bookStore.book(uniqueId: legacy.uniqueId))
        #expect(kept.author == "Rich Author")
        #expect(kept.currentTime == 321)
        #expect(await harness.fixture.session.bookStore.loadCursor(providerId: harness.fixture.providerID, libraryId: "3") == nil)
        await harness.close()
    }

    @Test func allSourcesPagesLocalRowsAndLiveSiloIndependentlyWithoutCachedSiloRows() async throws {
        SiloBrowseFixture.install { request in
            let items = (0..<120).map { card("audiobook:live\($0)", "audiobook") }
            return request.path == "/api/v2/catalog" ? catalog(request, items: items) : (500, problem("unexpected", 500), 0)
        }
        let harness = try RemoteBrowseHarness()
        let local = UUID()
        let localRows = (0..<60).map {
            Book(id: "local\($0)", title: "Local \($0)", libraryId: "abs", providerId: local, source: .audiobookshelf)
        }
        let localEbook = Book(id: "local-ebook", title: "Local ebook", mediaType: .ebook, libraryId: "abs",
                              providerId: local, source: .audiobookshelf)
        let cached = harness.book("audiobook:cached")
        await harness.fixture.session.bookStore.upsertBooks(localRows + [localEbook, cached])

        let model = harness.model(source: .all)
        await model.reload()

        #expect(model.remoteCatalog == .loaded(hasMore: true))
        #expect(model.books.count == 100)
        #expect(model.books.filter { $0.providerId == local }.count == 50)
        #expect(model.books.filter { $0.providerId == harness.fixture.providerID }.count == 50)
        #expect(!model.books.contains { $0.uniqueId == cached.uniqueId || $0.mediaType == .ebook })

        model.loadNextPageIfNeeded(currentBookId: model.displayBooks[model.displayBooks.count - 40].uniqueId)
        try await waitUntil { model.books.count == 160 && !model.isLoadingRemotePage }
        model.loadNextPageIfNeeded(currentBookId: model.displayBooks[model.displayBooks.count - 40].uniqueId)
        try await waitUntil { model.books.count == 180 && !model.isLoadingRemotePage }

        #expect(model.remoteCatalog == .loaded(hasMore: false))
        #expect(Set(model.books.map(\.uniqueId)).count == 180)
        #expect(!model.books.contains { $0.uniqueId == cached.uniqueId })
        #expect(SiloBrowseFixture.catalogRequests().map { $0.query("cursor").first } == [nil, "50", "100"])
        #expect(SiloBrowseFixture.detailRequests().isEmpty)
        await harness.close()
    }

    @Test func allSourcesKeepsReachableResultsWhenAnotherServerIsUnreachable() async throws {
        SiloBrowseFixture.install { request in
            guard request.url.host == "silo.invalid" else { return (0, nil, 0) }
            return catalog(request, items: [card("audiobook:live", "audiobook")])
        }
        let harness = try RemoteBrowseHarness()
        let offlineId = harness.addSilo(host: "silo-b.invalid", libraryId: "9")
        let local = Book(id: "local", title: "Local", libraryId: "abs", providerId: UUID(), source: .audiobookshelf)
        let saved = harness.book("audiobook:saved", libraryId: "9", providerId: offlineId)
        let metadataOnly = harness.book("audiobook:metadata", libraryId: "9", providerId: offlineId)
        await harness.fixture.session.bookStore.upsertBooks([local, saved, metadataOnly])
        try harness.saveAudioFile(for: saved)

        let model = harness.model(source: .all)
        await model.reload()

        #expect(model.remoteCatalog == .loaded(hasMore: false))
        #expect(Set(model.books.map(\.uniqueId)) == [
            local.uniqueId, saved.uniqueId, "\(harness.fixture.providerID)_audiobook:live",
        ])
        #expect(model.remoteIssues.map(\.providerId) == [offlineId])
        #expect(model.remoteIssues.first?.message == nil)
        await harness.close()
    }

    @Test func offlineStatusFiltersUseOnlyDownloadedServerBooks() async throws {
        SiloBrowseFixture.install { _ in (0, nil, 0) }
        let harness = try RemoteBrowseHarness()
        var finishedSaved = harness.book("audiobook:finished-saved")
        finishedSaved.isFinished = true
        var finishedCached = harness.book("audiobook:finished-cached")
        finishedCached.isFinished = true
        await harness.fixture.session.bookStore.upsertBooks([finishedSaved, finishedCached])
        try harness.saveAudioFile(for: finishedSaved)
        let source = LibrarySourceFilter.library(providerId: harness.fixture.providerID, libraryId: "3")

        let browse = harness.model(source: source)
        await browse.reload()
        #expect(browse.remoteCatalog == .onDeviceOnly)

        harness.fixture.defaults.set(LibraryStatusFilter.finished.rawValue, forKey: "imagine.library.status")
        let finished = harness.model(source: source)
        await finished.reload()

        #expect(finished.remoteCatalog == nil)
        #expect(finished.books.map(\.uniqueId) == [finishedSaved.uniqueId])
        #expect(finished.localScopeNotice?.contains("unavailable") == true)
        await harness.close()
    }

    @Test func emptyFilteredPageStillOffersToContinue() async throws {
        SiloBrowseFixture.install { request in
            guard request.path == "/api/v2/catalog" else { return (500, problem("unexpected", 500), 0) }
            let start = request.query("cursor").first.flatMap(Int.init) ?? 0
            // Movie pages map to no books but still carry a continuation.
            let items = start < 200
                ? (start..<(start + 50)).map { card("movie:\($0)", "movie") }
                : [card("audiobook:end", "audiobook")]
            var page: [String: Any] = ["has_more": start < 200]
            if start < 200 { page["next_cursor"] = String(start + 50) }
            return (200, ["items": items, "page": page], 0)
        }
        let harness = try RemoteBrowseHarness()
        let model = harness.model(source: .library(providerId: harness.fixture.providerID, libraryId: "3"))
        await model.reload()

        #expect(model.books.isEmpty)
        #expect(model.remoteCatalog == .loaded(hasMore: true))
        model.loadMoreRemote()
        try await waitUntil { !model.isLoadingRemotePage && model.remoteCatalog == .loaded(hasMore: false) }
        #expect(model.books.map(\.id) == ["audiobook:end"])
        #expect(SiloBrowseFixture.catalogRequests().map { $0.query("cursor").first } == [nil, "50", "100", "150", "200"])
        await harness.close()
    }
}
