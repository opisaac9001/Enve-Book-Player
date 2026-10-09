import Foundation
import Testing

@testable import enve

nonisolated private final class SiloPlaybackFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(String, String, [String: Any])] = []

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    static func requests() -> [(String, String, [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
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
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.recorded.append((method, path, body))
        var status = 200
        var payload: [String: Any] = [:]
        if path.hasSuffix("/catalog/items/single") {
            payload = ["content_id": "single", "type": "audiobook", "title": "Single", "versions": [["file_id": 11, "file_name": "single.mp3", "duration": 90]]]
        } else if path.hasSuffix("/catalog/items/multi") {
            let first: [String: Any] = ["file_id": 21, "file_name": "one.mp3", "duration": 60]
            let second: [String: Any] = ["file_id": 22, "file_name": "two.mp3", "duration": 80]
            payload = ["content_id": "multi", "type": "audiobook", "title": "Multi", "versions": [first, second],
                       "playback_variants": [["parts": [["part_index": 0, "default_file_id": 21, "versions": [first]],
                                                        ["part_index": 1, "default_file_id": 22, "versions": [second]]]]]]
        } else if path.hasSuffix("/playback/start") {
            let fileID = body["file_id"] as? Int ?? 0
            let starts = Self.recorded.filter { $0.1.hasSuffix("/playback/start") && ($0.2["file_id"] as? Int) == fileID }.count
            let sessionID = fileID == 11 && starts == 2 ? "single-restarted" : "session-\(fileID)"
            payload = ["protocol_version": 3, "outcome": "playable", "session_id": sessionID,
                       "playback_plan": ["protocol_version": 3, "delivery": "original_http",
                                         "stream": ["url": "/stream/\(sessionID)", "protocol": "http_progressive"],
                                         "timeline": ["source_start_seconds": body["start_position"] ?? 0,
                                                      "player_start_seconds": body["start_position"] ?? 0,
                                                      "timeline_offset_seconds": 0],
                                         "source": ["duration_seconds": fileID == 22 ? 80 : fileID == 21 ? 60 : 90]]]
        } else if path.hasSuffix("/playback/session-11/progress") {
            status = 404
        } else if path.hasSuffix("/sync/progress") {
            payload = ["results": [["media_item_id": "multi", "status": "ok"]]]
        } else if path.contains("/playback/") && method == "DELETE" {
            status = 204
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status != 204, let data = try? JSONSerialization.data(withJSONObject: payload) {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct SiloPlaybackLifecycleTests {
    @Test func startRestartMultipartProgressAndStopKeepPositions() async throws {
        SiloPlaybackFixture.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloPlaybackFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let connection = ServerConnection(name: "Fixture", url: "https://silo.invalid", type: .silo,
                                          token: "fixture-token", userId: "fixture-user")
        let key = connection.id.uuidString
        UserDefaults.standard.set("profile-1", forKey: "silo_profile_id_\(key)")
        UserDefaults.standard.set("fixture-user", forKey: "silo_profile_user_id_\(key)")
        defer {
            UserDefaults.standard.removeObject(forKey: "silo_profile_id_\(key)")
            UserDefaults.standard.removeObject(forKey: "silo_profile_user_id_\(key)")
        }
        let provider = SiloProvider(connection: connection, session: session)

        let single = Book(id: "single", title: "Single", duration: 90, providerId: connection.id)
        let first = try await provider.startPlaybackSession(for: single)
        #expect(first.sessionId == "session-11")
        #expect(first.audioTracks.count == 1)
        try await provider.updatePlaybackProgress(book: single, sessionId: first.sessionId,
                                                  currentTime: 37, isFinished: false, timeListened: 37)
        await provider.reportPlayback(.stopped, book: single, sessionId: first.sessionId, position: 37)

        let multi = Book(id: "multi", title: "Multi", duration: 140, providerId: connection.id)
        let parts = try await provider.startPlaybackSession(for: multi)
        #expect(parts.audioTracks.count == 2)
        #expect(parts.audioTracks[1].startOffset == 60)
        try await provider.updatePlaybackProgress(book: multi, sessionId: parts.sessionId,
                                                  currentTime: 75, isFinished: false, timeListened: 75)
        await provider.reportPlayback(.stopped, book: multi, sessionId: parts.sessionId, position: 75)

        let requests = SiloPlaybackFixture.requests()
        let starts = requests.filter { $0.1.hasSuffix("/playback/start") }
        #expect(starts.count == 4)
        #expect(starts.allSatisfy { ($0.2["protocol_version"] as? Int) == 3 })
        #expect(starts.allSatisfy { (($0.2["client_playback_context"] as? [String: Any])?["deliveries"] as? [String: Any])?["original_http"] != nil })
        #expect(starts.allSatisfy { ($0.2["client_capabilities"] as? [String: Any])?["codecs_video"] == nil })
        #expect(starts.allSatisfy { (($0.2["client_playback_context"] as? [String: Any])?["deliveries"] as? [String: Any])?.count == 1 })
        #expect((starts[1].2["start_position"] as? Double) == 37)
        #expect(starts[2...].allSatisfy { $0.2["progress_persistence"] as? String == "client" && ($0.2["start_position"] as? Double) == 0 })
        #expect(requests.contains { $0.1.hasSuffix("/playback/single-restarted/progress") && ($0.2["position"] as? Double) == 37 })
        #expect(requests.contains { $0.1.hasSuffix("/playback/session-22/progress") && ($0.2["position"] as? Double) == 15 })
        #expect(requests.contains { $0.0 == "POST" && $0.1.hasSuffix("/sync/progress") })
        #expect(requests.contains { $0.0 == "DELETE" && $0.1.hasSuffix("/playback/single-restarted") })
        #expect(requests.contains { $0.0 == "DELETE" && $0.1.hasSuffix("/playback/session-21") })
        #expect(requests.contains { $0.0 == "DELETE" && $0.1.hasSuffix("/playback/session-22") })
    }
}
