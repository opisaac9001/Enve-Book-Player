import Foundation

final class OPDSSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let certificateTransport: InsecureURLSession
    private let origin: HTTPOrigin
    private let username: String?
    private let password: String?
    private let credentialHeaderNames: Set<String>

    init(origin: URL, username: String?, password: String?, credentialHeaderNames: Set<String>, certificateTransport: InsecureURLSession = .delegateInstance) {
        self.certificateTransport = certificateTransport
        self.origin = HTTPOrigin(url: origin)
        self.username = username
        self.password = password
        self.credentialHeaderNames = credentialHeaderNames
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            certificateTransport.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
            return
        }

        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
            let user = username, !user.isEmpty, let password,
            origin.matches(challenge.protectionSpace)
        {
            completionHandler(
                .useCredential,
                URLCredential(user: user, password: password, persistence: .forSession)
            )
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(challenge.protectionSpace.host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    /// Reject unsupported schemes, embedded credentials, and HTTPS downgrades before following redirects.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, HTTPRedirectPolicy.isFollowable(url, from: response.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(
            HTTPRedirectPolicy.sanitized(
                request,
                keepingCredentialsFor: origin,
                alsoStripping: credentialHeaderNames
            )
        )
    }
}
