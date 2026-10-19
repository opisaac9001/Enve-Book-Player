import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized)
struct ABSListeningAttributionTests {
    @Test(arguments: [
        ("offline", true), ("unreachable", true), ("rejected", true),
        ("timeout", false), ("lost", false), ("server-error", false),
    ])
    func failedSessionSyncQueuesListeningOnlyWhenTheServerCannotHaveAppliedIt(scenario: String, queued: Bool) async throws {
        let fixture = try ABSListeningFixture(scenario: scenario)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await fixture.provider.updatePlaybackProgress(
                book: fixture.book, sessionId: "s1", currentTime: 100, isFinished: false, timeListened: 30
            )
        }
        let pending = fixture.session.listeningStore.pendingUploads(connectionId: fixture.connection.id)
        #expect(pending.map(\.timeListening) == (queued ? [30] : []))
        await fixture.close()
    }

    @Test func playbackSessionTeachesTheListenerAccountForOfflineEntries() async throws {
        let fixture = try ABSListeningFixture(scenario: "offline")
        defer { fixture.remove() }
        _ = try await fixture.provider.startPlaybackSession(for: fixture.book)
        try? await fixture.provider.updatePlaybackProgress(
            book: fixture.book, sessionId: "s1", currentTime: 100, isFinished: false, timeListened: 30
        )
        let pending = fixture.session.listeningStore.pendingUploads(connectionId: fixture.connection.id)
        #expect(pending.map(\.ownerAccountId) == ["user-a"])
        #expect(pending.first?.accountId == nil)
        await fixture.close()
    }

    @Test func uploadSendsOnlyTheSignedInUsersListening() async throws {
        let fixture = try ABSListeningFixture(scenario: "upload")
        defer { fixture.remove() }
        let store = fixture.session.listeningStore
        store.rememberAccount("user-b", connectionId: fixture.connection.id)
        record(store, connection: fixture.connection.id, item: "li_b", seconds: 20)
        store.rememberAccount("user-a", connectionId: fixture.connection.id)
        record(store, connection: fixture.connection.id, item: "li_a", seconds: 40)

        let uploaded = await fixture.provider.flushHistorySessions()
        #expect(uploaded.count == 1)
        #expect(ABSListeningProtocol.uploadedItemIds == ["li_a"])
        #expect(store.pendingUploads(connectionId: fixture.connection.id).map(\.libraryItemId) == ["li_b"])
        await fixture.close()
    }

    @Test func sessionSyncThatNeverLeftTheDeviceKeepsItsListeningTime() async throws {
        for (scenario, delivered) in [("offline", false), ("timeout", true), ("upload", true)] {
            let fixture = try ABSListeningFixture(scenario: scenario)
            defer { fixture.remove() }
            let service = PlayerSessionService(
                audiobookshelfService: AudiobookshelfService(session: fixture.urlSession),
                providerConnections: fixture.session.providerConnections,
                serverSyncEnabled: { true }
            )
            _ = try await service.startABSSession(for: fixture.book, startTime: 0)
            let result = await service.syncABSSession(for: fixture.book, progress: 100, duration: 3_600, timeListened: 30)
            #expect(result == delivered, "\(scenario)")
            await fixture.close()
        }
    }

    @Test func entriesRecordedBeforeAnyAccountIsKnownBelongToTheFirstVerifiedAccount() {
        let store = ABSLocalListeningStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let connection = UUID()
        record(store, connection: connection, item: "li_1", seconds: 15)
        #expect(store.hasUploadCandidates(connectionId: connection))
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-a").isEmpty)

        store.rememberAccount("user-a", connectionId: connection)
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-a").map(\.timeListening) == [15])

        store.rememberAccount("user-b", connectionId: connection)
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-b").isEmpty)
        #expect(!store.hasUploadCandidates(connectionId: connection))
        record(store, connection: connection, item: "li_1", seconds: 5)
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-b").map(\.timeListening) == [5])
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-a").map(\.timeListening) == [15])
    }

    @Test func legacyStoredSessionsDecodeWithoutAnOwner() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connection = UUID()
        let legacy = """
            [{"id":"legacy","connectionId":"\(connection.uuidString)","libraryItemId":"li_1","displayTitle":"T",
              "day":"2026-10-01","dayOfWeek":"Thursday","duration":3600,"timeListening":12,"currentTime":50,
              "startedAt":1790000000000,"updatedAt":1790000012000,"needsUpload":true}]
            """
        defaults.set(Data(legacy.utf8), forKey: "absLocalListeningSessions.v1")
        let store = ABSLocalListeningStore(defaults: defaults)
        let session = try #require(store.pendingUploads(connectionId: connection).first)
        #expect(session.ownerAccountId == nil)
        store.rememberAccount("user-a", connectionId: connection)
        #expect(store.pendingUploads(connectionId: connection, verifiedAccountId: "user-a").map(\.id) == ["legacy"])
    }

    @Test func onlyPreRequestTransportFailuresCountAsUndelivered() {
        #expect(AudiobookshelfProvider.requestNeverReachedServer(URLError(.notConnectedToInternet)))
        #expect(AudiobookshelfProvider.requestNeverReachedServer(URLError(.cannotConnectToHost)))
        #expect(AudiobookshelfProvider.requestNeverReachedServer(URLError(.serverCertificateUntrusted)))
        #expect(!AudiobookshelfProvider.requestNeverReachedServer(URLError(.timedOut)))
        #expect(!AudiobookshelfProvider.requestNeverReachedServer(URLError(.networkConnectionLost)))
        #expect(!AudiobookshelfProvider.requestNeverReachedServer(URLError(.cancelled)))
        #expect(!AudiobookshelfProvider.requestNeverReachedServer(ProviderError.invalidResponse))
    }

    private func record(_ store: ABSLocalListeningStore, connection: UUID, item: String, seconds: TimeInterval) {
        store.record(
            connectionId: connection, libraryItemId: item, episodeId: nil, displayTitle: "Title",
            displayAuthor: nil, duration: 3_600, currentTime: 120, listened: seconds
        )
    }
}

@MainActor
private final class ABSListeningFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "ABSListeningAttributionTests.\(UUID().uuidString)"
    let session: ProfileSession
    let connection: ServerConnection
    let provider: AudiobookshelfProvider
    let urlSession: URLSession
    let book: Book

    init(scenario: String) throws {
        ABSListeningProtocol.uploadedItemIds = []
        let profile = FamilyProfile(id: UUID().uuidString, name: "Listening fixture", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "profileServerSyncEnabled")
        session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ABSListeningProtocol.self]
        urlSession = URLSession(configuration: configuration)
        session.networkSession = urlSession
        connection = ServerConnection(name: "Listening fixture", url: "https://example.test/\(scenario)",
            type: .audiobookshelf, token: "legacyfixturetoken", isConnected: true)
        session.providerConnections.connections = [connection]
        provider = AudiobookshelfProvider(connection: connection, profileSession: session)
        var book = Book(id: "li_1", title: "Fixture", author: "Author", narrator: nil, source: .audiobookshelf,
            backendId: connection.id.uuidString, providerId: connection.id, libraryId: "library")
        book.duration = 3_600
        self.book = book
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

nonisolated private final class ABSListeningProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var uploaded: [String] = []
    static var uploadedItemIds: [String] {
        get { lock.lock(); defer { lock.unlock() }; return uploaded }
        set { lock.lock(); uploaded = newValue; lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        if path.hasSuffix("/sync") {
            switch path {
            case let p where p.contains("/offline/"): return fail(.notConnectedToInternet)
            case let p where p.contains("/unreachable/"): return fail(.cannotConnectToHost)
            case let p where p.contains("/timeout/"): return fail(.timedOut)
            case let p where p.contains("/lost/"): return fail(.networkConnectionLost)
            case let p where p.contains("/server-error/"): return respond(503, "{}")
            case let p where p.contains("/rejected/"): return respond(403, "{}")
            default: return respond(200, "{}")
            }
        }
        if path.hasSuffix("/play") {
            return respond(200, """
                {"id":"s1","userId":"user-a","libraryItemId":"li_1","currentTime":0,"chapters":[],
                 "audioTracks":[{"index":0,"startOffset":0,"duration":30,"contentUrl":"/s/a.mp3","mimeType":"audio/mpeg"}]}
                """)
        }
        if path.hasSuffix("/api/me") { return respond(200, #"{"id":"user-a"}"#) }
        if path.hasSuffix("/api/session/local-all") {
            let body = bodyData()
            let sessions = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
            Self.uploadedItemIds += sessions.compactMap { $0["libraryItemId"] as? String }
            let results = sessions.compactMap { $0["id"] as? String }.map { ["id": $0, "success": true] }
            return respond(200, String(decoding: try! JSONSerialization.data(withJSONObject: ["results": results]), as: UTF8.self))
        }
        respond(200, "{}")
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

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
