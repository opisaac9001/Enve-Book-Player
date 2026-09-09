import Foundation
import Testing

@testable import enve

private final class JellyfinProgressTransportStub: JellyfinProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var status = 200

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data = Data(#"{"Id":"book","Name":"Fixture","Type":"AudioBook","IsFolder":false,"RunTimeTicks":600000000,"Chapters":[{"Name":"One","StartPositionTicks":0},{"Name":"Two","StartPositionTicks":300000000}]}"#.utf8)
        return (data, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct JellyfinProgressTransportTests {
    @Test func audioWritesPersistedUserDataAndReportsServerFailure() async throws {
        let provider = makeProvider()
        let book = Book(id: "book", title: "Fixture", source: .jellyfin, providerId: provider.connection.id)
        try await provider.updatePlaybackProgress(book: book, sessionId: nil, currentTime: 23, isFinished: false, timeListened: 0)
        let request = try #require(provider.requests.last)
        #expect(request.url?.path == "/Users/user/Items/book/UserData")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["PlaybackPositionTicks"] as? Int == 230_000_000)
        #expect(body["Played"] as? Bool == false)
        #expect(body["LastPlayedDate"] as? String != nil)
        provider.status = 500
        await #expect(throws: (any Error).self) {
            try await provider.updatePlaybackProgress(book: book, sessionId: nil, currentTime: 0, isFinished: false, timeListened: 0)
        }
    }

    @Test func leafAudiobooksNeverQueryUnrelatedAudioChildren() async throws {
        let provider = makeProvider()
        let book = Book(id: "book", title: "Fixture", source: .jellyfin, providerId: provider.connection.id)
        let session = try await provider.startPlaybackSession(for: book)
        #expect(session.audioTracks.count == 1)
        #expect(session.audioTracks.first?.duration == 60)
        #expect(URL(string: session.audioTracks.first?.contentUrl ?? "")?.path == "/Audio/book/stream")
        #expect(!provider.requests.contains { $0.url?.path == "/Users/user/Items" })
    }

    private func makeProvider() -> JellyfinProgressTransportStub {
        JellyfinProgressTransportStub(connection: ServerConnection(
            name: "Fixture", url: "https://jellyfin.example.invalid", type: .jellyfin, token: "fixture", userId: "user"
        ))
    }
}
