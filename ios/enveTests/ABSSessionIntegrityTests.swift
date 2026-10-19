import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized)
struct ABSSessionIntegrityTests {
    @Test func sessionSyncForAnotherBookIsDroppedWithoutReachingTheServer() async throws {
        let fixture = try ABSSessionFixture()
        defer { fixture.remove() }
        _ = try await fixture.sessions.startABSSession(for: fixture.bookA, startTime: 0)
        ABSSessionProtocol.reset()

        let dropped = await fixture.sessions.syncABSSession(
            for: fixture.bookB, progress: 500, duration: 3_600, timeListened: 15
        )
        #expect(dropped)
        #expect(ABSSessionProtocol.requests.isEmpty)
        #expect(fixture.sessions.ownsABSSession(for: fixture.bookA))
        #expect(!fixture.sessions.ownsABSSession(for: fixture.bookB))
        #expect(!fixture.sessions.ownsABSSession(for: nil))

        _ = await fixture.sessions.syncABSSession(for: fixture.bookA, progress: 500, duration: 3_600, timeListened: 15)
        #expect(ABSSessionProtocol.requests == ["POST /api/session/s1/sync"])
        await fixture.close()
    }

    @Test func closingWithAnotherBookForgetsTheSessionWithoutWritingProgress() async throws {
        let fixture = try ABSSessionFixture()
        defer { fixture.remove() }
        _ = try await fixture.sessions.startABSSession(for: fixture.bookA, startTime: 0)
        ABSSessionProtocol.reset()

        await fixture.sessions.closeABSSession(for: fixture.bookB, progress: 500, duration: 3_600)
        #expect(ABSSessionProtocol.requests.isEmpty)
        #expect(fixture.sessions.currentABSSessionId == nil)
        await fixture.close()
    }

    @Test func readOnlyStreamLeavesTheMainSessionUntouched() async throws {
        let fixture = try ABSSessionFixture()
        defer { fixture.remove() }
        _ = try await fixture.sessions.startABSSession(for: fixture.bookA, startTime: 0)
        ABSSessionProtocol.reset()

        let url = try #require(try await fixture.resolver.streamURL(for: fixture.bookB, opensABSSession: false))
        #expect(url.path == "/api/items/li_b/file/ino_b/download")
        #expect(ABSSessionProtocol.requests.isEmpty)
        #expect(fixture.sessions.currentABSSessionId == "s1")
        #expect(fixture.sessions.ownsABSSession(for: fixture.bookA))
        #expect(!fixture.progress.absSessionActive)
        await fixture.close()
    }

    @Test func readOnlyStreamLooksUpFileInodesWithoutOpeningASession() async throws {
        let fixture = try ABSSessionFixture()
        defer { fixture.remove() }
        let book = Book(id: "li_c", title: "No inode", partKey: "li_c", libraryId: "library",
            providerId: fixture.connection.id, backendId: fixture.connection.id.uuidString)

        let url = try #require(try await fixture.resolver.streamURL(for: book, opensABSSession: false))
        #expect(url.path == "/api/items/li_c/file/ino_c/download")
        #expect(ABSSessionProtocol.requests == ["GET /api/items/li_c"])
        #expect(fixture.sessions.currentABSSessionId == nil)
        await fixture.close()
    }
}

@MainActor
private final class ABSSessionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "ABSSessionIntegrityTests.\(UUID().uuidString)"
    let session: ProfileSession
    let connection: ServerConnection
    let urlSession: URLSession
    let sessions: PlayerSessionService
    let progress: PlayerProgressService
    let resolver: PlayerStreamURLResolver
    let bookA: Book
    let bookB: Book

    init() throws {
        ABSSessionProtocol.reset()
        let profile = FamilyProfile(id: UUID().uuidString, name: "Session fixture", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "profileServerSyncEnabled")
        session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ABSSessionProtocol.self]
        urlSession = URLSession(configuration: configuration)
        session.networkSession = urlSession
        connection = ServerConnection(name: "Session fixture", url: "https://example.test",
            type: .audiobookshelf, token: "legacyfixturetoken", isConnected: true)
        session.providerConnections.connections = [connection]
        let abs = AudiobookshelfService(session: urlSession)
        sessions = PlayerSessionService(audiobookshelfService: abs, providerConnections: session.providerConnections,
            serverSyncEnabled: { true })
        progress = PlayerProgressService(audiobookshelfService: abs, providerConnections: session.providerConnections,
            profileSession: session)
        resolver = PlayerStreamURLResolver(audiobookshelfService: abs, providerConnections: session.providerConnections,
            sessionService: sessions, progressService: progress, profileSession: session)
        bookA = Book(id: "li_a", title: "Playing", partKey: "li_a", audioFileIno: "ino_a", libraryId: "library",
            providerId: connection.id, backendId: connection.id.uuidString)
        bookB = Book(id: "li_b", title: "Previewed", partKey: "li_b", audioFileIno: "ino_b", audioFileInos: ["ino_b"],
            libraryId: "library", providerId: connection.id, backendId: connection.id.uuidString)
    }

    func close() async {
        await session.retire()
    }

    func remove() {
        urlSession.invalidateAndCancel()
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

nonisolated private final class ABSSessionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []
    static var requests: [String] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    static func reset() {
        lock.lock(); recorded = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recorded.append("\(request.httpMethod ?? "GET") \(url.path)")
        Self.lock.unlock()
        if url.path.hasSuffix("/play") {
            return respond("""
                {"id":"s1","userId":"user-a","libraryItemId":"li_a","currentTime":0,"chapters":[],
                 "audioTracks":[{"index":0,"startOffset":0,"duration":30,"contentUrl":"/s/a.mp3","mimeType":"audio/mpeg"}]}
                """)
        }
        if url.path == "/api/items/li_c" {
            return respond("""
                {"id":"li_c","libraryId":"library","media":{"audioFiles":[
                  {"index":2,"ino":"ino_c2"},{"index":0,"ino":"ino_excluded","exclude":true},{"index":1,"ino":"ino_c"}]}}
                """)
        }
        respond("{}")
    }

    override func stopLoading() {}

    private func respond(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
