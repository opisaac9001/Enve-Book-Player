import Foundation
import Testing

@testable import enve

nonisolated private final class PlexConnectionProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(Int, String)
        case failure(URLError.Code)
        case stalled
        case transientFailure(URLError.Code, String)
        case heldResponse(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var held: [(PlexConnectionProtocol, String)] = []

    static func reset(_ replies: [String: Reply]) {
        lock.withLock {
            self.replies = replies
            captured = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { captured } }
    static var hasHeldResponses: Bool { lock.withLock { !held.isEmpty } }

    static func releaseResponses() {
        let responses = lock.withLock {
            let responses = held
            held = []
            return responses
        }
        for (operation, body) in responses { operation.respond(status: 200, body: body) }
    }

    private func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.captured.append(request)
            let key = request.url!.host! + request.url!.path
            return Self.replies[key] ?? .failure(.cannotConnectToHost)
        }
        switch reply {
        case .response(let status, let body):
            respond(status: status, body: body)
        case .heldResponse(let body):
            Self.lock.withLock { Self.held.append((self, body)) }
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .stalled:
            break
        case .transientFailure(let code, let body):
            Self.lock.withLock {
                Self.replies[request.url!.host! + request.url!.path] = .response(200, body)
            }
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlexConnectionRecoveryTests {
    private let endpoints: [PlexConnection] = [
        PlexConnection(uri: "https://relay.example.invalid", local: false, protocol: "https", address: nil, port: nil, relay: true),
        PlexConnection(uri: "https://remote.example.invalid", local: false, protocol: "https", address: nil, port: nil, relay: false),
        PlexConnection(uri: "http://local-http.example.invalid", local: true, protocol: "http", address: nil, port: nil, relay: false),
        PlexConnection(uri: "https://local.example.invalid", local: true, protocol: "https", address: nil, port: nil, relay: false),
    ]

    private func session(_ replies: [String: PlexConnectionProtocol.Reply]) -> URLSession {
        var replies = replies
        for key in Array(replies.keys) where key.hasSuffix("/library/sections") {
            let identityKey = String(key.dropLast("/library/sections".count)) + "/identity"
            if replies[identityKey] == nil {
                replies[identityKey] = .response(200, #"{"MediaContainer":{"machineIdentifier":"selected-server"}}"#)
            }
        }
        PlexConnectionProtocol.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexConnectionProtocol.self]
        return URLSession(configuration: config)
    }

    private func server() -> PlexServer {
        PlexServer(id: "selected-server", name: "Fixture", uri: "", local: true, httpsRequired: false,
                   owned: true, synced: false, accessToken: "selected-user-token", connections: endpoints)
    }

    private func connection() -> ServerConnection {
        var connection = ServerConnection(name: "Fixture", url: "https://remote.example.invalid", type: .plex, token: "server-token")
        connection.plexOwnerToken = "account-token"
        connection.plexHomeUserToken = "selected-user-token"
        connection.plexHomeUserId = "managed-user"
        return connection
    }

    private let resources = """
        <MediaContainer>
          <Device name="Other server" clientIdentifier="other-server" provides="server" owned="1" accessToken="other-token">
            <Connection uri="https://other.example.invalid" local="0" protocol="https" relay="0" />
          </Device>
          <Device name="Fixture" clientIdentifier="selected-server" provides="server" owned="1" accessToken="owner-server-token">
            <Connection uri="https://remote.example.invalid" local="0" protocol="https" relay="0" />
            <Connection uri="http://local-http.example.invalid" local="1" protocol="http" relay="0" />
          </Device>
        </MediaContainer>
        """

    @Test(arguments: ["local", "local-http", "remote", "relay"])
    func selectsFirstReachableTier(_ host: String) async {
        let orderedHosts = ["local", "local-http", "remote", "relay"]
        let index = orderedHosts.firstIndex(of: host)!
        let replies = Dictionary(uniqueKeysWithValues: orderedHosts[index...].map {
            ($0 + ".example.invalid/library/sections", PlexConnectionProtocol.Reply.response(200, "{}"))
        })
        let session = session(replies)
        defer { session.invalidateAndCancel() }
        let selected = await PlexService(session: session).findBestConnection(server: server(), persistSelection: false)
        #expect(selected.flatMap(URL.init(string:))?.host == host + ".example.invalid")
        #expect(PlexConnectionProtocol.requests.allSatisfy { $0.url?.query == nil })
        #expect(PlexConnectionProtocol.requests.filter { $0.url?.path == "/identity" }.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Plex-Token") == nil
        })
        #expect(PlexConnectionProtocol.requests.filter { $0.url?.path == "/library/sections" }.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Plex-Token") == "selected-user-token"
        })
    }

    @Test func publicIdentityCannotMakeRejectedCredentialsLookValid() async {
        let session = session([
            "local.example.invalid/library/sections": .response(401, ""),
        ])
        defer { session.invalidateAndCancel() }
        #expect(await PlexService(session: session).findBestConnection(server: server(), persistSelection: false) == nil)
        #expect(PlexConnectionProtocol.requests.contains { $0.url?.path == "/library/sections" })
    }

    @Test func stalledLocalProbeFallsBackWithinItsDeadline() async {
        let session = session([
            "local.example.invalid/library/sections": .stalled,
            "remote.example.invalid/library/sections": .response(200, "{}"),
        ])
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        let selected = await PlexService(session: session).findBestConnection(server: server(), persistSelection: false)
        #expect(selected == "https://remote.example.invalid")
        #expect(start.duration(to: .now) < .seconds(6))
    }

    @Test func cancellationDoesNotAdvanceToAnotherTier() async {
        let session = session(["local.example.invalid/library/sections": .stalled])
        defer { session.invalidateAndCancel() }
        let service = PlexService(session: session)
        let server = server()
        let task = Task { await service.findBestConnection(server: server, persistSelection: false) }
        while PlexConnectionProtocol.requests.isEmpty { await Task.yield() }
        task.cancel()
        #expect(await task.value == nil)
        #expect(!PlexConnectionProtocol.requests.contains { $0.url?.host == "plex.tv" })
    }

    @Test func recoversSelectedServerAndPreservesProgressRequestAndUser() async throws {
        let session = session([
            "plex.tv/api/v2/resources": .response(200, resources),
            "local-http.example.invalid/library/sections": .response(200, "{}"),
            "local-http.example.invalid/:/timeline": .response(200, "{}"),
            "other.example.invalid/library/sections": .response(200, "{}"),
        ])
        defer { session.invalidateAndCancel() }
        let provider = PlexProvider(connection: connection(), session: session)
        let book = Book(id: "track", title: "Fixture", duration: 100, source: .plex)
        try await provider.updatePlaybackProgress(book: book, sessionId: "playback-session", currentTime: 42,
                                                  isFinished: false, timeListened: 1)
        #expect(provider.connection.url == "http://local-http.example.invalid")
        let requests = PlexConnectionProtocol.requests
        #expect(!requests.contains { $0.url?.host == "other.example.invalid" })
        let discovery = try #require(requests.first { $0.url?.host == "plex.tv" })
        #expect(discovery.value(forHTTPHeaderField: "X-Plex-Token") == "account-token")
        let replay = try #require(requests.last)
        #expect(replay.httpMethod == "POST")
        #expect(replay.value(forHTTPHeaderField: "X-Plex-Token") == "selected-user-token")
        #expect(replay.value(forHTTPHeaderField: "X-Plex-Session-Identifier") == "playback-session")
        let query = URLComponents(url: try #require(replay.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "time" }?.value == "42000")
        #expect(query?.first { $0.name == "ratingKey" }?.value == "track")
        #expect(requests.filter { $0.url?.host != "plex.tv" && $0.url?.path != "/identity" }.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Plex-Token") == "selected-user-token"
        })
    }

    @Test func localConnectionRecoversToRemoteWhenAway() async throws {
        let session = session([
            "plex.tv/api/v2/resources": .response(200, resources),
            "remote.example.invalid/library/sections": .response(200, #"{"MediaContainer":{"Directory":[]}}"#),
        ])
        defer { session.invalidateAndCancel() }
        var connection = connection()
        connection.url = "http://local-http.example.invalid"
        let provider = PlexProvider(connection: connection, session: session)
        #expect(try await provider.fetchLibraries().isEmpty)
        #expect(provider.connection.url == "https://remote.example.invalid")
    }

    @Test func unmatchedSavedServerNeverFallsBackToAnotherAccountServer() async throws {
        let session = session(["plex.tv/api/v2/resources": .response(200, resources)])
        defer { session.invalidateAndCancel() }
        var connection = connection()
        connection.url = "https://missing.example.invalid"
        #expect(try await PlexService(session: session).recoverConnection(connection) == nil)
        #expect(PlexConnectionProtocol.requests.count == 1)
    }

    @Test func recoveryReplacesReverseProxyPrefixAndPreservesEscapedPath() async throws {
        let resources = resources.replacingOccurrences(of: "https://remote.example.invalid", with: "https://remote.example.invalid/plex")
        let session = session([
            "plex.tv/api/v2/resources": .response(200, resources),
            "local-http.example.invalid/library/sections": .response(200, "{}"),
            "local-http.example.invalid/library/metadata/track name": .response(200, "{}"),
        ])
        defer { session.invalidateAndCancel() }
        var connection = connection()
        connection.url = "https://remote.example.invalid/plex"
        let provider = PlexProvider(connection: connection, session: session)
        let url = try #require(URL(string: "https://remote.example.invalid/plex/library/metadata/track%20name?includeChapters=1"))
        var request = URLRequest(url: url)
        request.setValue("selected-user-token", forHTTPHeaderField: "X-Plex-Token")
        _ = try await provider.performDataTask(for: request, retryCount: 0)
        #expect(PlexConnectionProtocol.requests.last?.url?.absoluteString == "http://local-http.example.invalid/library/metadata/track%20name?includeChapters=1")
    }

    @Test func unavailableDiscoveryPreservesOriginalRequestRetry() async throws {
        let session = session([
            "remote.example.invalid/library/sections": .transientFailure(.networkConnectionLost, #"{"MediaContainer":{"Directory":[]}}"#),
        ])
        defer { session.invalidateAndCancel() }
        let provider = PlexProvider(connection: connection(), session: session)
        #expect(try await provider.fetchLibraries().isEmpty)
        #expect(provider.connection.url == "https://remote.example.invalid")
        #expect(PlexConnectionProtocol.requests.filter { $0.url?.host == "remote.example.invalid" }.count == 2)
    }

    @Test func unrelatedMachineOnLocalAddressNeverReceivesCredentials() async {
        let session = session([
            "local.example.invalid/identity": .response(200, #"{"MediaContainer":{"machineIdentifier":"other-server"}}"#),
            "local.example.invalid/library/sections": .response(200, "{}"),
            "remote.example.invalid/library/sections": .response(200, "{}"),
        ])
        defer { session.invalidateAndCancel() }
        let selected = await PlexService(session: session).findBestConnection(server: server(), persistSelection: false)
        #expect(selected == "https://remote.example.invalid")
        #expect(PlexConnectionProtocol.requests.filter { $0.url?.host == "local.example.invalid" }.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Plex-Token") == nil
        })
    }

    @Test func cancellingOneRequestDoesNotCancelSharedRecovery() async throws {
        let session = session([
            "plex.tv/api/v2/resources": .heldResponse(resources),
            "local-http.example.invalid/library/sections": .response(200, "{}"),
            "local-http.example.invalid/first": .response(200, "{}"),
            "local-http.example.invalid/second": .response(200, "{}"),
        ])
        defer { session.invalidateAndCancel() }
        let provider = PlexProvider(connection: connection(), session: session)
        let firstRequest = URLRequest(url: try #require(URL(string: "https://remote.example.invalid/first")))
        let secondRequest = URLRequest(url: try #require(URL(string: "https://remote.example.invalid/second")))
        let first = Task { try await provider.performDataTask(for: firstRequest, retryCount: 0) }
        while !PlexConnectionProtocol.hasHeldResponses { await Task.yield() }
        let second = Task { try await provider.performDataTask(for: secondRequest, retryCount: 0) }
        while !PlexConnectionProtocol.requests.contains(where: { $0.url?.path == "/second" }) { await Task.yield() }
        first.cancel()
        PlexConnectionProtocol.releaseResponses()
        await #expect(throws: CancellationError.self) { try await first.value }
        let (_, response) = try await second.value
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(PlexConnectionProtocol.requests.filter { $0.url?.host == "plex.tv" }.count == 1)
        #expect(provider.connection.url == "http://local-http.example.invalid")
    }

    @Test func unauthorizedResponseDoesNotRediscoverOrChangeUser() async throws {
        let session = session(["remote.example.invalid/library/sections": .response(401, "")])
        defer { session.invalidateAndCancel() }
        let provider = PlexProvider(connection: connection(), session: session)
        await #expect(throws: ProviderError.self) { try await provider.fetchLibraries() }
        #expect(PlexConnectionProtocol.requests.count == 1)
        #expect(provider.connection.url == "https://remote.example.invalid")
    }
}
