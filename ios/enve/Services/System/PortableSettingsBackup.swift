import CommonCrypto
import CryptoKit
import Foundation

struct PortableSettingsBackup: Codable {
    let settings: SettingsBackupDocument?
    let sources: [Source]
    var integrations: Integrations?
    var sharedSettings: SharedSettings?

    struct SharedSettings: Codable {
        var themeMode: String?
        var defaultSpeed: Double?
        var skipForwardSeconds: Int?
        var skipBackwardSeconds: Int?
        var readingEnabled: Bool?
        var accentHex: String?

        init(_ preferences: UserPreferences) {
            themeMode = preferences.theme == .oled ? "DARK" : preferences.theme.rawValue.uppercased()
            defaultSpeed = preferences.playbackSpeed
            skipForwardSeconds = Int(exactly: preferences.skipForwardAmount)
            skipBackwardSeconds = Int(exactly: preferences.skipBackwardAmount)
            readingEnabled = preferences.readingEnabled
            let channels = [preferences.primaryColorRed, preferences.primaryColorGreen, preferences.primaryColorBlue]
            if channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                accentHex = "#" + channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
            }
        }

        func apply(to preferences: inout UserPreferences) {
            if let themeMode, let theme = UserPreferences.AppTheme(rawValue: themeMode.lowercased()) {
                preferences.theme = theme
            }
            if let defaultSpeed, (0.25...4).contains(defaultSpeed) { preferences.playbackSpeed = defaultSpeed }
            if let skipForwardSeconds, (1...300).contains(skipForwardSeconds) {
                preferences.skipForwardAmount = Double(skipForwardSeconds)
            }
            if let skipBackwardSeconds, (1...300).contains(skipBackwardSeconds) {
                preferences.skipBackwardAmount = Double(skipBackwardSeconds)
            }
            if let readingEnabled { preferences.readingEnabled = readingEnabled }
            if let accentHex {
                let raw = accentHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                if raw.count == 6, let value = UInt32(raw, radix: 16) {
                    preferences.primaryColorRed = CGFloat((value >> 16) & 255) / 255
                    preferences.primaryColorGreen = CGFloat((value >> 8) & 255) / 255
                    preferences.primaryColorBlue = CGFloat(value & 255) / 255
                }
            }
        }
    }

    struct Integrations: Codable {
        enum Kind: String, CaseIterable, Identifiable {
            case hardcover, readwise, koreader

            var id: Self { self }
            var name: String {
                switch self {
                case .hardcover: "Hardcover"
                case .readwise: "Readwise"
                case .koreader: "KOReader sync"
                }
            }
        }

        let hasHardcover: Bool
        let hardcoverKey: String?
        let hasReadwise: Bool
        let readwiseKey: String?
        let koreader: KOReaderConfig?

        var available: [Kind] {
            Kind.allCases.filter {
                switch $0 {
                case .hardcover: hasHardcover
                case .readwise: hasReadwise
                case .koreader: koreader != nil
                }
            }
        }

        func needsSignIn(_ kind: Kind) -> Bool {
            switch kind {
            case .hardcover: hardcoverKey?.isEmpty != false
            case .readwise: readwiseKey?.isEmpty != false
            case .koreader: koreader?.passwordHash.isEmpty != false
            }
        }
    }

    struct Source: Codable, Identifiable {
        let id: UUID
        let name: String
        let url: String
        let type: ProviderType
        let username: String?
        let userId: String?
        let selectedLibraryIds: Set<String>?
        let knownLibraryIds: Set<String>?
        let isArchived: Bool
        let rootPath: String?
        let authMode: ConnectionAuthMode
        let mtlsEnabled: Bool
        let grimmoryOIDCRedirectURI: String?
        let komgaOAuthProviderId: String?
        let headers: [String: String]?
        let secretHeaderNames: Set<String>
        let password: String?
        let apiKey: String?
        let needsSignIn: Bool

        var summary: String {
            var parts = [Self.portableAddress(url) ?? type.rawValue]
            if let username, !username.isEmpty { parts.append(username) }
            if isArchived {
                parts.append("Archived")
            } else if needsSignIn {
                parts.append("Sign in or verify after import")
            }
            return parts.joined(separator: " · ")
        }

        init?(_ connection: ServerConnection, includeSignIns: Bool) {
            guard connection.type != .local,
                let address = Self.address(connection.url),
                let portableURL = Self.portableAddress(connection.url)
            else { return nil }

            id = connection.id
            name = connection.name
            type = connection.type
            username = connection.username
            userId = connection.userId
            selectedLibraryIds = connection.selectedLibraryIds
            knownLibraryIds = connection.knownLibraryIds
            isArchived = connection.isArchived
            rootPath = connection.rootPath
            authMode = connection.authMode
            mtlsEnabled = connection.mtlsEnabled
            grimmoryOIDCRedirectURI = connection.grimmoryOIDCRedirectURI
            komgaOAuthProviderId = connection.komgaOAuthProviderId
            secretHeaderNames = connection.allSecretCustomHeaderNames()

            let canCopyCredentials = includeSignIns && authMode != .sso && !mtlsEnabled
            url = portableURL
            headers = canCopyCredentials ? connection.customHeaders?.filter {
                ServerConnection.normalizedHeaderName($0.key) != "cookie"
            } : connection.publicCustomHeadersForPersistence()
            password = canCopyCredentials && connection.password?.isEmpty == false ? connection.password : nil
            apiKey = canCopyCredentials && Self.canCopyAPIKey(type: type, mode: authMode) && connection.token?.isEmpty == false
                ? connection.token : nil
            let hasEmbeddedCredentials = address.user != nil || address.password != nil || address.query != nil
            let canBeAnonymous = (type == .opds || type == .webdav) && authMode == .auto
                && connection.password == nil && connection.token == nil && secretHeaderNames.isEmpty
            let exportedHeaders = headers
            needsSignIn = authMode == .sso || mtlsEnabled || hasEmbeddedCredentials
                || (!canBeAnonymous && password == nil && apiKey == nil)
                || secretHeaderNames.contains { ServerConnection.headerValue(in: exportedHeaders, for: $0) == nil }
        }

        func connection(id: UUID) throws -> ServerConnection {
            guard type != .local, let endpoint = Self.portableAddress(url) else { throw SettingsBackupError.invalidSource }
            let canRestoreCredentials = authMode != .sso && !mtlsEnabled
            var connection = ServerConnection(
                id: id, name: name, url: endpoint, type: type, username: username,
                password: canRestoreCredentials ? password : nil,
                token: canRestoreCredentials && Self.canCopyAPIKey(type: type, mode: authMode) ? apiKey : nil,
                userId: userId, selectedLibraryIds: selectedLibraryIds, isArchived: isArchived,
                rootPath: rootPath, customHeaders: headers, secretCustomHeaderNames: secretHeaderNames,
                authMode: authMode, mtlsEnabled: mtlsEnabled, grimmoryOIDCRedirectURI: grimmoryOIDCRedirectURI,
                komgaOAuthProviderId: komgaOAuthProviderId
            )
            connection.knownLibraryIds = knownLibraryIds
            return connection
        }

        static func portableAddress(_ value: String) -> String? {
            guard var components = address(value) else { return nil }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string
        }

        private static func address(_ value: String) -> URLComponents? {
            guard let components = URLComponents(string: value),
                let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                let host = components.host, !host.isEmpty, components.url != nil
            else { return nil }
            return components
        }

        private static func canCopyAPIKey(type: ProviderType, mode: ConnectionAuthMode) -> Bool {
            guard mode == .token else { return false }
            switch type {
            case .plex, .oneDrive: return false
            default: return true
            }
        }
    }

    struct SourceIdentity: Hashable {
        let type: ProviderType
        let endpoint: String
        let account: String?
        let rootPath: String?

        init(_ connection: ServerConnection) {
            type = connection.type
            var address = Source.portableAddress(connection.url).flatMap(URLComponents.init(string:))
            let scheme = address?.scheme?.lowercased()
            let host = address?.host?.lowercased()
            address?.scheme = scheme
            address?.host = host
            if let scheme = address?.scheme,
                (scheme == "https" && address?.port == 443) || (scheme == "http" && address?.port == 80)
            {
                address?.port = nil
            }
            address?.user = nil
            address?.password = nil
            address?.fragment = nil
            if let path = address?.percentEncodedPath, path.hasSuffix("/") {
                address?.percentEncodedPath = String(path.reversed().drop(while: { $0 == "/" }).reversed())
            }
            endpoint = address?.string ?? connection.url
            account = connection.username?.isEmpty == false ? connection.username : connection.userId
            rootPath = connection.rootPath
        }
    }
}

nonisolated struct EncryptedSettingsBackup: Codable {
    static let format = "enve-settings-backup"
    static let currentVersion = 1
    let format: String
    let version: Int
    let salt: Data
    let payload: Data

    static func seal(_ data: Data, passphrase: String) throws -> Self {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try deriveKey(passphrase, salt: salt)
        let box = try AES.GCM.seal(data, using: key, authenticating: authenticatedHeader(salt))
        guard let combined = box.combined else { throw SettingsBackupError.unreadable }
        return Self(format: format, version: currentVersion, salt: salt, payload: combined)
    }

    func open(passphrase: String) throws -> Data {
        guard format == Self.format, salt.count == 16 else { throw SettingsBackupError.unreadable }
        guard version == Self.currentVersion else { throw SettingsBackupError.unsupportedVersion(version) }
        let key = try Self.deriveKey(passphrase, salt: salt)
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: payload), using: key, authenticating: Self.authenticatedHeader(salt)
            )
        } catch {
            throw SettingsBackupError.cannotUnlock
        }
    }

    private static func authenticatedHeader(_ salt: Data) -> Data {
        Data("\(format):\(currentVersion)".utf8) + salt
    }

    private static func deriveKey(_ passphrase: String, salt: Data) throws -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        guard !password.isEmpty, password.count <= 1024 else { throw SettingsBackupError.invalidPassphrase }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                    output.bindMemory(to: UInt8.self).baseAddress, output.count
                )
            }
        }
        guard status == kCCSuccess else { throw SettingsBackupError.unreadable }
        return SymmetricKey(data: bytes)
    }
}
