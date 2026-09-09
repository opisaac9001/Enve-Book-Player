// AGENT-LOCKED
import Foundation
@preconcurrency import Security

enum NetworkHostUtils {
    static nonisolated func isLocalNetworkHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4,
            parts.allSatisfy({ part in
                !part.isEmpty && (part.count == 1 || part.first != "0")
                    && part.utf8.allSatisfy { (48...57).contains($0) }
            })
        {
            let octets = parts.compactMap { UInt8($0) }
            if octets.count == 4 {
                return octets == [127, 0, 0, 1]
                    || octets[0] == 10
                    || (octets[0] == 192 && octets[1] == 168)
                    || (octets[0] == 172 && (16...31).contains(octets[1]))
                    || (octets[0] == 100 && (64...127).contains(octets[1]))
            }
        }

        if host.hasSuffix(".local") || host.hasSuffix(".lan") { return true }
        if host.hasSuffix(".home") || host.hasSuffix(".internal") { return true }
        if host.hasSuffix(".plex.direct") { return true }

        return false
    }

    static nonisolated func findMTLSIdentity(forHost host: String) -> SecIdentity? {
        @MainActor
        func lookup() -> SecIdentity? {
            let connections = AppState.shared.providerConnections.connections.filter { $0.mtlsEnabled && !$0.isArchived }
            for conn in connections {
                guard let connHost = URL(string: conn.url)?.host else { continue }
                if connHost == host {
                    return MTLSManager.shared.identity(for: conn.id)
                }
            }
            return MTLSManager.shared.pendingIdentity(forHost: host)
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated(lookup)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(lookup) }
    }

    static func handleAuthChallenge(
        challenge: URLAuthenticationChallenge,
        basicCredential: URLCredential? = nil,
        maxBasicAttempts: Int = 2,
        basicAttemptCount: inout Int,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            if isLocalNetworkHost(host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
            let credential = basicCredential,
            basicAttemptCount < maxBasicAttempts
        {
            basicAttemptCount += 1
            completionHandler(.useCredential, credential)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
