import Foundation
import Testing

@testable import enve

private enum PlexProgressFixtureError: Error { case transport }

private final class PlexProgressTransportStub: PlexProvider, @unchecked Sendable {
    var requestedIDs: [[String]] = []
    var metadata: [String: [String: Any]] = [:]
    var omittedID: String?
    var duplicateItems: [[String: Any]] = []
    var failingRequest: Int?
    var throwsTransportError = false
    var cancelsRequest: Int?

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let ids = url.lastPathComponent.split(separator: ",").map(String.init)
        requestedIDs.append(ids)
        if throwsTransportError { throw PlexProgressFixtureError.transport }
        let items = ids.reversed().compactMap { id in
            id == omittedID ? nil : metadata[id]
        }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": items + duplicateItems]])
        if requestedIDs.count == cancelsRequest {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let status = requestedIDs.count == failingRequest ? 503 : 200
        return (data, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct PlexProgressBatchingTests {
    @Test(arguments: [1, 40, 101])
    func batchesTrackMetadataAndMapsShuffledResponsesToTimeline(trackCount: Int) async throws {
        let provider = makeProvider()
        let book = makeBook(trackCount: trackCount)
        for index in 0..<trackCount {
            provider.metadata[String(index)] = item(id: String(index), offset: index == trackCount - 1 ? 2_000 : 0,
                                                   viewedAt: index + 1)
        }

        let result = try #require(await provider.fetchAudiobookProgress(for: book))

        #expect(provider.requestedIDs.count == (trackCount + 99) / 100)
        #expect(provider.requestedIDs.allSatisfy { $0.count <= 100 })
        #expect(provider.requestedIDs.flatMap { $0 } == (0..<trackCount).map(String.init))
        #expect(result.positionSeconds == Double(trackCount - 1) * 10 + 2)
        #expect(result.percentage == result.positionSeconds / Double(trackCount * 10))
        #expect(result.updatedAt == Date(timeIntervalSince1970: Double(trackCount)))
        #expect(!result.isFinished)
    }

    @Test func singleFileWithoutStoredTracksUsesMetadataDuration() async throws {
        let provider = makeProvider()
        provider.metadata["album"] = item(id: "album", offset: 15_000, viewedAt: 1, duration: 120_000)
        let book = Book(id: "album", title: "Fixture", source: .plex)

        let result = try #require(await provider.fetchAudiobookProgress(for: book))

        #expect(provider.requestedIDs == [["album"]])
        #expect(result.positionSeconds == 15)
        #expect(result.percentage == 0.125)
        #expect(!result.isFinished)
    }

    @Test func missingTrackDoesNotReturnAnotherTracksProgress() async {
        let provider = makeProvider()
        let book = makeBook(trackCount: 40)
        populate(provider, trackCount: 40)
        provider.omittedID = "39"

        await #expect(throws: (any Error).self) {
            try await provider.fetchAudiobookProgress(for: book)
        }
        #expect(provider.requestedIDs.count == 1)
    }

    @Test func completedTracksUseFullDurationWithoutAlbumFallback() async throws {
        let provider = makeProvider()
        for index in 0..<40 {
            provider.metadata[String(index)] = item(id: String(index), finished: true)
        }

        let result = try #require(await provider.fetchAudiobookProgress(for: makeBook(trackCount: 40)))

        #expect(result.isFinished)
        #expect(result.positionSeconds == 400)
        #expect(result.percentage == 1)
        #expect(provider.requestedIDs.count == 1)
    }

    @Test func latestViewedTrackWinsOverResponseOrderAndHigherPosition() async throws {
        let provider = makeProvider()
        provider.metadata["0"] = item(id: "0", offset: 3_000, viewedAt: 20)
        provider.metadata["1"] = item(id: "1", offset: 8_000, viewedAt: 10)

        let result = try #require(await provider.fetchAudiobookProgress(for: makeBook(trackCount: 2)))

        #expect(result.positionSeconds == 3)
        #expect(result.updatedAt == Date(timeIntervalSince1970: 20))
    }

    @Test(arguments: [false, true])
    func firstDuplicateRecordPreservesRewindAndCompletion(finished: Bool) async throws {
        let provider = makeProvider()
        provider.metadata["0"] = item(id: "0", offset: finished ? 0 : 3_000, viewedAt: 20, finished: finished)
        provider.duplicateItems = [item(id: "0", offset: 8_000, viewedAt: 10)]

        let result = try #require(await provider.fetchAudiobookProgress(for: makeBook(trackCount: 1)))

        #expect(result.positionSeconds == (finished ? 10 : 3))
        #expect(result.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(result.isFinished == finished)
        #expect(provider.requestedIDs == [["0"]])
    }

    @Test func undatedTrackProgressKeepsTimelineOrder() async throws {
        let provider = makeProvider()
        provider.metadata["0"] = item(id: "0", offset: 3_000)
        provider.metadata["1"] = item(id: "1", offset: 8_000)

        let result = try #require(await provider.fetchAudiobookProgress(for: makeBook(trackCount: 2)))

        #expect(result.positionSeconds == 3)
        #expect(result.updatedAt == .distantPast)
        #expect(provider.requestedIDs.count == 1)
    }

    @Test func absentTrackProgressPreservesAlbumFallback() async throws {
        let provider = makeProvider()
        populate(provider, trackCount: 2)
        provider.metadata["album"] = item(id: "album", offset: 4_500, viewedAt: 7)

        let result = try #require(await provider.fetchAudiobookProgress(for: makeBook(trackCount: 2)))

        #expect(provider.requestedIDs == [["0", "1"], ["album"]])
        #expect(result.positionSeconds == 4.5)
        #expect(result.percentage == 0.225)
        #expect(result.updatedAt == Date(timeIntervalSince1970: 7))
        #expect(!result.isFinished)
    }

    @Test func secondBatchFailureDoesNotReturnPartialProgress() async {
        let provider = makeProvider()
        populate(provider, trackCount: 101)
        provider.failingRequest = 2

        await #expect(throws: (any Error).self) {
            try await provider.fetchAudiobookProgress(for: makeBook(trackCount: 101))
        }
        #expect(provider.requestedIDs.count == 2)
    }

    @Test func transportFailureStopsBeforeNextBatch() async {
        let provider = makeProvider()
        provider.throwsTransportError = true

        await #expect(throws: PlexProgressFixtureError.self) {
            try await provider.fetchAudiobookProgress(for: makeBook(trackCount: 101))
        }
        #expect(provider.requestedIDs.count == 1)
    }

    @Test func cancellationBeforeFirstBatchSendsNoRequest() async {
        let provider = makeProvider()
        let book = makeBook(trackCount: 101)
        let task = Task { try await provider.fetchAudiobookProgress(for: book) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.requestedIDs.isEmpty)
    }

    @Test(arguments: [1, 2])
    func cancellationAfterResponseStopsNextBatchOrAlbumFallback(requestNumber: Int) async {
        let provider = makeProvider()
        populate(provider, trackCount: 101)
        provider.cancelsRequest = requestNumber
        let book = makeBook(trackCount: 101)
        let task = Task { try await provider.fetchAudiobookProgress(for: book) }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.requestedIDs.count == requestNumber)
    }

    @Test func cancellationAfterAlbumFallbackDoesNotReturnProgress() async {
        let provider = makeProvider()
        populate(provider, trackCount: 1)
        provider.metadata["album"] = item(id: "album", offset: 5_000)
        provider.cancelsRequest = 2
        let book = makeBook(trackCount: 1)
        let task = Task { try await provider.fetchAudiobookProgress(for: book) }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.requestedIDs == [["0"], ["album"]])
    }

    private func makeProvider() -> PlexProgressTransportStub {
        PlexProgressTransportStub(connection: ServerConnection(name: "Fixture", url: "https://plex.example.invalid", type: .plex))
    }

    private func makeBook(trackCount: Int) -> Book {
        let tracks = (0..<trackCount).reversed().map { index in
            AudioTrack(id: String(index), index: index, title: "Track \(index)",
                       contentUrl: "https://plex.example.invalid/audio/\(index)", duration: 10,
                       startOffset: Double(index * 10), format: "mp3")
        }
        return Book(id: "album", title: "Fixture", duration: Double(trackCount * 10), source: .plex, audioTracks: tracks)
    }

    private func populate(_ provider: PlexProgressTransportStub, trackCount: Int) {
        for index in 0..<trackCount {
            provider.metadata[String(index)] = item(id: String(index))
        }
    }

    private func item(id: String, offset: Int = 0, viewedAt: Int? = nil, finished: Bool = false,
                      duration: Int = 10_000) -> [String: Any] {
        var result: [String: Any] = ["ratingKey": id, "key": "/library/metadata/\(id)", "title": "Fixture", "type": "track", "duration": duration,
                                    "viewOffset": offset, "viewCount": finished ? 1 : 0]
        if let viewedAt { result["lastViewedAt"] = viewedAt }
        return result
    }
}
