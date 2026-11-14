import Foundation
import Testing

@testable import enve

nonisolated private final class SiloAdminFixture: URLProtocol, @unchecked Sendable {
    nonisolated struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: [String: Any]

        var path: String { url.path }

        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
    }

    typealias Responder = @Sendable (_ request: Recorded) -> (status: Int, payload: [String: Any])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var responder: Responder = { _ in (404, [:]) }

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
        Self.recorded.append(entry)
        let responder = Self.responder
        Self.lock.unlock()

        let (status, payload) = responder(entry)
        let contentType = status >= 400 ? "application/problem+json" : "application/json"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated private func page(_ items: [[String: Any]], next: String?, extra: [String: Any] = [:]) -> [String: Any] {
    var info: [String: Any] = ["has_more": next != nil]
    if let next { info["next_cursor"] = next }
    return extra.merging(["items": items, "page": info]) { $1 }
}

nonisolated private func adminUser(_ id: String, _ username: String, role: String = "user", owner: Bool = false) -> [String: Any] {
    [
        "id": id, "username": username, "email": "\(username)@example.test", "role": role, "permissions": [],
        "enabled": true, "library_ids": NSNull(), "max_streams": NSNull(), "is_owner": owner,
        "password_login": true, "password_change_required": false, "break_glass": false,
        "effective_policy": [
            "library_ids": ["1", "3"], "max_playback_quality": "1080p", "max_streams": 2, "max_transcodes": 0,
            "max_remote_stream_bitrate_kbps": 0, "max_local_stream_bitrate_kbps": 0, "max_profiles": 5,
            "transcode_allowed": true, "audio_transcode_allowed": false, "download_allowed": true,
            "download_transcode_allowed": false, "requests_allowed": false, "permissions": [],
        ],
        "created_at": "2026-01-02T03:04:05.678Z", "updated_at": "2026-01-02T03:04:05.678Z", "last_active_at": NSNull(),
    ]
}

nonisolated private func problem(_ id: String, _ status: Int) -> [String: Any] {
    ["type": "https://siloserver.org/docs/api/v2/problems/\(id)", "title": id, "status": status, "detail": "Fixture problem."]
}

@MainActor
@Suite(.serialized)
struct SiloAdminV2Tests {
    private struct Harness {
        let service: SiloAdminService
        let cleanup: () -> Void
    }

    private func makeHarness() -> Harness {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloAdminFixture.self]
        let session = URLSession(configuration: config)
        let connection = ServerConnection(name: "Fixture", url: "https://silo.invalid", type: .silo,
                                          token: "access-1", userId: "7")
        let key = connection.id.uuidString
        UserDefaults.standard.set("p-main", forKey: "silo_profile_id_\(key)")
        UserDefaults.standard.set("7", forKey: "silo_profile_user_id_\(key)")
        let provider = SiloProvider(connection: connection, session: session)
        return Harness(service: SiloAdminService(provider: provider)) {
            for suffix in ["id", "name", "user_id"] {
                UserDefaults.standard.removeObject(forKey: "silo_profile_\(suffix)_\(key)")
            }
            session.invalidateAndCancel()
        }
    }

    @Test func adminUsersFollowEveryCursorAtTheMaximumPageSize() async throws {
        SiloAdminFixture.install { request in
            guard request.path == "/api/v2/admin/users" else { return (404, problem("not_found", 404)) }
            switch request.query("cursor") {
            case nil: return (200, page([adminUser("1", "owner", role: "admin", owner: true)], next: "c1"))
            case "c1": return (200, page([], next: "c2"))
            case "c2": return (200, page([adminUser("2", "reader")], next: nil))
            default: return (400, problem("invalid_cursor", 400))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }

        let users = try await harness.service.fetchAdminUsers()

        #expect(users.map(\.id) == ["1", "2"])
        #expect(users[0].isAdmin && users[0].isOwner)
        #expect(!users[1].isAdmin)
        #expect(users[1].effectivePolicy.libraryIDs == ["1", "3"])
        #expect(users[1].effectivePolicy.maxStreams == 2)
        let requests = SiloAdminFixture.requests()
        #expect(requests.map { $0.query("cursor") } == [nil, "c1", "c2"])
        #expect(requests.allSatisfy { $0.query("limit") == "200" && $0.method == "GET" })
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer access-1" })
        #expect(requests.allSatisfy { $0.headers["X-Profile-Id"] == "p-main" })
    }

    @Test func adminUsersRejectARepeatedCursor() async {
        SiloAdminFixture.install { _ in (200, page([adminUser("1", "owner")], next: "loop")) }
        let harness = makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: SiloAdminError.invalidPage) { try await harness.service.fetchAdminUsers() }
        #expect(SiloAdminFixture.requests().count == 2)
    }

    @Test func adminUsersRejectMoreResultsWithoutACursor() async {
        SiloAdminFixture.install { _ in (200, ["items": [], "page": ["has_more": true]]) }
        let harness = makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: SiloAdminError.invalidPage) { try await harness.service.fetchAdminUsers() }
    }

    @Test func forbiddenAdminRouteSurfacesAsUnauthorized() async {
        SiloAdminFixture.install { _ in (403, problem("forbidden", 403)) }
        let harness = makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: SiloAdminError.unauthorized) { try await harness.service.fetchAdminUsers() }
    }

    @Test func historyAndScansReadOneBoundedNewestFirstPage() async throws {
        SiloAdminFixture.install { request in
            switch request.path {
            case "/api/v2/admin/playback-history":
                return (200, page([
                    ["session_id": "s2", "user_id": "2", "username": "", "profile_id": "p2", "profile_name": "Kid",
                     "media_item_id": "audiobook:a", "media_file_id": "9", "media_title": "Dune", "media_type": "audiobook",
                     "play_method": "direct", "started_at": "2026-03-02T00:00:00.000Z", "ended_at": "2026-03-02T01:00:00.000Z",
                     "watched_seconds": 3600.0, "duration_seconds": 7200.0, "completed": false, "played_seconds": NSNull(),
                     "series_title": "", "season_number": NSNull(), "episode_number": NSNull(), "measured": false],
                ], next: "h1"))
            case "/api/v2/admin/autoscan/scans":
                return (200, page([
                    ["id": "41", "library_id": "3", "mode": "library", "trigger": "manual", "status": "completed",
                     "requested_at": "2026-03-01T00:00:00.000Z", "completed_at": "2026-03-01T00:05:00.000Z"],
                    ["id": "40", "library_id": "4", "mode": "subtree", "path": "/media/books/new", "trigger": "autoscan",
                     "status": "failed", "error_message": "unreadable"],
                ], next: "s1", extra: ["total": 57]))
            default:
                return (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }

        let history = try await harness.service.fetchPlaybackHistory(limit: 25)
        let scans = try await harness.service.fetchRecentScans(limit: 20)
        _ = try await harness.service.fetchPlaybackHistory(limit: 0)
        _ = try await harness.service.fetchRecentScans(limit: 500)

        #expect(history.map(\.sessionID) == ["s2"])
        #expect(history[0].profileName == "Kid")
        #expect(history[0].watchedSeconds == 3600)
        #expect(history[0].startedAt == ISO8601Timestamp.parse("2026-03-02T00:00:00.000Z"))
        #expect(scans.map(\.id) == ["41", "40"])
        #expect(scans.map(\.libraryID) == ["3", "4"])
        #expect(scans[0].completedAt == ISO8601Timestamp.parse("2026-03-01T00:05:00.000Z"))
        #expect(scans[1].path == "/media/books/new")
        let requests = SiloAdminFixture.requests()
        #expect(requests.map { $0.query("limit") } == ["25", "20", "1", "200"])
        #expect(requests.allSatisfy { $0.query("cursor") == nil })
    }

    @Test func librariesStatsAccountAndCatalogTotalsUseV2Routes() async throws {
        SiloAdminFixture.install { request in
            switch request.path {
            case "/api/v2/libraries":
                return (200, ["items": [
                    ["id": "3", "name": "Books", "type": "audiobooks", "enabled": true, "paths": ["/media/audiobooks"],
                     "metadata_language": "en", "sort_order": 0, "trailer_kinds": []],
                    ["id": "4", "name": "Films", "type": "movies", "enabled": false, "paths": ["/media/movies"],
                     "metadata_language": "en", "sort_order": 1, "trailer_kinds": []],
                ]])
            case "/api/v2/admin/stats":
                return (200, ["total_items": 12, "total_files": 30, "total_users": 2, "total_movies": 1,
                              "total_movie_files": 1, "total_shows": 0, "total_show_files": 0, "advisory_titles": 0,
                              "active_streams": 1, "total_storage_bytes": 4096, "watch_providers": []])
            case "/api/v2/account/me":
                return (200, ["id": "1", "username": "owner", "email": "", "role": "admin", "permissions": [],
                              "download_allowed": true, "password_change_required": false])
            case "/api/v2/catalog":
                return (200, page([["content_id": "audiobook:a", "type": "audiobook", "title": "Dune"]], next: "n1",
                                  extra: ["total": 140, "total_exact": true, "window_cursor": "w"]))
            default:
                return (404, problem("not_found", 404))
            }
        }
        let harness = makeHarness()
        defer { harness.cleanup() }

        let libraries = try await harness.service.fetchLibraries()
        let stats = try await harness.service.fetchStats()
        let me = try await harness.service.fetchMe()
        let total = try await harness.service.catalogTotal(libraryId: "3", type: "audiobook")

        #expect(libraries.map(\.id) == ["3", "4"])
        #expect(libraries[0].isReadingLibrary && libraries[0].countsAudiobooks)
        #expect(!libraries[1].isReadingLibrary && !libraries[1].enabled)
        #expect(stats.totalUsers == 2 && stats.totalStorageBytes == 4096)
        #expect(me.id == "1" && me.isAdmin && me.displayName == "owner")
        #expect(total == 140)
        let catalog = try #require(SiloAdminFixture.requests().last)
        #expect(catalog.query("library_id") == "3")
        #expect(catalog.query("type") == "audiobook")
        #expect(catalog.query("limit") == "1")
        #expect(catalog.query("cursor") == nil)
    }

    @Test func scanLibraryPostsTheStringLibraryIdentifier() async throws {
        SiloAdminFixture.install { request in
            guard request.path == "/api/v2/scan", request.method == "POST" else { return (404, problem("not_found", 404)) }
            return (202, ["status": "accepted", "mode": "library", "library_id": request.body["library_id"] ?? ""])
        }
        let harness = makeHarness()
        defer { harness.cleanup() }

        try await harness.service.scanLibrary(id: "3")

        let requests = SiloAdminFixture.requests()
        #expect(requests.count == 1)
        #expect(requests[0].body["library_id"] as? String == "3")
        #expect(requests[0].headers["Content-Type"] == "application/json")
    }
}
