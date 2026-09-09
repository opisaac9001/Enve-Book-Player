import Foundation
import Testing

@testable import enve

private final class PlexPlaybackTransportStub: PlexProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var status = 200
    var missingPart = false

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let metadata: [[String: Any]] = ["10", "30"].map { id in
            var item: [String: Any] = [
                "ratingKey": id,
                "key": "/library/metadata/\(id)",
                "parentRatingKey": id == "10" ? "album-a" : "album-b",
                "title": "Server title \(id)",
                "type": "track",
                "duration": 999000,
            ]
            if !missingPart || id != "30" {
                item["Media"] = [["Part": [["key": "/library/parts/\(id)/fresh.mp3"]]]]
            }
            return item
        }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": metadata]])
        return (data, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct PlexPlaybackSessionTests {
    @Test func repeatedPlaybackRefreshesCorruptedURLsWithoutChangingGroupedTimeline() async throws {
        let provider = makeProvider()
        let book = makeBook()
        let first = try await provider.startPlaybackSession(for: book)

        #expect(first.audioTracks.map(\.id) == ["30", "10"])
        #expect(first.audioTracks.map(\.index) == [0, 1])
        #expect(first.audioTracks.map(\.startOffset) == [0, 45])
        #expect(first.audioTracks.map(\.duration) == [45, 60])
        #expect(first.audioTracks.map(\.title) == ["Opening", "Closing"])
        #expect(first.audioTracks.map(\.mimeType) == ["audio/mpeg", "audio/mp4"])
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.url?.path == "/library/metadata/30,10")

        for (track, id) in zip(first.audioTracks, ["30", "10"]) {
            let components = try #require(URLComponents(string: track.contentUrl))
            #expect(components.scheme == "https")
            #expect(components.host == "plex.example.invalid")
            #expect(components.path == "/library/parts/\(id)/fresh.mp3")
            #expect(components.queryItems?.filter { $0.name == "X-Plex-Token" }.map(\.value) == ["current-fixture-token"])
            #expect(components.queryItems?.first { $0.name == "download" }?.value == "1")
        }

        let savedTracks = try first.audioTracks.map { track in
            AudioTrack(
                id: try #require(track.id), index: track.index, title: track.title,
                contentUrl: track.contentUrl, duration: track.duration,
                startOffset: track.startOffset, format: track.mimeType
            )
        }
        let savedBook = Book(id: book.id, title: book.title, source: .plex, audioTracks: savedTracks)
        let second = try await provider.startPlaybackSession(for: savedBook)
        #expect(second.audioTracks.map(\.contentUrl) == first.audioTracks.map(\.contentUrl))
        #expect(second.audioTracks.map(\.startOffset) == first.audioTracks.map(\.startOffset))
        #expect(provider.requests.count == 2)
        #expect(provider.requests.allSatisfy { $0.url?.path == "/library/metadata/30,10" })
    }

    @Test func missingPartFailsInsteadOfReturningAnIncompleteTimeline() async {
        let provider = makeProvider()
        provider.missingPart = true
        await #expect(throws: (any Error).self) {
            try await provider.startPlaybackSession(for: makeBook())
        }
    }

    @Test func unsuccessfulMetadataResponseFailsEvenWithDecodableBody() async {
        let provider = makeProvider()
        provider.status = 503
        await #expect(throws: (any Error).self) {
            try await provider.startPlaybackSession(for: makeBook())
        }
    }

    private func makeProvider() -> PlexPlaybackTransportStub {
        PlexPlaybackTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://plex.example.invalid", type: .plex, token: "current-fixture-token"
        ))
    }

    private func makeBook() -> Book {
        Book(id: "grouped-albums", title: "Fixture", source: .plex, audioTracks: [
            AudioTrack(id: "30", index: 0, title: "Opening",
                contentUrl: "https://old.example.invalid/https://old.example.invalid/library/parts/stale/file?X-Plex-Token=stale-fixture",
                duration: 45, startOffset: 0, format: "audio/mpeg"),
            AudioTrack(id: "10", index: 1, title: "Closing",
                contentUrl: "https://old.example.invalid/https://old.example.invalid/https://old.example.invalid/library/parts/stale/file",
                duration: 60, startOffset: 45, format: "audio/mp4"),
        ])
    }
}
