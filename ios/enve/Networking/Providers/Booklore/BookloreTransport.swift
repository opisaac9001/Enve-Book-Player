import Foundation
import Logging
import Security

final class BookloreTransport: @unchecked Sendable {
    private let session: URLSession
    private let authDelegate: BookloreAuthDelegate

    var credential: URLCredential { authDelegate.credential }
    var sessionHeaders: [AnyHashable: Any]? { session.configuration.httpAdditionalHeaders }

    init(connection: ServerConnection, profileSession: ProfileSession? = nil) {
        let configuration: URLSessionConfiguration = profileSession?.isOwner == false ? .ephemeral : .default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        authDelegate = BookloreAuthDelegate(
            username: connection.username ?? "",
            password: connection.password ?? "",
            serverHost: URL(string: connection.url)?.host,
            certificateTransport: profileSession?.transport ?? .delegateInstance
        )
        session = URLSession(configuration: configuration, delegate: authDelegate, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func setCustomHeadersProvider(_ provider: @escaping () -> [String: String]?) {
        authDelegate.customHeadersProvider = provider
    }

    func makeRequest(
        connection: ServerConnection,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        includeAuth: Bool = true,
        allowBasicFallback: Bool = false
    ) throws -> URLRequest {
        let base = Self.normalize(connection.url)
        guard var components = URLComponents(string: "\(base)\(path)") else {
            throw ProviderError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw ProviderError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if includeAuth {
            addAuthHeaders(to: &request, connection: connection, allowBasicFallback: allowBasicFallback)
        } else {
            for (key, value) in connection.customHeaders ?? [:]
            where key.caseInsensitiveCompare("Authorization") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    func addAuthHeaders(
        to request: inout URLRequest,
        connection: ServerConnection,
        allowBasicFallback: Bool = false
    ) {
        for (key, value) in connection.customHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let token = connection.token, !token.isEmpty {
            if token.hasPrefix("Basic ") {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(
                    "Bearer \(BookloreJWT.normalizedToken(token) ?? token)",
                    forHTTPHeaderField: "Authorization"
                )
            }
        } else if allowBasicFallback,
            let username = connection.username,
            let password = connection.password,
            !username.isEmpty,
            let data = "\(username):\(password)".data(using: .utf8)
        {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    private static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("/") { result.removeLast() }
        if !result.hasPrefix("http") { result = "http://\(result)" }
        return result
    }
}

final class BookloreAuthDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    let credential: URLCredential
    private let serverHost: String?
    private let certificateTransport: InsecureURLSession
    private var challengeCount = 0
    var customHeadersProvider: (() -> [String: String]?)?

    init(username: String, password: String, serverHost: String?, certificateTransport: InsecureURLSession = .delegateInstance) {
        credential = URLCredential(user: username, password: password, persistence: .forSession)
        self.serverHost = serverHost?.lowercased()
        self.certificateTransport = certificateTransport
        super.init()
    }

    private func isServerHost(_ host: String?) -> Bool {
        guard let serverHost, let host else { return false }
        return host.lowercased() == serverHost
    }

    @objc func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let redirectURL = request.url,
            let host = redirectURL.host?.lowercased(),
            host.contains("cloudflareaccess.com") || redirectURL.path.hasPrefix("/cdn-cgi/access/")
        {
            AppLogger.network.warning("Blocked redirect to Cloudflare Access login: \(redirectURL)")
            completionHandler(nil)
            return
        }
        var redirectRequest = request
        for (key, value) in customHeadersProvider?() ?? [:]
        where isServerHost(request.url?.host) && redirectRequest.value(forHTTPHeaderField: key) == nil {
            redirectRequest.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirectRequest)
    }

    @objc nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        if method == NSURLAuthenticationMethodClientCertificate {
            certificateTransport.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        } else if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    @objc func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        AppLogger.network.debug("Booklore auth challenge method=\(method) attempt=\(challengeCount + 1)")
        if method == NSURLAuthenticationMethodClientCertificate {
            certificateTransport.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        } else if (method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest)
            && challengeCount < 2 && isServerHost(challenge.protectionSpace.host)
        {
            challengeCount += 1
            completionHandler(.useCredential, credential)
        } else if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(challenge.protectionSpace.host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
