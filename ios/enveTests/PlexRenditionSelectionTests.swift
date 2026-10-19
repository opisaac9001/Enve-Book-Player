import Foundation
import Testing

@testable import enve

private final class PlexRenditionStub: PlexProvider, @unchecked Sendable {
    static let album: [String: Any] = [
        "ratingKey": "album-1", "key": "/library/metadata/album-1", "title": "Fixture Album", "type": "album",
    ]
    static let tracks: [[String: Any]] = [
        track("21", disc: 2, index: 1, media: [
            ["container": "ogg", "audioCodec": "opus", "duration": 50000,
             "Part": [["key": "/library/parts/21/a.ogg", "container": "ogg", "duration": 50000]]],
            ["container": "mp3", "audioCodec": "mp3", "duration": 40000,
             "Part": [["key": "/library/parts/21/b.mp3", "container": "mp3", "duration": 40000]]],
        ]),
        track("12", disc: 1, index: 2, media: [
            ["container": "mp3", "duration": 30000, "Part": [["key": "/library/parts/12/c.mp3"]]],
        ]),
        track("11", disc: 1, index: 1, media: [
            ["container": "m4b", "audioCodec": "aac", "duration": 20000, "Part": [["key": "/library/parts/11/d.m4b"]]],
        ]),
    ]

    private static func track(_ id: String, disc: Int, index: Int, media: [[String: Any]]) -> [String: Any] {
        ["ratingKey": id, "key": "/library/metadata/\(id)", "parentRatingKey": "album-1", "title": "Track \(id)",
         "type": "track", "parentIndex": disc, "index": index, "duration": 50000, "Media": media]
    }

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let metadata: [[String: Any]]
        if url.path.hasSuffix("/children") {
            metadata = Self.tracks
        } else {
            let ids = Set(url.lastPathComponent.split(separator: ",").map(String.init))
            metadata = ids.contains("album-1") ? [Self.album] : Self.tracks.filter { ids.contains($0["ratingKey"] as? String ?? "") }
        }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": metadata]])
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private struct TrackSignature: Equatable {
    let id: String?
    let startOffset: Double
    let duration: Double?
    let mimeType: String?
    let path: String?
    let query: Set<URLQueryItem>
}

@MainActor
struct PlexRenditionSelectionTests {
    @Test func freshAlbumSessionAndDownloadPlanMatchTheStoredSession() async throws {
        let provider = makeProvider()
        let stored = try catalogBook(provider: provider, trackIDs: ["21", "12", "11"])
        #expect(stored.audioTracks?.map(\.id) == ["11", "12", "21"])

        let storedSession = try await provider.startPlaybackSession(for: stored)
        let freshSession = try await provider.startPlaybackSession(
            for: Book(id: "album-1", title: "Fixture Album", source: .plex)
        )
        let downloads = try await PlexDownloadPlanProvider.requests(
            for: Book(id: "album-1", title: "Fixture Album", source: .plex), provider: provider
        )

        let expected = storedSession.audioTracks.map(signature)
        #expect(expected.map(\.id) == ["11", "12", "21"])
        #expect(expected.map(\.startOffset) == [0, 20, 50])
        #expect(expected.map(\.duration) == [20, 30, 40])
        #expect(expected.map(\.mimeType) == ["audio/mp4", "audio/mpeg", "audio/mpeg"])
        #expect(expected.map(\.path) == ["/library/parts/11/d.m4b", "/library/parts/12/c.mp3", "/library/parts/21/b.mp3"])
        #expect(storedSession.audioTracks.map(\.index) == freshSession.audioTracks.map(\.index))
        #expect(freshSession.audioTracks.map(signature) == expected)

        let downloadSignatures = downloads.map { download in
            let components = download.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            return TrackSignature(id: nil, startOffset: 0, duration: nil, mimeType: download.mimeType,
                path: components?.path, query: Set(components?.queryItems ?? []))
        }
        #expect(downloadSignatures == expected.map {
            TrackSignature(id: nil, startOffset: 0, duration: nil, mimeType: $0.mimeType, path: $0.path, query: $0.query)
        })
    }

    @Test func unsupportedFirstVersionFallsBackToPlayableMp3InCatalogAndSession() async throws {
        let provider = makeProvider()
        let catalog = try catalogBook(provider: provider, trackIDs: ["21"])
        #expect(catalog.audioTracks?.map(\.format) == ["audio/mpeg"])
        #expect(catalog.audioTracks?.map(\.contentUrl) == ["/library/parts/21/b.mp3"])
        #expect(catalog.audioTracks?.map(\.duration) == [40])
        #expect(catalog.partKey == "/library/parts/21/b.mp3")

        let session = try await provider.startPlaybackSession(for: Book(id: "21", title: "Track 21", source: .plex))
        let track = try #require(session.audioTracks.first)
        #expect(session.audioTracks.count == 1)
        #expect(track.mimeType == "audio/mpeg")
        #expect(track.duration == 40)
        #expect(URLComponents(string: track.contentUrl)?.path == "/library/parts/21/b.mp3")
    }

    private func catalogBook(provider: PlexProvider, trackIDs: [String]) throws -> Book {
        let decode = { (fields: [String: Any]) in
            try JSONDecoder().decode(PlexProvider.PlexMetadata.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let tracks = try trackIDs.map { id in
            try decode(try #require(PlexRenditionStub.tracks.first { $0["ratingKey"] as? String == id }))
        }
        return try #require(provider.mapPlexAlbum(try decode(PlexRenditionStub.album), tracks: tracks, libraryId: "library").first)
    }

    private func signature(_ track: AudioTrackInfo) -> TrackSignature {
        let components = URLComponents(string: track.contentUrl)
        return TrackSignature(id: track.id, startOffset: track.startOffset, duration: track.duration,
            mimeType: track.mimeType, path: components?.path, query: Set(components?.queryItems ?? []))
    }

    private func makeProvider() -> PlexRenditionStub {
        PlexRenditionStub(connection: ServerConnection(
            name: "Fixture", url: "https://plex.example.invalid", type: .plex, token: "rendition-fixture-token"
        ))
    }
}
