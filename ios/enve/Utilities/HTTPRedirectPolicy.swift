import Foundation

/// Scope credentials explicitly because URLSession may replay original headers on redirects.
nonisolated enum HTTPRedirectPolicy {
    /// Headers that carry a secret in every provider, stripped on top of whatever the caller names.
    static let alwaysSensitiveHeaderNames: Set<String> = ["Authorization", "Cookie", "Proxy-Authorization"]

    private static let allowedSchemes: Set<String> = ["http", "https"]

    /// Reject unsupported schemes, embedded userinfo, and HTTPS downgrades.
    static func isFollowable(_ url: URL, from source: URL?) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            allowedSchemes.contains(scheme),
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty
        else { return false }
        return !(source?.scheme?.lowercased() == "https" && scheme != "https")
    }

    /// Strip credentials outside their origin; a nil origin strips them unconditionally.
    static func sanitized(
        _ request: URLRequest,
        keepingCredentialsFor origin: HTTPOrigin?,
        alsoStripping extraHeaderNames: Set<String> = []
    ) -> URLRequest {
        if let url = request.url, origin?.matches(url) == true { return request }

        var stripped = request
        for name in request.allHTTPHeaderFields?.keys ?? [:].keys
        where ServerConnection.isSecretHeaderName(name) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        for name in alwaysSensitiveHeaderNames.union(extraHeaderNames) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }

    /// Use the original request URL when the caller has not supplied a credential origin.
    static func origin(ofOriginalRequestIn task: URLSessionTask) -> HTTPOrigin? {
        task.originalRequest?.url.map(HTTPOrigin.init(url:))
    }
}
