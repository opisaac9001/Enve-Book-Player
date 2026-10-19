import Foundation
import Testing

@testable import enve

@MainActor
struct ABSAuthenticationTransportTests {
    @Test(arguments: ["cancelled", "offline", "server-error"])
    func transientRefreshFailureDoesNotStartPasswordLogin(scenario: String) async throws {
        let fixture = try Fixture(scenario: scenario)
        defer { fixture.remove() }
        do {
            _ = try await fixture.provider.performTokenRefresh()
            Issue.record("Transient failure unexpectedly fell back to password login")
        } catch {
            switch scenario {
            case "cancelled": #expect((error as? URLError)?.code == .cancelled)
            case "offline": #expect((error as? URLError)?.code == .notConnectedToInternet)
            default:
                guard case AudiobookshelfError.serverError(503) = error else {
                    Issue.record("Expected server error, received \(type(of: error))")
                    await fixture.session.retire()
                    return
                }
            }
        }
        #expect(fixture.provider.connection.token == fixture.originalToken)
        #expect(fixture.session.legacyKeychain.get(fixture.refreshKey) == "fixture-refresh")
        await fixture.provider.retire()
        await fixture.session.retire()
    }

    @Test func rejectedRefreshRecoversWithPasswordAndStoresRotatedCredentials() async throws {
        let fixture = try Fixture(scenario: "rejected")
        defer { fixture.remove() }
        let credentials = try await fixture.provider.performTokenRefresh()
        #expect(credentials.accessToken == "rotated-fixture")
        #expect(fixture.provider.connection.isConnected)
        #expect(fixture.session.legacyKeychain.get(fixture.refreshKey) == "rotated-refresh")
        await fixture.provider.retire()
        await fixture.session.retire()
    }

    @Test func offlineValidationKeepsCredentialsAndDoesNotRequireReauthentication() async throws {
        let fixture = try Fixture(scenario: "offline")
        defer { fixture.remove() }
        do {
            _ = try await fixture.provider.validateConnection()
            Issue.record("Offline validation succeeded")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
            #expect(!ProviderConnectionStore.requiresReauthentication(after: error))
        }
        #expect(fixture.provider.connection.token == fixture.originalToken)
        await fixture.provider.retire()
        await fixture.session.retire()
    }

    @Test func offlineCatalogRefreshDoesNotTurnIntoAnAuthorizationFailure() async throws {
        let fixture = try Fixture(scenario: "offline")
        defer { fixture.remove() }
        do {
            _ = try await fixture.provider.fetchLibraries()
            Issue.record("Offline catalog request succeeded")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
            #expect(!ProviderConnectionStore.requiresReauthentication(after: error))
        }
        await fixture.provider.retire()
        await fixture.session.retire()
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "ABSAuthenticationTransportTests.\(UUID().uuidString)"
        let originalToken = "e30.eyJleHAiOjEsInR5cGUiOiJhY2Nlc3MifQ.fixture"
        let session: ProfileSession
        let provider: AudiobookshelfProvider
        let refreshKey: String

        init(scenario: String) throws {
            let profile = FamilyProfile(id: UUID().uuidString, name: "Authentication fixture", role: .adult)
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            session = try ProfileSession(profile: profile, storage: storage, defaults: UserDefaults(suiteName: domain)!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ABSRecoveryProtocol.self]
            session.networkSession = URLSession(configuration: configuration)
            let connection = ServerConnection(name: "Authentication fixture", url: "https://example.test/\(scenario)",
                type: .audiobookshelf, username: "fixture-user", password: "fixture-password", token: originalToken)
            refreshKey = "abs_refresh_\(connection.id.uuidString)"
            session.legacyKeychain.set("fixture-refresh", key: refreshKey)
            provider = AudiobookshelfProvider(connection: connection, profileSession: session)
        }

        func remove() {
            session.networkSession.invalidateAndCancel()
            session.legacyKeychain.delete(refreshKey)
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

nonisolated private final class ABSRecoveryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        guard request.timeoutInterval <= 10 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if url.path.hasSuffix("/auth/refresh") {
            if url.path.contains("/cancelled/") {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            if url.path.contains("/offline/") {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
        }
        let status = url.path.hasSuffix("/auth/refresh") ? (url.path.contains("/server-error/") ? 503 : 401) : 200
        let body = Data(#"{"user":{"accessToken":"rotated-fixture","refreshToken":"rotated-refresh"}}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
