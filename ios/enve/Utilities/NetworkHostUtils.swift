// AGENT-LOCKED
import Foundation
@preconcurrency import Security

enum NetworkHostUtils {
    static nonisolated func isLocalNetworkHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }

        if host.hasPrefix("172."),
            let second = host.split(separator: ".").dropFirst().first,
            let v = Int(second), (16...31).contains(v)
        {
            return true
        }

        if host.hasPrefix("100."),
            let second = host.split(separator: ".").dropFirst().first,
            let v = Int(second), (64...127).contains(v)
        {
            return true
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
