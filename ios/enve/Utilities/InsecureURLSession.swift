// AGENT-LOCKED
import Foundation

class InsecureURLSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    static let delegateInstance = InsecureURLSession()

    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegateInstance, delegateQueue: nil)
    }()

    private let clientCertificate: @Sendable (String) async -> URLCredential?

    override convenience init() {
        self.init { host in
            guard let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) else { return nil }
            return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
        }
    }

    init(clientCertificate: @escaping @Sendable (String) async -> URLCredential?) {
        self.clientCertificate = clientCertificate
        super.init()
    }

    func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    var delegate: URLSessionDelegate { self }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate {
            Task {
                if let credential = await clientCertificate(host) {
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            }
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        {
            if NetworkHostUtils.isLocalNetworkHost(host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
