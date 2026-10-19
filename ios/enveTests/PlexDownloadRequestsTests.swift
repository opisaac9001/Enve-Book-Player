import Foundation
import Testing

@testable import enve

private final class PlexDownloadProviderStub: PlexProvider, @unchecked Sendable {
    var missingPart = false
    var responseStatus = 200
    var requestedPaths: [String] = []

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        requestedPaths.append(url.path)
        let records: [[String: Any]] = ["two", "one"].map { id in
            var record: [String: Any] = ["ratingKey": id, "key": "/library/metadata/\(id)", "title": id, "type": "track"]
            if !missingPart || id != "two" {
                record["Media"] = [["Part": [["key": "/library/parts/\(id)/fresh.mp3"]]]]
            }
            return record
        }
        return (try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": records]]),
            try #require(HTTPURLResponse(url: url, statusCode: responseStatus, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct PlexDownloadRequestsTests {
    @Test func disconnectedFlagAndHomeTokenStillUseExactProviderAndAllFreshTracks() async throws {
        let connection = ServerConnection(name: "Fixture", url: "https://correct-server.invalid", type: .plex,
            token: nil, isConnected: false, plexHomeUserToken: "home-fixture-token")
        let provider = PlexDownloadProviderStub(connection: connection)
        let requests = try await PlexDownloadPlanProvider.requests(for: makeBook(providerID: connection.id), provider: provider)
        #expect(requests.count == 2)
        #expect(provider.requestedPaths == ["/library/metadata/one,two"])
        #expect(requests.map { $0.request.url?.path } == ["/library/parts/one/fresh.mp3", "/library/parts/two/fresh.mp3"])
        #expect(requests.allSatisfy { $0.request.url?.host == "correct-server.invalid" })
        #expect(requests.allSatisfy { $0.request.value(forHTTPHeaderField: "X-Plex-Token") == "home-fixture-token" })
        #expect(requests.allSatisfy { URLComponents(url: $0.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "X-Plex-Token" })?.value == "home-fixture-token" })
    }

    @Test func missingPartRejectsWholeDownloadInsteadOfSavingOneTrack() async {
        let provider = PlexDownloadProviderStub(connection: ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex))
        provider.missingPart = true
        await #expect(throws: (any Error).self) {
            try await PlexDownloadPlanProvider.requests(for: makeBook(providerID: provider.connection.id), provider: provider)
        }
    }

    @Test func serverFailureDoesNotFallBackToStalePartURL() async {
        let provider = PlexDownloadProviderStub(connection: ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex))
        provider.responseStatus = 503
        await #expect(throws: (any Error).self) {
            try await PlexDownloadPlanProvider.requests(for: makeBook(providerID: provider.connection.id), provider: provider)
        }
        #expect(provider.requestedPaths.count == 1)
    }

    @Test func cancelledDownloadDoesNotRequestMetadata() async {
        let provider = PlexDownloadProviderStub(connection: ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PlexDownloadPlanProvider.requests(for: makeBook(providerID: provider.connection.id), provider: provider)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(provider.requestedPaths.isEmpty)
    }

    @Test func shuffledUnequalTracksDownloadInPlaybackTimelineOrder() async throws {
        let provider = PlexDownloadProviderStub(connection: ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex))
        let book = Book(id: "group", title: "Order fixture", audioTracks: [
            AudioTrack(id: "two", index: 1, title: "Two", duration: 70, startOffset: 30, format: "audio/mpeg"),
            AudioTrack(id: "one", index: 0, title: "One", duration: 30, startOffset: 0, format: "audio/mpeg")],
            providerId: provider.connection.id, source: .plex)
        let requests = try await PlexDownloadPlanProvider.requests(for: book, provider: provider)
        #expect(provider.requestedPaths == ["/library/metadata/two,one"])
        #expect(requests.map { $0.request.url?.path } == ["/library/parts/one/fresh.mp3", "/library/parts/two/fresh.mp3"])
    }

    private func makeBook(providerID: UUID) -> Book {
        Book(id: "group", title: "Download fixture", audioTracks: [
            AudioTrack(id: "one", index: 0, title: "One", contentUrl: "https://stale.invalid/old.mp3", duration: 45, startOffset: 0, format: "audio/mpeg"),
            AudioTrack(id: "two", index: 1, title: "Two", contentUrl: "https://stale.invalid/old.mp3", duration: 45, startOffset: 45, format: "audio/mpeg")], providerId: providerID, source: .plex)
    }
}
