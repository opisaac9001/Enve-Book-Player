import CryptoKit
import Foundation
import Testing

@testable import enve

nonisolated private final class SiloOAuthFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(URL, String, [String: Any])] = []

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    static func requests() -> [(URL, String, [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let host = url.host() ?? ""
        let method = request.httpMethod ?? "GET"
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bodyData.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.recorded.append((url, method, body))
        Self.lock.unlock()

        var status = 200
        var payload: [String: Any] = [:]
        if path.hasSuffix("/api/v2/auth/oauth/capabilities") {
            switch host {
            case "legacy.invalid": status = 404
            case "disabled.invalid": payload = ["native": false]
            default: payload = ["native": true]
            }
        } else if path.hasSuffix("/api/v2/auth/providers") {
            switch host {
            case "noproviders.invalid":
                payload = ["items": [["mode": "password"], ["mode": "oauth"]]]
            case "offsite.invalid":
                payload = ["items": [["mode": "oauth", "native_start_path": "//attacker.invalid/start"]]]
            default:
                payload = ["items": [
                    ["mode": "password", "display_name": "Password"],
                    ["mode": "oauth", "display_name": "Authentik", "native_start_path": "/api/v2/auth/oauth/authentik/native/start"],
                    ["mode": "oauth", "display_name": "Missing path"],
                ]]
            }
        } else if path.hasSuffix("/api/v2/system/identity") {
            payload = ["server_id": "srv-1"]
        } else if path.hasSuffix("/api/v2/auth/oauth/complete") {
            payload = ["access_token": "access-1", "refresh_token": "refresh-1", "user": ["id": "7", "username": "reader"]]
        } else {
            status = 404
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct SiloNativeOAuthTests {
    private func makeProvider(url: String, session: URLSession) -> SiloProvider {
        SiloProvider(
            connection: ServerConnection(name: "Fixture", url: url, type: .silo, authMode: .sso),
            session: session
        )
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloOAuthFixture.self]
        return URLSession(configuration: config)
    }

    private let attempt = SiloProvider.NativeOAuthAttempt(
        authorizationURL: URL(string: "https://silo.invalid/start")!,
        codeVerifier: "verifier",
        state: "state-1",
        serverID: "srv-1",
        issuer: "https://silo.invalid"
    )

    private func callback(_ query: String, path: String = "org.siloserver.silo:/auth/callback") -> URL {
        URL(string: "\(path)?\(query)")!
    }

    @Test func nativeSignInExchangesCodeWithSavedServerOnly() async throws {
        SiloOAuthFixture.reset()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = makeProvider(url: "https://silo.invalid/base/", session: session)
        defer { KeychainHelper.shared.delete("silo_refresh_\(provider.connection.id.uuidString)") }

        let options = try await provider.nativeOAuthOptions()
        #expect(options == [.init(displayName: "Authentik", nativeStartPath: "/api/v2/auth/oauth/authentik/native/start")])

        let attempt = try await provider.beginNativeOAuth(with: options[0])
        let components = try #require(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "silo.invalid")
        #expect(components.path == "/base/api/v2/auth/oauth/authentik/native/start")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["app_state"] == attempt.state)
        let expectedChallenge = Data(SHA256.hash(data: Data(attempt.codeVerifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(query["code_challenge"] == expectedChallenge)
        #expect(attempt.codeVerifier.count >= 43)
        #expect(attempt.serverID == "srv-1")
        #expect(attempt.issuer == "https://silo.invalid")

        let callbackURL = callback(
            "code=abc&state=\(attempt.state)&server=srv-1&iss=https://silo.invalid"
        )
        try await provider.completeNativeOAuth(callbackURL: callbackURL, attempt: attempt)

        let complete = try #require(SiloOAuthFixture.requests().last)
        #expect(complete.0.host() == "silo.invalid")
        #expect(complete.0.path == "/base/api/v2/auth/oauth/complete")
        #expect(complete.1 == "POST")
        #expect(complete.2["code"] as? String == "abc")
        #expect(complete.2["code_verifier"] as? String == attempt.codeVerifier)
        #expect(provider.connection.token == "access-1")
        #expect(provider.connection.userId == "7")
        #expect(provider.connection.username == "reader")
        #expect(provider.connection.authMode == .sso)
        #expect(KeychainHelper.shared.get("silo_refresh_\(provider.connection.id.uuidString)") == "refresh-1")
    }

    @Test func rejectedCallbackNeverReachesTheServer() async throws {
        SiloOAuthFixture.reset()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = makeProvider(url: "https://silo.invalid", session: session)

        await #expect(throws: SiloOAuthError.serverMismatch) {
            try await provider.completeNativeOAuth(
                callbackURL: callback("code=abc&state=state-1&server=other&iss=https://silo.invalid"),
                attempt: attempt
            )
        }
        #expect(SiloOAuthFixture.requests().isEmpty)
        #expect(provider.connection.token == nil)
    }

    @Test func callbackRequiresExactSchemeAndPath() {
        let valid = "code=abc&state=state-1&server=srv-1&iss=https://silo.invalid"
        #expect(throws: SiloOAuthError.invalidCallback) {
            try attempt.authorizationCode(from: callback(valid, path: "enveapp:/auth/callback"))
        }
        #expect(throws: SiloOAuthError.invalidCallback) {
            try attempt.authorizationCode(from: callback(valid, path: "org.siloserver.silo:/auth/callback/extra"))
        }
        #expect(throws: SiloOAuthError.invalidCallback) {
            try attempt.authorizationCode(from: callback(valid, path: "org.siloserver.silo://auth/callback"))
        }
        #expect((try? attempt.authorizationCode(from: callback(valid))) == "abc")
    }

    @Test func callbackRequiresMatchingStateServerAndIssuer() {
        #expect(throws: SiloOAuthError.invalidCallback) {
            try attempt.authorizationCode(from: callback("code=abc&state=forged&server=srv-1&iss=https://silo.invalid"))
        }
        #expect(throws: SiloOAuthError.invalidCallback) {
            try attempt.authorizationCode(
                from: callback("code=abc&state=state-1&state=state-1&server=srv-1&iss=https://silo.invalid")
            )
        }
        #expect(throws: SiloOAuthError.serverMismatch) {
            try attempt.authorizationCode(from: callback("code=abc&state=state-1&iss=https://silo.invalid"))
        }
        for issuer in ["https://evil.invalid", "http://silo.invalid", "https://silo.invalid:8443", "https://silo.invalid/base"] {
            #expect(throws: SiloOAuthError.issuerMismatch) {
                try attempt.authorizationCode(from: callback("code=abc&state=state-1&server=srv-1&iss=\(issuer)"))
            }
        }
        for issuer in ["https://SILO.invalid/", "https://silo.invalid:443"] {
            #expect((try? attempt.authorizationCode(from: callback("code=abc&state=state-1&server=srv-1&iss=\(issuer)"))) == "abc")
        }
    }

    @Test func callbackSurfacesErrorAndRequiresCode() {
        #expect(throws: SiloOAuthError.authorizationFailed("access_denied")) {
            try attempt.authorizationCode(
                from: callback("error=access_denied&state=state-1&server=srv-1&iss=https://silo.invalid")
            )
        }
        #expect(throws: SiloOAuthError.invalidCallback) {
            try attempt.authorizationCode(from: callback("state=state-1&server=srv-1&iss=https://silo.invalid"))
        }
        for extra in ["&code=other", "&error=denied", "&link=1"] {
            #expect(throws: SiloOAuthError.invalidCallback) {
                try attempt.authorizationCode(
                    from: callback("code=abc&state=state-1&server=srv-1&iss=https://silo.invalid\(extra)")
                )
            }
        }
    }

    @Test func missingNativeSupportIsAClearError() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        await #expect(throws: SiloOAuthError.nativeSignInUnavailable) {
            try await makeProvider(url: "https://legacy.invalid", session: session).nativeOAuthOptions()
        }
        await #expect(throws: SiloOAuthError.nativeSignInUnavailable) {
            try await makeProvider(url: "https://disabled.invalid", session: session).nativeOAuthOptions()
        }
        await #expect(throws: SiloOAuthError.noProviders) {
            try await makeProvider(url: "https://noproviders.invalid", session: session).nativeOAuthOptions()
        }
    }

    @Test func startPathMustStayOnSavedServer() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = makeProvider(url: "https://offsite.invalid", session: session)

        let options = try await provider.nativeOAuthOptions()
        await #expect(throws: SiloOAuthError.invalidStartPath) {
            try await provider.beginNativeOAuth(with: options[0])
        }
        await #expect(throws: SiloOAuthError.invalidStartPath) {
            try await provider.beginNativeOAuth(
                with: .init(displayName: "Absolute", nativeStartPath: "https://attacker.invalid/start")
            )
        }
        await #expect(throws: SiloOAuthError.invalidStartPath) {
            try await provider.beginNativeOAuth(
                with: .init(displayName: "Unexpected", nativeStartPath: "/other/native/start")
            )
        }
    }
}
