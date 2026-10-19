import Foundation
import Testing
import WatchConnectivity

@testable import enve

@MainActor
@Suite(.serialized)
struct WatchABSSessionTests {
    @Test(arguments: ["li_playing", "li_other"])
    func watchStreamDoesNotReopenThePhonesABSSession(watchItem: String) async throws {
        let fixture = try WatchABSFixture()
        defer { fixture.remove() }
        let playing = fixture.book("li_playing")
        let requested = fixture.book(watchItem)
        await fixture.session.bookStore.upsertBooks([playing, requested])

        _ = try await fixture.provider.startPlaybackSession(for: playing)
        let phonePlay = try #require(WatchABSProtocol.plays.first)
        #expect(WatchABSProtocol.plays.count == 1)

        let bridge = WatchSessionBridge(
            providerResolver: fixture,
            bookQuerying: fixture.session.bookStore, libraryCache: fixture.session.appState.libraryCache,
            playback: fixture.session.playback.composition.controller, profileSession: fixture.session
        )
        let descriptor = try #require(await fixture.descriptor(from: bridge, stableId: requested.stableId))

        #expect(!descriptor.tracks.isEmpty)
        let reopened = WatchABSProtocol.plays.dropFirst().filter { $0.deviceId == phonePlay.deviceId }
        #expect(reopened.isEmpty, "Watch POSTed /play as \(reopened.map(\.path)) with the phone's device id")
        await bridge.retire()
        await fixture.close()
    }
}

@MainActor
private final class WatchABSFixture: LibraryProviderResolving {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "WatchABSSessionTests.\(UUID().uuidString)"
    let session: ProfileSession
    let connection: ServerConnection
    let provider: AudiobookshelfProvider
    let urlSession: URLSession

    init() throws {
        WatchABSProtocol.reset()
        let profile = FamilyProfile(id: UUID().uuidString, name: "Watch fixture", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "profileServerSyncEnabled")
        session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchABSProtocol.self]
        urlSession = URLSession(configuration: configuration)
        session.networkSession = urlSession
        connection = ServerConnection(name: "Watch fixture", url: "https://example.test",
            type: .audiobookshelf, token: "legacyfixturetoken", isConnected: true)
        session.providerConnections.connections = [connection]
        provider = AudiobookshelfProvider(connection: connection, profileSession: session)
    }

    func provider(for providerId: UUID) -> LibraryProvider? { provider }
    func provider(for book: Book) -> LibraryProvider? { provider }

    func book(_ itemId: String) -> Book {
        Book(id: itemId, title: itemId, partKey: itemId, duration: 60, source: .audiobookshelf,
            backendId: connection.id.uuidString, providerId: connection.id, libraryId: "library")
    }

    func descriptor(from bridge: WatchSessionBridge, stableId: String) async -> WatchPlaybackDescriptor? {
        let message = WatchWire.envelope(.requestDescriptor, WatchDescriptorRequest(stableId: stableId))
        let data: Data? = await withCheckedContinuation { continuation in
            bridge.session(WCSession.default, didReceiveMessage: message) { reply in
                continuation.resume(returning: reply[WatchWire.dataKey] as? Data)
            }
        }
        return data.flatMap { try? JSONDecoder().decode(WatchPlaybackDescriptor.self, from: $0) }
    }

    func close() async {
        await provider.retire()
        await session.retire()
    }

    func remove() {
        urlSession.invalidateAndCancel()
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

nonisolated private final class WatchABSProtocol: URLProtocol, @unchecked Sendable {
    struct Play: Sendable { let path: String; let deviceId: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Play] = []
    static var plays: [Play] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    static func reset() {
        lock.lock(); recorded = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let item = url.pathComponents.dropFirst(3).first ?? ""
        if request.httpMethod == "POST", url.path.hasSuffix("/play") {
            let body = (try? JSONSerialization.jsonObject(with: bodyData())) as? [String: Any]
            let deviceId = (body?["deviceInfo"] as? [String: Any])?["deviceId"] as? String
            Self.lock.lock()
            Self.recorded.append(Play(path: url.path, deviceId: deviceId))
            Self.lock.unlock()
            return respond("""
                {"id":"session-\(item)","userId":"user-a","currentTime":0,"chapters":[],
                 "audioTracks":[{"index":0,"startOffset":0,"duration":60,"contentUrl":"/api/items/\(item)/file/ino-\(item)","mimeType":"audio/mpeg"}]}
                """)
        }
        if url.path == "/api/items/\(item)" {
            return respond("""
                {"id":"\(item)","libraryId":"library","media":{"metadata":{"title":"\(item)"},
                 "audioFiles":[{"index":0,"ino":"ino-\(item)","duration":60,"metadata":{"filename":"a.mp3"}}]}}
                """)
        }
        respond("{}")
    }

    override func stopLoading() {}

    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
