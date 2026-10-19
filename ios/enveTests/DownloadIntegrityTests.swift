import Foundation
import Testing

@testable import enve

private final class SessionDownloadFixtureProvider: PlaybackSessionProvider {
    var connection = ServerConnection(name: "Fixture", url: "https://example.test", type: .silo, token: "stale")
    var capabilities: ProviderCapabilities { [] }
    var trackURLs: [String] = []
    var sessionError: Error?
    var fallbackURL: URL?

    func validateConnection() async throws -> Bool { true }
    func getAudioURL(for book: Book) -> URL? { fallbackURL }
    func chapterExtractionURL(for book: Book) -> URL? { nil }
    func getStreamingHeaders() -> [String: String] { ["Authorization": "Bearer \(connection.token ?? "")"] }
    func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {}

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        if let sessionError { throw sessionError }
        connection.token = "refreshed"
        return PlaybackSessionInfo(sessionId: "fixture", audioTracks: trackURLs.enumerated().map {
            AudioTrackInfo(index: $0.offset, startOffset: Double($0.offset * 30), duration: 30,
                contentUrl: $0.element, mimeType: "audio/mpeg")
        }, chapters: [])
    }
}

@MainActor
struct DownloadIntegrityTests {
    private let book = Book(id: "fixture", title: "Fixture", providerId: UUID(), source: .silo)

    @Test func sessionRequestsCarryHeadersFromAfterTheSessionRefresh() async throws {
        let provider = SessionDownloadFixtureProvider()
        provider.trackURLs = ["https://example.test/a.mp3", "https://example.test/b.mp3"]
        let requests = try await UnifiedDownloadService.sessionTrackRequests(for: book, provider: provider)
        #expect(requests.map { $0.request.url?.lastPathComponent } == ["a.mp3", "b.mp3"])
        #expect(requests.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed" })
    }

    @Test func sessionFailureIsTheDownloadFailureInsteadOfASingleFileFallback() async {
        let provider = SessionDownloadFixtureProvider()
        provider.sessionError = ProviderError.serverError("manifest unavailable")
        provider.fallbackURL = URL(string: "https://example.test/first-track-only.mp3")
        await #expect {
            _ = try await UnifiedDownloadService.sessionTrackRequests(for: book, provider: provider)
        } throws: { error in
            error.localizedDescription.contains("manifest unavailable")
        }
    }

    @Test func unusableTrackURLFailsInsteadOfDroppingTheTrack() async {
        let provider = SessionDownloadFixtureProvider()
        provider.trackURLs = ["https://example.test/a.mp3", "", "https://example.test/c.mp3"]
        await #expect(throws: UnifiedDownloadService.DownloadError.self) {
            _ = try await UnifiedDownloadService.sessionTrackRequests(for: book, provider: provider)
        }
    }

    @Test func emptySessionFallsBackToTheProviderAudioURL() async throws {
        let provider = SessionDownloadFixtureProvider()
        provider.fallbackURL = URL(string: "https://example.test/book.m4b")
        let requests = try await UnifiedDownloadService.sessionTrackRequests(for: book, provider: provider)
        #expect(requests.map { $0.request.url?.lastPathComponent } == ["book.m4b"])
        #expect(requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed")
    }

    @Test func truncatedBodyIsRejectedAgainstContentLength() throws {
        let file = try writeFile(bytes: 4_000)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: NSError.self) {
            try BookDownloadManager.validateDownloadedFileLength(at: file, response: response(status: 200, length: 8_000))
        }
        try BookDownloadManager.validateDownloadedFileLength(at: file, response: response(status: 200, length: 4_000))
    }

    @Test func lengthIsNotComparedWhenTheBodyIsEncodedPartialOrUndeclared() throws {
        let file = try writeFile(bytes: 4_000)
        defer { try? FileManager.default.removeItem(at: file) }
        try BookDownloadManager.validateDownloadedFileLength(at: file, response: response(status: 200, length: 900, encoding: "gzip"))
        try BookDownloadManager.validateDownloadedFileLength(at: file, response: response(status: 206, length: 1_000))
        try BookDownloadManager.validateDownloadedFileLength(at: file, response: response(status: 200, length: nil))
    }

    private func writeFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func response(status: Int, length: Int?, encoding: String? = nil) -> HTTPURLResponse {
        var headers = ["Content-Type": "audio/mpeg"]
        if let length { headers["Content-Length"] = String(length) }
        if let encoding { headers["Content-Encoding"] = encoding }
        return HTTPURLResponse(url: URL(string: "https://example.test/a.mp3")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
