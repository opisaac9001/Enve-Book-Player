// AGENT-LOCKED
import Foundation
import Logging
import Security

final class MTLSManager: @unchecked Sendable {
    static let shared = MTLSManager()
    private let pendingAuthenticationLock = NSLock()
    private var pendingAuthenticationHost: String?
    private init() {}

    static func certKey(for connectionId: UUID) -> String {
        "mtls_cert_\(connectionId.uuidString)"
    }

    static func certPassKey(for connectionId: UUID) -> String {
        "mtls_cert_pass_\(connectionId.uuidString)"
    }

    static let pendingCertKey = "mtls_pending_cert"
    static let pendingCertPassKey = "mtls_pending_cert_pass"

    func validatePKCS12(_ data: Data, password: String) throws -> String {
        let (identity, _) = try importPKCS12(data, password: password)
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        guard status == errSecSuccess, let cert else {
            throw MTLSError.identityExtraction(status)
        }
        let summary = SecCertificateCopySubjectSummary(cert) as String? ?? "Client Certificate"
        return summary
    }

    func storePendingCert(data: Data, password: String) {
        KeychainHelper.shared.set(data, key: Self.pendingCertKey)
        if !password.isEmpty {
            KeychainHelper.shared.set(password, key: Self.pendingCertPassKey)
        }
    }

    func storePendingCertData(_ data: Data) {
        KeychainHelper.shared.set(data, key: Self.pendingCertKey)
    }

    var hasPendingCertData: Bool {
        KeychainHelper.shared.getData(Self.pendingCertKey) != nil
    }

    func promotePendingCert(to connectionId: UUID) {
        if let data = KeychainHelper.shared.getData(Self.pendingCertKey) {
            KeychainHelper.shared.set(data, key: Self.certKey(for: connectionId))
        }
        if let pass = KeychainHelper.shared.get(Self.pendingCertPassKey) {
            KeychainHelper.shared.set(pass, key: Self.certPassKey(for: connectionId))
        }
        clearPendingCert()
    }

    func clearPendingCert() {
        KeychainHelper.shared.delete(Self.pendingCertKey)
        KeychainHelper.shared.delete(Self.pendingCertPassKey)
    }

    func deleteCert(for connectionId: UUID) {
        KeychainHelper.shared.delete(Self.certKey(for: connectionId))
        KeychainHelper.shared.delete(Self.certPassKey(for: connectionId))
    }

    func identity(for connectionId: UUID) -> SecIdentity? {
        resolveIdentity(for: connectionId)
    }

    func pendingIdentity(password: String) -> SecIdentity? {
        guard let data = KeychainHelper.shared.getData(Self.pendingCertKey) else { return nil }
        return try? importPKCS12(data, password: password).identity
    }

    func beginPendingAuthentication(forHost host: String) {
        pendingAuthenticationLock.lock()
        pendingAuthenticationHost = host.lowercased()
        pendingAuthenticationLock.unlock()
    }

    func endPendingAuthentication() {
        pendingAuthenticationLock.lock()
        pendingAuthenticationHost = nil
        pendingAuthenticationLock.unlock()
    }

    func pendingIdentity(forHost host: String) -> SecIdentity? {
        pendingAuthenticationLock.lock()
        let isExpectedHost = pendingAuthenticationHost == host.lowercased()
        pendingAuthenticationLock.unlock()

        guard isExpectedHost,
            let data = KeychainHelper.shared.getData(Self.pendingCertKey)
        else { return nil }

        let password = KeychainHelper.shared.get(Self.pendingCertPassKey) ?? ""
        if password == "__keychain_identity__" {
            return findKeychainIdentity(matchingDER: data)
        }
        return try? importPKCS12(data, password: password).identity
    }

    struct KeychainIdentityInfo: Identifiable, Hashable {
        let id: String
        let label: String

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    func listKeychainIdentities() -> [(info: KeychainIdentityInfo, identity: SecIdentity)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            return []
        }

        var seen = Set<String>()
        return identities.compactMap { identity in
            var certRef: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
                let cert = certRef
            else { return nil }

            let summary = SecCertificateCopySubjectSummary(cert) as String? ?? "Unknown"

            let derData = SecCertificateCopyData(cert) as Data
            let hashBytes = [UInt8](derData).prefix(32)
            let fingerprint = hashBytes.map { String(format: "%02x", $0) }.joined()

            guard seen.insert(fingerprint).inserted else { return nil }

            let info = KeychainIdentityInfo(
                id: fingerprint,
                label: summary
            )
            return (info: info, identity: identity)
        }
    }

    func storePendingKeychainIdentity(_ identity: SecIdentity) -> String? {
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
            let cert = certRef
        else { return nil }

        let summary = SecCertificateCopySubjectSummary(cert) as String? ?? "Client Certificate"
        let derData = SecCertificateCopyData(cert) as Data

        KeychainHelper.shared.set(derData, key: Self.pendingCertKey)
        KeychainHelper.shared.set("__keychain_identity__", key: Self.pendingCertPassKey)
        return summary
    }

    func promoteKeychainPendingCert(to connectionId: UUID) {
        guard let pendingDER = KeychainHelper.shared.getData(Self.pendingCertKey),
            KeychainHelper.shared.get(Self.pendingCertPassKey) == "__keychain_identity__"
        else {
            promotePendingCert(to: connectionId)
            return
        }

        KeychainHelper.shared.set(pendingDER, key: Self.certKey(for: connectionId))
        KeychainHelper.shared.set("__keychain_identity__", key: Self.certPassKey(for: connectionId))
        clearPendingCert()
    }

    func resolveIdentity(for connectionId: UUID) -> SecIdentity? {
        guard let data = KeychainHelper.shared.getData(Self.certKey(for: connectionId)) else { return nil }
        let password = KeychainHelper.shared.get(Self.certPassKey(for: connectionId)) ?? ""

        if password == "__keychain_identity__" {
            return findKeychainIdentity(matchingDER: data)
        }

        return try? importPKCS12(data, password: password).identity
    }

    private func findKeychainIdentity(matchingDER targetDER: Data) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let identities = result as? [SecIdentity]
        else { return nil }

        for identity in identities {
            var certRef: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
                let cert = certRef
            else { continue }
            let derData = SecCertificateCopyData(cert) as Data
            if derData == targetDER {
                return identity
            }
        }
        return nil
    }

    @discardableResult
    func handleChallenge(
        for connectionId: UUID?,
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            guard let connectionId,
                let identity = identity(for: connectionId)
            else {
                completionHandler(.performDefaultHandling, nil)
                return true
            }
            let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            completionHandler(.useCredential, credential)
            return true
        }

        return false
    }

    func makeSession(
        for connectionId: UUID,
        configuration: URLSessionConfiguration = .default,
        additionalDelegate: URLSessionDelegate? = nil
    ) -> URLSession {
        let resolvedIdentity = identity(for: connectionId)
        let delegate = MTLSURLSessionDelegate(identity: resolvedIdentity)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func importPKCS12(_ data: Data, password: String) throws -> (identity: SecIdentity, chain: [SecCertificate]) {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        if status != errSecSuccess {
            AppLogger.network.error(
                "[mTLS] SecPKCS12Import failed: OSStatus=\(status), dataSize=\(data.count) bytes, passwordLength=\(password.count)"
            )
            throw MTLSError.pkcs12Import(status)
        }

        guard let array = items as? [[String: Any]],
            let first = array.first,
            let rawIdentity = first[kSecImportItemIdentity as String]
        else {
            AppLogger.network.info("[mTLS] SecPKCS12Import succeeded but no identity found in \((items as? [Any])?.count ?? 0) item(s)")
            throw MTLSError.noIdentityFound
        }

        let identity = rawIdentity as! SecIdentity

        let chain: [SecCertificate]
        if let rawChain = first[kSecImportItemCertChain as String] as? [SecCertificate] {
            chain = rawChain
        } else {
            chain = []
        }

        AppLogger.network.info("[mTLS] Successfully imported PKCS#12 with \(chain.count) certificate(s) in chain")
        return (identity, chain)
    }
}

enum MTLSError: LocalizedError {
    case pkcs12Import(OSStatus)
    case noIdentityFound
    case identityExtraction(OSStatus)
    case invalidCertificate

    var errorDescription: String? {
        switch self {
        case .pkcs12Import(let status):
            switch status {
            case errSecAuthFailed:
                return "The certificate password is incorrect. Please re-enter your password and try again."
            case errSecDecode:
                return "The selected file is not a valid PKCS#12 (.p12/.pfx) certificate. It may be corrupted or in an unsupported format."
            case errSecPassphraseRequired:
                return "This certificate requires a password. Please enter the password and tap Validate."
            default:
                return "Failed to import certificate (Security error \(status)). Please verify the file and password are correct."
            }
        case .noIdentityFound:
            return "No client identity found in the certificate file. The .p12/.pfx may only contain CA certificates without a private key."
        case .identityExtraction(let status):
            return "Could not read certificate details (error \(status))."
        case .invalidCertificate:
            return "The certificate file is invalid or corrupted."
        }
    }
}

final class MTLSURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: SecIdentity?

    init(identity: SecIdentity?) {
        self.identity = identity
        super.init()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            guard let identity else {
                AppLogger.network.info("No client identity available")
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            return
        }

        if method == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust {
                let host = challenge.protectionSpace.host
                if NetworkHostUtils.isLocalNetworkHost(host) {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
