import Foundation
import Testing

@testable import enve

nonisolated private final class SiloPlaybackFixture: URLProtocol, @unchecked Sendable {
    nonisolated struct Recorded {
        let method: String
        let path: String
        let authorization: String?
        let body: [String: Any]
    }

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
            path: url.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        )
        Self.lock.lock()
        let history = Self.recorded
        Self.recorded.append(entry)
        let responder = Self.responder
        Self.lock.unlock()

        let (status, payload) = responder(entry, history)
        let contentType = status >= 400 ? "application/problem+json" : "application/json"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let payload, let data = try? JSONSerialization.data(withJSONObject: payload) {
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

nonisolated private func capabilities(_ installationID: String) -> [String: Any] {
    [
        "state": "available", "allowed": true, "revision": "rev-\(installationID)", "installation_id": installationID,
        "protocol_versions": [3], "features": ["sequenced_progress_v1"], "deliveries": ["original_http"],
    ]
}

nonisolated private func decision(sessionID: String, fileID: String, duration: Double, start: Any) -> [String: Any] {
    [
        "protocol_version": 3, "server_features": [], "outcome": "playable", "session_id": sessionID,
        "playback_plan": [
            "protocol_version": 3, "plan_id": "plan-\(sessionID)", "plan_attempt_key": "key-\(sessionID)",
            "session_id": sessionID, "delivery": "original_http",
            "stream": ["url": "/api/v2/stream/\(sessionID)?st=signed", "protocol": "http_progressive", "headers": [:], "header_refresh": "none"],
            "timeline": ["source_start_seconds": start, "stream_origin_seconds": 0, "player_start_seconds": start,
                         "timeline_offset_seconds": 0, "can_seek_anywhere": true, "seek_restoration": "native"],
            "source": ["media_file_id": fileID, "duration_seconds": duration],
            "requested_media_file_id": fileID, "effective_media_file_id": fileID,
        ],
    ]
}

nonisolated private func singleDetail() -> [String: Any] {
    [
        "content_id": "audiobook:single", "type": "audiobook", "title": "Single", "genres": [], "keywords": [],
        "status": "matched", "cast": [], "crew": [], "ratings": [], "subtitles": [],
        "versions": [["file_id": "11", "file_name": "single.mp3", "container": "mp3", "duration": 90, "file_size": 1,
                      "bitrate": 64, "added_at": "2026-01-01T00:00:00.000Z", "resolution": "", "codec_video": "",
                      "codec_audio": "mp3", "hdr": false]],
    ]
}

nonisolated private func multiDetail() -> [String: Any] {
    let first: [String: Any] = ["file_id": "21", "file_name": "one.mp3", "container": "mp3", "duration": 60]
    let second: [String: Any] = ["file_id": "22", "file_name": "two.mp3", "container": "mp3", "duration": 80]
    return [
        "content_id": "audiobook:multi", "type": "audiobook", "title": "Multi", "genres": [], "keywords": [], "status": "matched",
        "versions": [first, second],
        "playback_variants": [["variant_id": "v1", "part_count": 2, "parts": [
            ["part_index": 0, "default_file_id": "21", "versions": [first]],
            ["part_index": 1, "default_file_id": "22", "versions": [second]],
        ]]],
    ]
}

nonisolated private let durations: [String: Double] = ["11": 90, "21": 60, "22": 80]

@MainActor
@Suite(.serialized)
struct SiloPlaybackLifecycleTests {
    private func makeProvider(token: String = "fixture-token") -> (SiloProvider, URLSession, () -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloPlaybackFixture.self]
        let session = URLSession(configuration: config)
        let connection = ServerConnection(name: "Fixture", url: "https://silo.invalid", type: .silo,
                                          token: token, userId: "fixture-user")
        let key = connection.id.uuidString
        UserDefaults.standard.set("profile-1", forKey: "silo_profile_id_\(key)")
        UserDefaults.standard.set("fixture-user", forKey: "silo_profile_user_id_\(key)")
        let cleanup = {
            UserDefaults.standard.removeObject(forKey: "silo_profile_id_\(key)")
            UserDefaults.standard.removeObject(forKey: "silo_profile_user_id_\(key)")
            KeychainHelper.shared.delete("silo_refresh_\(key)")
            session.invalidateAndCancel()
        }
        return (SiloProvider(connection: connection, session: session), session, cleanup)
    }

    nonisolated private static func standardResponse(_ request: SiloPlaybackFixture.Recorded, _ history: [SiloPlaybackFixture.Recorded]) -> (status: Int, payload: Any?) {
        let path = request.path
        if path == "/api/v2/playback/capabilities" { return (200, capabilities("6f1c2d3e-0000-4000-8000-000000000001")) }
        if path == "/api/v2/catalog/items/audiobook:single" { return (200, singleDetail()) }
        if path == "/api/v2/catalog/items/audiobook:multi" { return (200, multiDetail()) }
        if path == "/api/v2/playback/start" {
            let fileID = request.body["file_id"] as? String ?? ""
            let starts = history.filter { $0.path == path && ($0.body["file_id"] as? String) == fileID }.count
            let sessionID = fileID == "11" && starts == 1 ? "single-restarted" : "session-\(fileID)"
            return (201, decision(sessionID: sessionID, fileID: fileID, duration: durations[fileID] ?? 0, start: request.body["start_position"] ?? 0))
        }
        if path == "/api/v2/playback/session-11/progress" { return (404, problem("not_found", 404)) }
        if path.hasPrefix("/api/v2/playback/"), path.hasSuffix("/progress"), request.method == "POST" {
            let sample: [String: Any] = ["sequence": request.body["sequence"] ?? 0, "position": request.body["position"] ?? 0,
                                         "is_paused": request.body["is_paused"] ?? false]
            return (200, ["outcome": "applied", "accepted": sample])
        }
        if path == "/api/v2/sync/progress" {
            let items = (request.body["items"] as? [[String: Any]] ?? []).enumerated().map { index, item in
                ["index": index, "media_item_id": item["media_item_id"] ?? "", "status": "success"] as [String: Any]
            }
            return (200, ["items": items, "summary": ["total": items.count, "succeeded": items.count, "failed": 0]])
        }
        if path.hasPrefix("/api/v2/playback/"), request.method == "DELETE" {
            return (200, ["outcome": "stopped", "stop_id": request.body["stop_id"] ?? ""])
        }
        return (404, problem("not_found", 404))
    }

    private static func isCanonicalUUID(_ value: Any?) -> Bool {
        guard let value = value as? String, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    @Test func startRestartMultipartProgressAndStopUseServerInstallationAndSequences() async throws {
        SiloPlaybackFixture.install(Self.standardResponse)
        let (provider, _, cleanup) = makeProvider()
        defer { cleanup() }
        let installation = "6f1c2d3e-0000-4000-8000-000000000001"

        let single = Book(id: "audiobook:single", title: "Single", duration: 90, providerId: provider.connection.id)
        let first = try await provider.startPlaybackSession(for: single)
        #expect(first.sessionId == "session-11")
        #expect(first.audioTracks.first?.contentUrl.hasPrefix("https://silo.invalid/api/v2/stream/session-11?st=signed") == true)
        try await provider.updatePlaybackProgress(book: single, sessionId: first.sessionId,
                                                  currentTime: 37, isFinished: false, timeListened: 37)
        await provider.reportPlayback(.stopped, book: single, sessionId: first.sessionId, position: 37)

        let multi = Book(id: "audiobook:multi", title: "Multi", duration: 140,
                         lastUpdate: Date(timeIntervalSince1970: 1_767_323_045), providerId: provider.connection.id)
        let parts = try await provider.startPlaybackSession(for: multi)
        #expect(parts.audioTracks.count == 2)
        #expect(parts.audioTracks[1].startOffset == 60)
        try await provider.updatePlaybackProgress(book: multi, sessionId: parts.sessionId,
                                                  currentTime: 75, isFinished: false, timeListened: 75)
        await provider.reportPlayback(.stopped, book: multi, sessionId: parts.sessionId, position: 75)

        let requests = SiloPlaybackFixture.requests()
        #expect(requests.filter { $0.path == "/api/v2/playback/capabilities" }.count == 1)
        let starts = requests.filter { $0.path == "/api/v2/playback/start" }
        #expect(starts.count == 4)
        #expect(starts.allSatisfy { $0.body["installation_id"] as? String == installation })
        #expect(starts.allSatisfy { $0.body["profile_id"] as? String == "profile-1" })
        #expect(starts.map { $0.body["file_id"] as? String } == ["11", "11", "21", "22"])
        #expect(starts.allSatisfy { ($0.body["protocol_version"] as? Int) == 3 })
        #expect(starts.allSatisfy { (($0.body["client_playback_context"] as? [String: Any])?["deliveries"] as? [String: Any])?.count == 1 })
        for start in starts {
            let capabilities = try #require(start.body["client_capabilities"] as? [String: Any])
            #expect(capabilities["codecs_video"] as? [String] == [])
            #expect(capabilities["codecs_video_hardware"] as? [String] == [])
            let context = try #require(start.body["client_playback_context"] as? [String: Any])
            #expect(context["app_version"] is String)
            #expect(context["output"] is [String: Any])
            let deliveries = try #require(context["deliveries"] as? [String: [String: Any]])
            #expect(deliveries["original_http"]?["video_codecs"] as? [String] == [])
        }
        #expect((starts[1].body["start_position"] as? Double) == 37)
        #expect(starts[2...].allSatisfy { $0.body["progress_persistence"] as? String == "client" })

        let lost = try #require(requests.first { $0.path == "/api/v2/playback/session-11/progress" })
        #expect(lost.body["sequence"] as? Int == 1)
        let restarted = try #require(requests.first { $0.path == "/api/v2/playback/single-restarted/progress" })
        #expect(restarted.body["sequence"] as? Int == 1)
        #expect(restarted.body["position"] as? Double == 37)
        #expect(restarted.body["installation_id"] as? String == installation)
        let partSample = try #require(requests.first { $0.path == "/api/v2/playback/session-22/progress" })
        #expect(partSample.body["position"] as? Double == 15)

        let sync = try #require(requests.first { $0.path == "/api/v2/sync/progress" })
        let item = try #require((sync.body["items"] as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["media_item_id", "position_ms", "duration_ms", "updated_at"])
        #expect(item["media_item_id"] as? String == "audiobook:multi")
        #expect(item["position_ms"] as? Int == 75_000)
        #expect(item["duration_ms"] as? Int == 140_000)
        #expect(item["updated_at"] as? String == "2026-01-02T03:04:05.000Z")

        let stops = requests.filter { $0.method == "DELETE" }
        #expect(stops.map(\.path) == ["/api/v2/playback/single-restarted", "/api/v2/playback/session-21", "/api/v2/playback/session-22"])
        #expect(stops.allSatisfy { Self.isCanonicalUUID($0.body["stop_id"]) && $0.body["installation_id"] as? String == installation })
        #expect(stops[0].body["sequence"] as? Int == 2)
        #expect(stops[0].body["position"] as? Double == 37)
        #expect(stops[1].body["sequence"] == nil && stops[1].body["position"] == nil)
    }

    @Test func authRecoveryAndInstallationChangeResendTheSameSample() async throws {
        SiloPlaybackFixture.install { request, history in
            if request.path == "/api/v2/auth/refresh" {
                return (200, ["access_token": "fresh-token", "refresh_token": "refresh-2", "expires_in": 3600])
            }
            if request.path == "/api/v2/playback/capabilities" {
                let previous = history.filter { $0.path == request.path }.count
                return (200, capabilities(previous == 0 ? "6f1c2d3e-0000-4000-8000-00000000000a" : "6f1c2d3e-0000-4000-8000-00000000000b"))
            }
            if request.path.hasSuffix("/progress") {
                if request.authorization == "Bearer stale-token" { return (401, problem("invalid_token", 401)) }
                if request.body["installation_id"] as? String == "6f1c2d3e-0000-4000-8000-00000000000a" {
                    return (409, problem("installation_changed", 409))
                }
            }
            return Self.standardResponse(request, history)
        }
        let (provider, _, cleanup) = makeProvider()
        defer { cleanup() }
        KeychainHelper.shared.set("refresh-1", key: "silo_refresh_\(provider.connection.id.uuidString)")

        let single = Book(id: "audiobook:single", title: "Single", duration: 90, providerId: provider.connection.id)
        let started = try await provider.startPlaybackSession(for: single)
        provider.connection.token = "stale-token"
        await provider.reportPlayback(.resumed, book: single, sessionId: started.sessionId, position: 12)
        await provider.reportPlayback(.paused, book: single, sessionId: started.sessionId, position: 14)

        let samples = SiloPlaybackFixture.requests().filter { $0.path == "/api/v2/playback/session-11/progress" }
        #expect(samples.map(\.authorization) == ["Bearer stale-token", "Bearer fresh-token", "Bearer fresh-token", "Bearer fresh-token"])
        #expect(samples.map { $0.body["sequence"] as? Int } == [1, 1, 1, 2])
        #expect(samples.map { $0.body["position"] as? Double } == [12, 12, 12, 14])
        #expect(samples.map { $0.body["installation_id"] as? String } == [
            "6f1c2d3e-0000-4000-8000-00000000000a", "6f1c2d3e-0000-4000-8000-00000000000a",
            "6f1c2d3e-0000-4000-8000-00000000000b", "6f1c2d3e-0000-4000-8000-00000000000b",
        ])
        #expect(SiloPlaybackFixture.requests().filter { $0.path == "/api/v2/auth/refresh" }.count == 1)
    }

    @Test func failedStopIsRetriedWithTheSameIdentityAndFinalSample() async throws {
        SiloPlaybackFixture.install { request, history in
            if request.method == "DELETE", !history.contains(where: { $0.method == "DELETE" }) {
                return (503, problem("dependency_unavailable", 503))
            }
            return Self.standardResponse(request, history)
        }
        let (provider, _, cleanup) = makeProvider()
        defer { cleanup() }

        let single = Book(id: "audiobook:single", title: "Single", duration: 90, providerId: provider.connection.id)
        let first = try await provider.startPlaybackSession(for: single)
        await provider.reportPlayback(.stopped, book: single, sessionId: first.sessionId, position: 41)
        _ = try await provider.startPlaybackSession(for: single)

        let stops = SiloPlaybackFixture.requests().filter { $0.method == "DELETE" }
        #expect(stops.count == 2)
        #expect(stops.allSatisfy { $0.path == "/api/v2/playback/session-11" })
        #expect(Self.isCanonicalUUID(stops[0].body["stop_id"]))
        #expect(stops[0].body["stop_id"] as? String == stops[1].body["stop_id"] as? String)
        #expect(stops.allSatisfy { $0.body["sequence"] as? Int == 1 && $0.body["position"] as? Double == 41 })
    }
}
