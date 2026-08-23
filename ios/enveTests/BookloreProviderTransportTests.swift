import Foundation
import Testing

@testable import enve

@MainActor
struct BookloreProviderTransportTests {
    @Test func trackProbeRequestsCarryAuthAndCustomHeaders() throws {
        let provider = BookloreProvider(connection: Self.connection())
        let trackURL = try #require(provider.getAudioTrackURL(for: Self.book(), trackIndex: 3))

        let request = provider.makeTrackProbeRequest(url: trackURL)

        #expect(request.httpMethod == "HEAD")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-id")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "CF_Authorization=session")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func trackURLsTargetThePerTrackStreamEndpoint() throws {
        let provider = BookloreProvider(connection: Self.connection())

        let url = try #require(provider.getAudioTrackURL(for: Self.book(), trackIndex: 3))

        #expect(url.path == "/api/v1/audiobooks/42/track/3/stream")
        #expect(url.query?.contains("token=header.payload.signature") == true)
    }

    @Test func companionAudiobookIdsAreUnwrappedBeforeProbing() throws {
        let provider = BookloreProvider(connection: Self.connection())
        let companion = Book(
            id: BookloreProvider.companionAudiobookIDPrefix + "42",
            title: "Probe Fixture",
            source: .booklore,
            providerId: UUID(),
            libraryId: "library-1"
        )

        let url = try #require(provider.getAudioTrackURL(for: companion, trackIndex: 0))

        #expect(url.path == "/api/v1/audiobooks/42/track/0/stream")
    }

    @Test func streamingHeadersForwardCustomHeadersToAVFoundation() {
        let provider = BookloreProvider(connection: Self.connection())

        let headers = provider.getStreamingHeaders()

        #expect(headers["CF-Access-Client-Id"] == "client-id")
        #expect(headers["Cookie"] == "CF_Authorization=session")
    }

    @Test func aConnectionWithoutCustomHeadersStillAuthenticatesTheProbe() throws {
        var connection = Self.connection()
        connection.customHeaders = nil
        let provider = BookloreProvider(connection: connection)
        let trackURL = try #require(provider.getAudioTrackURL(for: Self.book(), trackIndex: 0))

        let request = provider.makeTrackProbeRequest(url: trackURL)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
        #expect(provider.getStreamingHeaders().isEmpty)
    }

    private static func connection() -> ServerConnection {
        ServerConnection(
            name: "fixture",
            url: "books.example.invalid/",
            type: .booklore,
            token: "header.payload.signature",
            customHeaders: [
                "CF-Access-Client-Id": "client-id",
                "Cookie": "CF_Authorization=session",
            ]
        )
    }

    private static func book() -> Book {
        Book(
            id: "42",
            title: "Probe Fixture",
            source: .booklore,
            providerId: UUID(),
            libraryId: "library-1"
        )
    }
}
