import Foundation
import XCTest

@testable import enve

nonisolated final class StreamingInterruptionTests: XCTestCase {
    private var base: URL { URL(string: "http://127.0.0.1:18763")! }

    @MainActor
    func testStreamingResumesAfterBufferRunsOutDuringAnOutage() async throws {
        let key = "\(UUID().uuidString).wav"
        try await requireServer(key)
        try await withPlayer(key) { audio, book in
            audio.playDirectURL(book, url: base.appendingPathComponent("stream/\(key)"))
            try await waitUntil { audio.currentTime > 1 }
            try await control(key, mode: "stall")
            let stalledAt = try await waitForStall(audio)
            XCTAssertGreaterThan(stalledAt, 0)
            XCTAssertLessThan(stalledAt, 30, "The fixture must exhaust its buffer, not play a fully cached file")
            XCTAssertNil(audio.playbackError)
            try await control(key, mode: "online")
            try await waitUntil { audio.currentTime > stalledAt + 1 }
            XCTAssertEqual(audio.currentBook?.id, key)
            XCTAssertLessThan(audio.currentTime, stalledAt + 8)
        }
    }

    @MainActor
    func testDroppedConnectionRecoversWithoutResettingPosition() async throws {
        let key = "\(UUID().uuidString).wav"
        try await requireServer(key)
        try await withPlayer(key) { audio, book in
            audio.playDirectURL(book, url: base.appendingPathComponent("stream/\(key)"))
            try await waitUntil { audio.currentTime > 1 }
            try await control(key, mode: "stall")
            let stalledAt = try await waitForStall(audio)
            try await control(key, mode: "drop")
            try await Task.sleep(for: .seconds(1))
            try await control(key, mode: "online")
            try await waitUntil { audio.currentTime > stalledAt + 1 }
            XCTAssertEqual(audio.currentBook?.id, key)
            XCTAssertLessThan(audio.currentTime, stalledAt + 8)
            XCTAssertNil(audio.playbackError)
        }
    }

    @MainActor
    func testPausedPlaybackStaysPausedWhenNetworkReturns() async throws {
        let key = "\(UUID().uuidString).wav"
        try await requireServer(key)
        try await withPlayer(key) { audio, book in
            audio.playDirectURL(book, url: base.appendingPathComponent("stream/\(key)"))
            try await waitUntil { audio.currentTime > 1 }
            try await control(key, mode: "stall")
            _ = try await waitForStall(audio)
            audio.pause()
            let pausedAt = audio.currentTime
            try await control(key, mode: "online")
            try await Task.sleep(for: .seconds(1))
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(audio.currentTime, pausedAt, accuracy: 0.2)
            audio.play()
            try await waitUntil { audio.currentTime > pausedAt + 1 }
        }
    }

    @MainActor
    func testFailedInitialConnectionCanBeRetriedWithPlayAfterNetworkReturns() async throws {
        let key = "\(UUID().uuidString).wav"
        try await requireServer(key)
        try await withPlayer(key) { audio, book in
            try await control(key, mode: "drop")
            audio.playDirectURL(book, url: base.appendingPathComponent("stream/\(key)"))
            try await waitUntil { audio.playbackError != nil }
            XCTAssertEqual(audio.currentTime, 0, accuracy: 0.2)
            try await control(key, mode: "online")
            audio.play()
            try await waitUntil { audio.currentTime > 1 }
            XCTAssertNil(audio.playbackError)
        }
    }

    @MainActor
    func testPlayRetriesProviderSessionPreparationAfterAnOfflineFailure() async throws {
        let key = "\(UUID().uuidString).wav"
        try await requireServer(key)
        try await withPlayer(key) { audio, _ in
            let remoteBook = Book(id: key, title: "Provider streaming fixture", duration: 120,
                source: .audiobookshelf, mediaType: .audiobook)
            let provider = OfflineOnceProvider(url: base.appendingPathComponent("stream/\(key)"))
            audio.playBook(remoteBook, provider: provider)
            try await waitUntil { audio.playbackError != nil }
            XCTAssertEqual(provider.sessionStarts, 1)
            audio.play()
            try await waitUntil { audio.currentTime > 1 }
            XCTAssertEqual(provider.sessionStarts, 2)
            XCTAssertNil(audio.playbackError)
        }
    }

    @MainActor
    private func withPlayer(_ key: String, body: (PlaybackManager, Book) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "StreamingInterruptionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let profile = FamilyProfile(id: UUID().uuidString, name: "Streaming test", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let player = session.playback.manager
        let book = Book(id: key, title: "Streaming fixture", duration: 120, source: .local, mediaType: .audiobook)
        do { try await body(player, book) }
        catch { await session.retire(); throw error }
        await session.retire()
    }

    @MainActor
    private func requireServer(_ key: String) async throws {
        do { try await control(key, mode: "online") }
        catch { throw XCTSkip("Requires the controlled playback fixture server on localhost:18763") }
    }

    @MainActor
    private func control(_ key: String, mode: String) async throws {
        var request = URLRequest(url: base.appendingPathComponent("control/\(key)/\(mode)"))
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    @MainActor
    private func waitForStall(_ audio: PlaybackManager) async throws -> Double {
        var previous = audio.currentTime
        for _ in 0..<25 {
            try await Task.sleep(for: .seconds(1))
            let current = audio.currentTime
            if abs(current - previous) < 0.1 { return current }
            previous = current
        }
        XCTFail("Playback did not stall after the fixture stopped sending bytes")
        return audio.currentTime
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Streaming playback did not reach the expected state")
                throw NSError(domain: "StreamingInterruptionTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
private final class OfflineOnceProvider: PlaybackSessionProvider {
    var connection = ServerConnection(name: "Fixture", url: "http://127.0.0.1:18763", type: .audiobookshelf, token: "")
    private let url: URL
    private(set) var sessionStarts = 0

    init(url: URL) { self.url = url }

    func validateConnection() async throws -> Bool { true }
    func getAudioURL(for book: Book) -> URL? { url }
    func getStreamingHeaders() -> [String: String] { [:] }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        sessionStarts += 1
        if sessionStarts == 1 { throw URLError(.notConnectedToInternet) }
        return PlaybackSessionInfo(sessionId: UUID().uuidString,
            audioTracks: [AudioTrackInfo(index: 0, startOffset: 0, duration: 120,
                contentUrl: url.absoluteString, mimeType: "audio/wav")], chapters: [])
    }
}
