import Foundation
import Testing

@testable import enve

@MainActor
struct BooklorePlaybackClientTests {
    @Test func fetchMappingUsesInfoEndpointAndTrackURLs() async throws {
        var requestedPath: String?
        let client = Self.makeClient { request in
            requestedPath = request.url?.path
            let data = Data(
                """
                {
                  "bookFileId": 77,
                  "duration": 120,
                  "tracks": [
                    {"index":0,"duration":60,"cumulativeStart":0},
                    {"index":1,"duration":60,"cumulativeStart":60}
                  ]
                }
                """.utf8
            )
            return (data, Self.response(for: request, statusCode: 200))
        }

        let mapping = try await client.fetchMapping(bookId: "42") { index in
            URL(string: "https://example.invalid/audio/\(index)")
        }

        #expect(requestedPath == "/api/v1/audiobooks/42/info")
        #expect(mapping?.bookFileId == 77)
        #expect(mapping?.tracks.map(\.contentUrl) == [
            "https://example.invalid/audio/0",
            "https://example.invalid/audio/1",
        ])
    }

    @Test func downloadTracksAreSortedAndRequireMultipleResolvableURLs() async {
        let client = Self.makeClient { request in
            let data = Data(
                """
                {
                  "tracks": [
                    {"index":2,"mimeType":"audio/aac"},
                    {"index":0,"mimeType":"audio/mpeg"},
                    {"index":1,"mimeType":"audio/mp4"}
                  ]
                }
                """.utf8
            )
            return (data, Self.response(for: request, statusCode: 200))
        }

        let tracks = await client.fetchDownloadTracks(bookId: "42") { index in
            index == 2 ? nil : URL(string: "https://example.invalid/audio/\(index)")
        }

        #expect(tracks?.map { $0.url.lastPathComponent } == ["0", "1"])
        #expect(tracks?.map(\.mimeType) == ["audio/mpeg", "audio/mp4"])
    }

    @Test func nonSuccessInfoResponseReturnsNoMapping() async throws {
        let client = Self.makeClient { request in
            (Data(), Self.response(for: request, statusCode: 404))
        }

        let mapping = try await client.fetchMapping(bookId: "42") { _ in nil }

        #expect(mapping == nil)
    }

    private static func makeClient(
        perform: @escaping BooklorePlaybackClient.AuthorizedRequest
    ) -> BooklorePlaybackClient {
        BooklorePlaybackClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: perform
        )
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
