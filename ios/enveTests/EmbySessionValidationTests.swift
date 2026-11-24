import Foundation
import Testing

@testable import enve

nonisolated private final class EmbySessionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let status: Int
        let body: String
        switch url.path {
        case "/emby/System/Info/Public":
            (status, body) = (200, "{}")
        case "/emby/Users/user":
            let auth = request.value(forHTTPHeaderField: "X-Emby-Authorization") ?? ""
            let valid = auth.contains("Token=\"current\"") && request.value(forHTTPHeaderField: "X-Proxy-Route") == "books"
            (status, body) = valid ? (200, #"{"Id":"user"}"#) : (401, "")
        default:
            (status, body) = (404, "")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
struct EmbySessionValidationTests {
    @Test(arguments: ["revoked", "current"])
    func verifiesASelectedUserWithTheSavedKey(token: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbySessionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = EmbyProvider(connection: ServerConnection(
            name: "Fixture", url: "https://emby.example.invalid/emby", type: .emby,
            token: token, userId: "user", customHeaders: ["X-Proxy-Route": "books"], authMode: .token
        ), session: session)
        let valid = try await provider.validateConnection()
        #expect(valid == (token == "current"))
    }
}
