import Foundation
import Testing

@testable import enve

nonisolated private final class BookOrbitCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let indices: [Any] = ["2", "2.5", 2, 2.5, NSNull(), "1–3", "0.50"]
        var cards: [[String: Any]] = indices.enumerated().map { offset, index in
            ["id": offset + 1, "title": "Fixture", "seriesName": "Series", "seriesIndex": index,
             "files": [["id": offset + 1, "format": "epub", "role": "primary"]]]
        }
        cards.append(["id": 8, "title": "Without series index", "seriesName": "Series"])
        let payload: Any
        if url.path == "/api/v1/audiobooks/9/playback-state" {
            if request.httpMethod == "PUT" {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                guard json?["assetId"] as? String == "asset-b",
                      json?["positionMs"] as? Int == 15_000,
                      json?["baseRevision"] as? Int == 4,
                      json?["manifestRevision"] as? String == "manifest-1" else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
            }
            payload = [
                "assetId": "asset-b", "positionMs": 15_000, "percentage": 62.5,
                "revision": 4, "manifestRevision": "manifest-1"
            ]
        } else if url.path == "/api/v1/audiobooks/9/manifest" {
            payload = [
                "revision": "manifest-1",
                "assets": [
                    ["assetId": "asset-b", "sequence": 1, "format": "mp3", "durationMs": 60_000],
                    ["assetId": "asset-a", "sequence": 0, "format": "mp3", "durationMs": 60_000]
                ],
                "chapters": [["title": "Opening", "startMs": 0]],
                "totalDurationMs": 120_000
            ]
        } else if url.path == "/api/v1/books/9" {
            payload = ["id": 9, "title": "Two-track audiobook", "files": [
                ["id": 90, "format": "mp3", "role": "primary", "durationSeconds": 60],
                ["id": 91, "format": "mp3", "role": "content", "durationSeconds": 60]
            ]]
        } else if url.path.hasSuffix("/books") {
            payload = ["items": cards, "total": cards.count, "page": 0, "size": 200]
        } else if let id = Int(url.lastPathComponent), (1...cards.count).contains(id) {
            payload = cards[id - 1]
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
struct BookOrbitCatalogTests {
    @Test func playerTimelinePreservesFileIdentityForProgress() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitCatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = BookOrbitProvider(
            connection: ServerConnection(name: "Fixture", url: "https://bookorbit.invalid", type: .bookOrbit,
                                         token: "fixture-token"), session: session
        )
        let book = try await provider.fetchFullBookDetails(bookId: "9", libraryId: "1")
        let playback = try await provider.startPlaybackSession(for: book)
        let playingBook = book.withPlaybackSessionTimeline(tracks: playback.audioTracks, duration: 120)
        #expect(playback.audioTracks.map(\.id) == ["asset-a", "asset-b"])
        #expect(playback.audioTracks.map(\.contentUrl) == [
            "https://bookorbit.invalid/api/v1/audiobooks/9/assets/asset-a/content",
            "https://bookorbit.invalid/api/v1/audiobooks/9/assets/asset-b/content"
        ])
        #expect(playback.chapters.first?.title == "Opening")
        try await provider.updatePlaybackProgress(book: playingBook, sessionId: playback.sessionId,
                                                  currentTime: 75, isFinished: false, timeListened: 0)
        let remote = try #require(await provider.fetchAudiobookProgress(for: playingBook))
        #expect(remote.positionSeconds == 75)
        #expect(remote.trackIndex == 1)
    }

    @Test func importsSeriesIndicesFromCurrentAndOlderServers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitCatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = BookOrbitProvider(
            connection: ServerConnection(name: "Fixture", url: "https://bookorbit.invalid", type: .bookOrbit,
                                         token: "fixture-token"),
            session: session
        )
        let expected: [String?] = ["2", "2.5", "2", "2.5", nil, "1–3", "0.50", nil]
        let books = try await provider.fetchBooks(libraryId: "1")
        #expect(books.count == expected.count)
        #expect(books.map { $0.seriesInfo?.sequence } == expected)
        let recent = try await provider.fetchRecentBooks(libraryId: "1", limit: 10)
        #expect(recent.map { $0.seriesInfo?.sequence } == expected.reversed())
        for (book, sequence) in zip(books, expected) {
            let detail = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: "1")
            #expect(detail.seriesInfo?.sequence == sequence)
        }
    }
}
