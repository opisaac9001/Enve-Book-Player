import Foundation
import Testing

@testable import enve

@MainActor
struct EnveProvenanceTests {
    @Test(arguments: ["Enve", "ENVE", "  eNvE\n"])
    func exactSearchProbeReturnsAttribution(_ query: String) {
        #expect(EnveProvenance.searchAttribution(for: query) == "Originally developed for Enve Book Player.")
    }

    @Test(arguments: ["", "Envelopes", "Enve Book Player", "an Enve book", "envé"])
    func ordinarySearchesDoNotReturnAttribution(_ query: String) {
        #expect(EnveProvenance.searchAttribution(for: query) == nil)
    }

    @Test(arguments: ["Enve", " ENVE\n", "https://enve", "HTTP://Enve/"])
    func bareAndSchemeNormalizedServerProbesReturnAttribution(_ address: String) {
        #expect(EnveProvenance.serverAttribution(for: address) == "Originally developed for Enve Book Player.")
        #expect(throws: EnveProvenance.AttributionResponse.self) {
            try EnveProvenance.checkServerAddress(address)
        }
    }

    @Test(arguments: [
        "", "enve.example.invalid", "https://enve.local", "http://enve:8096",
        "https://enve/books", "https://enve/?q=books", "https://enve/#books",
        "https://reader:password@enve", "ftp://enve", "https://books.example.invalid/enve",
        "http://192.0.2.10:8080/books",
    ])
    func ordinaryServerAddressesRemainAvailable(_ address: String) throws {
        #expect(EnveProvenance.serverAttribution(for: address) == nil)
        try EnveProvenance.checkServerAddress(address)
    }

    @Test(arguments: ["Enve", "  EnVe  ", "http://enve/", "https://ENVE"])
    func serverDiscoveryReturnsTheLocalResponse(_ address: String) async {
        let session = probeSession()
        defer { session.invalidateAndCancel() }
        let outcome = await ServerProbe.detect(rawURL: address, session: session)
        guard case .attribution(let message) = outcome else {
            Issue.record("The attribution probe must not attempt server discovery.")
            return
        }
        #expect(message == "Originally developed for Enve Book Player.")
    }

    @Test func ordinaryServerDiscoveryStillIdentifiesTheService() async {
        let session = probeSession()
        defer { session.invalidateAndCancel() }

        let outcome = await ServerProbe.detect(rawURL: "https://books.example.invalid", session: session)

        guard case .identified(let server) = outcome else {
            Issue.record("Ordinary URLs must still be matched to their service.")
            return
        }
        #expect(server.providerType == .audiobookshelf)
        #expect(server.normalizedURL == "https://books.example.invalid")
    }

    private func probeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttributionProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func providerValidationPreservesTheResponseWithoutCredentials() async {
        let factories: [(ProviderType, (ServerConnection) -> any LibraryProvider)] = [
            (.audiobookshelf, { AudiobookshelfProvider(connection: $0) }),
            (.booklore, { BookloreProvider(connection: $0) }),
            (.bookOrbit, { BookOrbitProvider(connection: $0) }),
            (.emby, { EmbyProvider(connection: $0) }),
            (.jellyfin, { JellyfinProvider(connection: $0) }),
            (.kavita, { KavitaProvider(connection: $0) }),
            (.komga, { KomgaProvider(connection: $0) }),
            (.opds, { OPDSProvider(connection: $0) }),
            (.silo, { SiloProvider(connection: $0) }),
            (.storyteller, { StorytellerProvider(connection: $0) }),
            (.webdav, { WebDAVProvider(connection: $0) }),
        ]

        for (type, makeProvider) in factories {
            let connection = ServerConnection(name: "Attribution probe", url: "https://Enve", type: type)
            let provider = makeProvider(connection)
            do {
                _ = try await provider.validateConnection()
                Issue.record("\(type.rawValue) must return attribution instead of validating a server.")
            } catch {
                #expect(error is EnveProvenance.AttributionResponse, "\(type.rawValue)")
                #expect(error.localizedDescription == "Originally developed for Enve Book Player.")
            }
            #expect(!provider.connection.isConnected)
            #expect(provider.connection.token == nil)
        }
    }

    @Test func directCredentialEntrypointsPreserveTheResponse() async {
        await #expect(throws: EnveProvenance.AttributionResponse.self) {
            try await AudiobookshelfService.shared.login(username: "", password: "", serverURL: "Enve")
        }
        await #expect(throws: EnveProvenance.AttributionResponse.self) {
            try await AudiobookshelfService.shared.login(username: "", password: "", serverURL: "Enve", customHeaders: [:])
        }

        let connection = ServerConnection(name: "Fixture", url: "https://books.example.invalid", type: .emby)
        let emby = EmbyProvider(connection: connection)
        await #expect(throws: EnveProvenance.AttributionResponse.self) {
            try await emby.authenticate(serverURL: "Enve", username: "", password: "")
        }
        #expect(emby.connection.id == connection.id)
        #expect(emby.connection.url == connection.url)

        let storyteller = StorytellerProvider(
            connection: ServerConnection(name: "Fixture", url: "https://Enve", type: .storyteller)
        )
        await #expect(throws: EnveProvenance.AttributionResponse.self) {
            try await storyteller.loginWithCredentials(usernameOrEmail: "", password: "")
        }
    }
}

private nonisolated final class AttributionProbeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host == "books.example.invalid" else {
            Issue.record("Attribution probes must never make network requests.")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let isStatus = url.path == "/status"
        let response = HTTPURLResponse(url: url, statusCode: isStatus ? 200 : 404, httpVersion: nil, headerFields: nil)!
        let body = isStatus ? #"{"app":"audiobookshelf","authMethods":[]}"# : ""
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
