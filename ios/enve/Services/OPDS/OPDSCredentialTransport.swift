import Foundation

/// Reject cross-origin redirects: 307/308 can replay passwords or refresh tokens in the request body.
nonisolated enum OPDSCredentialTransport {
    /// Allow delegated identity providers, but permit HTTP only for HTTP feeds or local-network hosts.
    static func isPostable(_ endpoint: URL, feedURL: URL) -> Bool {
        guard OPDSURL.isRequestable(endpoint) else { return false }
        guard endpoint.scheme?.lowercased() != "https" else { return true }
        return OPDSURL.sameOrigin(endpoint, as: feedURL)
            || NetworkHostUtils.isLocalNetworkHost(endpoint.host ?? "")
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw ProviderError.invalidURL }

        let delegate = OPDSCredentialSessionDelegate(endpoint: url)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }
}

/// Accept supported local TLS challenges and keep credential bodies on the endpoint origin.
final class OPDSCredentialSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: HTTPOrigin

    init(endpoint: URL) {
        origin = HTTPOrigin(url: endpoint)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate,
            let identity = NetworkHostUtils.findMTLSIdentity(forHost: host)
        {
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            )
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
            HTTPRedirectPolicy.isFollowable(url, from: response.url),
            origin.matches(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(HTTPRedirectPolicy.sanitized(request, keepingCredentialsFor: origin))
    }
}
