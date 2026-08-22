import Foundation

enum ProviderType: String, Codable, CaseIterable {
    case audiobookshelf
    case plex
    case jellyfin
    case emby
    case webdav
    case torbox
    case premiumize
    case realdebrid
    case local
    case booklore = "grimmory"
    case komga
    case kavita
    case opds
    case storyteller
    case bookOrbit = "bookorbit"
    case silo

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue.lowercased() {
        case "booklore", "grimmory":
            self = .booklore
        case "komga":
            self = .komga
        case "kavita":
            self = .kavita
        case "opds":
            self = .opds
        case "storyteller":
            self = .storyteller
        case "bookorbit":
            self = .bookOrbit
        case "silo":
            self = .silo
        default:
            guard let value = ProviderType(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown provider type: \(rawValue)"
                )
            }
            self = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var iconName: String {
        switch self {
        case .audiobookshelf: return "books.vertical"
        case .plex: return "play.tv"
        case .jellyfin: return "film"
        case .emby: return "tv"
        case .webdav: return "externaldrive.connected.to.line.below.fill"
        case .torbox: return "shippingbox"
        case .premiumize: return "cloud.fill"
        case .realdebrid: return "link.circle.fill"
        case .local: return "folder"
        case .booklore: return "pawprint.fill"
        case .komga: return "books.vertical"
        case .kavita: return "text.book.closed"
        case .opds: return "antenna.radiowaves.left.and.right"
        case .storyteller: return "text.book.closed.fill"
        case .bookOrbit: return "circle.hexagongrid.fill"
        case .silo: return "server.rack"
        }
    }

    var assetIconName: String? {
        switch self {
        case .audiobookshelf: return "AudiobookshelfLogo"
        case .plex: return "PlexLogo"
        case .jellyfin: return "JellyfinLogo"
        case .emby: return "EmbyLogo"
        case .booklore: return "GrimmoryLogo"
        case .komga: return "KomgaLogo"
        case .kavita: return "KavitaLogo"
        case .opds: return "OPDSLogo"
        case .storyteller: return "StorytellerLogo"
        case .webdav: return "WebDAVLogo"
        case .torbox: return "TorBoxLogo"
        case .premiumize: return "PremiumizeLogo"
        case .realdebrid: return "RealDebridLogo"
        case .bookOrbit: return "BookOrbitLogo"
        case .silo: return "SiloLogo"
        case .local: return nil
        }
    }
}

public enum ConnectionAuthMode: String, Codable, CaseIterable {
    case auto
    case usernamePassword
    case token
    case sso

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .usernamePassword: return "Username & Password"
        case .token: return "Token / API Key"
        case .sso: return "SSO"
        }
    }
}

struct ServerConnection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var type: ProviderType
    var username: String?
    var password: String?
    var token: String?
    var userId: String?
    var isConnected: Bool = false
    var lastVerified: Date?
    var selectedLibraryIds: Set<String>?
    var isArchived: Bool = false
    var rootPath: String?
    var customHeaders: [String: String]?
    var secretCustomHeaderNames: Set<String> = []
    var authMode: ConnectionAuthMode = .auto
    var mtlsEnabled: Bool = false

    var grimmoryOIDCRedirectURI: String?
    var komgaOAuthProviderId: String?

    var plexHomeUserId: String?
    var plexHomeUserName: String?
    var plexHomeUserThumb: String?
    var plexHomeUserToken: String?
    var plexHomeUserIsManaged: Bool?
    var plexOwnerToken: String?

    var effectivePlexToken: String? {
        if type == .plex, let homeToken = plexHomeUserToken, !homeToken.isEmpty {
            return homeToken
        }
        return token
    }

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        type: ProviderType,
        username: String? = nil,
        password: String? = nil,
        token: String? = nil,
        userId: String? = nil,
        isConnected: Bool = false,
        lastVerified: Date? = nil,
        selectedLibraryIds: Set<String>? = nil,
        isArchived: Bool = false,
        rootPath: String? = nil,
        customHeaders: [String: String]? = nil,
        secretCustomHeaderNames: Set<String> = [],
        authMode: ConnectionAuthMode = .auto,
        mtlsEnabled: Bool = false,
        grimmoryOIDCRedirectURI: String? = nil,
        komgaOAuthProviderId: String? = nil,
        plexHomeUserId: String? = nil,
        plexHomeUserName: String? = nil,
        plexHomeUserThumb: String? = nil,
        plexHomeUserToken: String? = nil,
        plexHomeUserIsManaged: Bool? = nil,
        plexOwnerToken: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.type = type
        self.username = username
        self.password = password
        self.token = token
        self.userId = userId
        self.isConnected = isConnected
        self.lastVerified = lastVerified
        self.selectedLibraryIds = selectedLibraryIds
        self.isArchived = isArchived
        self.rootPath = rootPath
        self.customHeaders = customHeaders
        self.secretCustomHeaderNames = secretCustomHeaderNames.union(Self.secretHeaderNames(in: customHeaders))
        self.authMode = authMode
        self.mtlsEnabled = mtlsEnabled
        self.grimmoryOIDCRedirectURI = grimmoryOIDCRedirectURI
        self.komgaOAuthProviderId = komgaOAuthProviderId
        self.plexHomeUserId = plexHomeUserId
        self.plexHomeUserName = plexHomeUserName
        self.plexHomeUserThumb = plexHomeUserThumb
        self.plexHomeUserToken = plexHomeUserToken
        self.plexHomeUserIsManaged = plexHomeUserIsManaged
        self.plexOwnerToken = plexOwnerToken
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, type, username, password, token, userId, isConnected, lastVerified, selectedLibraryIds, isArchived, rootPath,
            customHeaders, secretCustomHeaderNames, authMode, mtlsEnabled
        case grimmoryOIDCRedirectURI, komgaOAuthProviderId
        case plexHomeUserId, plexHomeUserName, plexHomeUserThumb, plexHomeUserToken, plexHomeUserIsManaged, plexOwnerToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        type = try container.decode(ProviderType.self, forKey: .type)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
        lastVerified = try container.decodeIfPresent(Date.self, forKey: .lastVerified)
        selectedLibraryIds = try container.decodeIfPresent(Set<String>.self, forKey: .selectedLibraryIds)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders)
        secretCustomHeaderNames = try container.decodeIfPresent(Set<String>.self, forKey: .secretCustomHeaderNames) ?? []
        secretCustomHeaderNames.formUnion(Self.secretHeaderNames(in: customHeaders))
        authMode = try container.decodeIfPresent(ConnectionAuthMode.self, forKey: .authMode) ?? .auto
        mtlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .mtlsEnabled) ?? false
        grimmoryOIDCRedirectURI = try container.decodeIfPresent(String.self, forKey: .grimmoryOIDCRedirectURI)
        komgaOAuthProviderId = try container.decodeIfPresent(String.self, forKey: .komgaOAuthProviderId)
        plexHomeUserId = try container.decodeIfPresent(String.self, forKey: .plexHomeUserId)
        plexHomeUserName = try container.decodeIfPresent(String.self, forKey: .plexHomeUserName)
        plexHomeUserThumb = try container.decodeIfPresent(String.self, forKey: .plexHomeUserThumb)
        plexHomeUserToken = try container.decodeIfPresent(String.self, forKey: .plexHomeUserToken)
        plexHomeUserIsManaged = try container.decodeIfPresent(Bool.self, forKey: .plexHomeUserIsManaged)
        plexOwnerToken = try container.decodeIfPresent(String.self, forKey: .plexOwnerToken)

        hydrateSecretsFromSharedKeychain()
    }

    func encode(to encoder: Encoder) throws {
        let secretHeaderNames = allSecretCustomHeaderNames()
        let hasPersistableSecrets =
            (token?.isEmpty == false)
            || (password?.isEmpty == false)
            || (plexHomeUserToken?.isEmpty == false)
            || (plexOwnerToken?.isEmpty == false)
            || secretHeaderNames.contains { Self.headerValue(in: customHeaders, for: $0)?.isEmpty == false }

        if hasPersistableSecrets && !persistSecretsToSharedKeychain() {
            throw EncodingError.invalidValue(
                id,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Connection secrets could not be persisted to the keychain."
                )
            )
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encode(isConnected, forKey: .isConnected)
        try container.encodeIfPresent(lastVerified, forKey: .lastVerified)
        try container.encodeIfPresent(selectedLibraryIds, forKey: .selectedLibraryIds)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(rootPath, forKey: .rootPath)
        try container.encodeIfPresent(publicCustomHeadersForPersistence(), forKey: .customHeaders)
        if !secretHeaderNames.isEmpty {
            try container.encode(secretHeaderNames.sorted(), forKey: .secretCustomHeaderNames)
        }
        try container.encode(authMode, forKey: .authMode)
        try container.encode(mtlsEnabled, forKey: .mtlsEnabled)
        try container.encodeIfPresent(grimmoryOIDCRedirectURI, forKey: .grimmoryOIDCRedirectURI)
        try container.encodeIfPresent(komgaOAuthProviderId, forKey: .komgaOAuthProviderId)
        try container.encodeIfPresent(plexHomeUserId, forKey: .plexHomeUserId)
        try container.encodeIfPresent(plexHomeUserName, forKey: .plexHomeUserName)
        try container.encodeIfPresent(plexHomeUserThumb, forKey: .plexHomeUserThumb)
        try container.encodeIfPresent(plexHomeUserIsManaged, forKey: .plexHomeUserIsManaged)
    }

    @discardableResult
    func persistSecretsToSharedKeychain() -> Bool {
        let connectionId = id.uuidString
        let keychain = SharedKeychainStore.shared
        var success = true

        if let token, !token.isEmpty {
            success = keychain.setToken(token, forConnectionId: connectionId) && success
        }
        if let password, !password.isEmpty {
            success = keychain.setPassword(password, forConnectionId: connectionId) && success
        }
        if let plexHomeUserToken, !plexHomeUserToken.isEmpty {
            success = keychain.setPlexHomeUserToken(plexHomeUserToken, forConnectionId: connectionId) && success
        }
        if let plexOwnerToken, !plexOwnerToken.isEmpty {
            success = keychain.setPlexOwnerToken(plexOwnerToken, forConnectionId: connectionId) && success
        }

        for headerName in allSecretCustomHeaderNames() {
            guard let value = Self.headerValue(in: customHeaders, for: headerName), !value.isEmpty else {
                continue
            }
            success = keychain.setCustomHeaderValue(value, headerName: headerName, forConnectionId: connectionId) && success
        }
        return success
    }

    mutating func hydrateSecretsFromSharedKeychain() {
        let connectionId = id.uuidString
        let keychain = SharedKeychainStore.shared

        if let storedToken = keychain.token(forConnectionId: connectionId) {
            token = storedToken
        } else if let token, !token.isEmpty {
            keychain.setToken(token, forConnectionId: connectionId)
        }

        if let storedPassword = keychain.password(forConnectionId: connectionId) {
            password = storedPassword
        } else if let password, !password.isEmpty {
            keychain.setPassword(password, forConnectionId: connectionId)
        }

        if let storedHomeUserToken = keychain.plexHomeUserToken(forConnectionId: connectionId) {
            plexHomeUserToken = storedHomeUserToken
        } else if let plexHomeUserToken, !plexHomeUserToken.isEmpty {
            keychain.setPlexHomeUserToken(plexHomeUserToken, forConnectionId: connectionId)
        }

        if let storedOwnerToken = keychain.plexOwnerToken(forConnectionId: connectionId) {
            plexOwnerToken = storedOwnerToken
        } else if let plexOwnerToken, !plexOwnerToken.isEmpty {
            keychain.setPlexOwnerToken(plexOwnerToken, forConnectionId: connectionId)
        }

        secretCustomHeaderNames.formUnion(Self.secretHeaderNames(in: customHeaders))
        let secretHeaderNames = allSecretCustomHeaderNames()
        guard !secretHeaderNames.isEmpty else { return }

        var headers = customHeaders ?? [:]
        for headerName in secretHeaderNames {
            if let storedValue = keychain.customHeaderValue(headerName: headerName, forConnectionId: connectionId) {
                Self.setHeaderValue(storedValue, for: headerName, in: &headers)
            } else if let value = Self.headerValue(in: headers, for: headerName), !value.isEmpty {
                keychain.setCustomHeaderValue(value, headerName: headerName, forConnectionId: connectionId)
            }
        }
        customHeaders = headers.isEmpty ? nil : headers
    }

    func publicCustomHeadersForPersistence() -> [String: String]? {
        guard let customHeaders else { return nil }

        let secretHeaderNames = Set(allSecretCustomHeaderNames().map(Self.normalizedHeaderName))
        let publicHeaders = customHeaders.filter { headerName, value in
            !secretHeaderNames.contains(Self.normalizedHeaderName(headerName)) && !Self.headerValueLooksSecret(value)
        }
        return publicHeaders.isEmpty ? nil : publicHeaders
    }

    func allSecretCustomHeaderNames() -> Set<String> {
        secretCustomHeaderNames.union(Self.secretHeaderNames(in: customHeaders))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func headerValue(in headers: [String: String]?, for headerName: String) -> String? {
        guard let headers else { return nil }
        let normalized = normalizedHeaderName(headerName)
        return headers.first { normalizedHeaderName($0.key) == normalized }?.value
    }

    static func setHeaderValue(_ value: String, for headerName: String, in headers: inout [String: String]) {
        let normalized = normalizedHeaderName(headerName)
        if let existingKey = headers.keys.first(where: { normalizedHeaderName($0) == normalized }) {
            headers[existingKey] = value
        } else {
            headers[headerName] = value
        }
    }

    static func normalizedHeaderName(_ headerName: String) -> String {
        headerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func secretHeaderNames(in headers: [String: String]?) -> Set<String> {
        guard let headers else { return [] }
        return Set(
            headers.compactMap { headerName, value in
                isSecretHeaderName(headerName) || headerValueLooksSecret(value) ? headerName : nil
            }
        )
    }

    private static func isSecretHeaderName(_ headerName: String) -> Bool {
        let normalized = normalizedHeaderName(headerName)
        guard !normalized.isEmpty else { return false }

        let exactSecretNames: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "cf-access-client-secret",
            "x-api-key",
            "x-auth-token",
            "x-access-token",
        ]
        if exactSecretNames.contains(normalized) || normalized.hasSuffix("-authorization") {
            return true
        }

        let secretFragments = ["token", "secret", "api-key", "apikey", "password", "passwd", "credential", "session"]
        return secretFragments.contains { normalized.contains($0) }
    }

    private static func headerValueLooksSecret(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("cf-access-client-secret") || lowercased.contains("cf_authorization=")
    }
}

extension ServerConnection {
    var iconAssetName: String? {
        if type == .webdav {
            return webDAVPreset?.assetIconName ?? type.assetIconName
        }
        return type.assetIconName
    }

    var iconSystemName: String {
        if type == .webdav {
            return webDAVPreset?.systemIconName ?? type.iconName
        }
        return type.iconName
    }

    private var webDAVPreset: UnifiedWebDAVPreset? {
        guard type == .webdav, let host = URL(string: url)?.host?.lowercased() else {
            return nil
        }

        if host.contains("torbox") {
            return .torbox
        }
        if host.contains("premiumize") {
            return .premiumize
        }
        if host.contains("real-debrid") || host.contains("realdebrid") {
            return .realdebrid
        }
        return .generic
    }
}

enum CloudflareAccessHeaders {
    static let clientIdHeader = "CF-Access-Client-Id"
    static let clientSecretHeader = "CF-Access-Client-Secret"
    static let cookieHeader = "Cookie"

    static func mergedHeaders(
        existingHeaders: [String: String]? = nil,
        browserHeaders: [String: String]? = nil,
        clientId: String,
        clientSecret: String,
        singleHeaderName: String = ""
    ) -> [String: String]? {
        var headers = existingHeaders ?? [:]
        removeServiceTokenHeaders(from: &headers)

        if let browserCookie = headerValue(named: cookieHeader, in: browserHeaders) {
            removeHeader(named: cookieHeader, from: &headers)
            headers[cookieHeader] = browserCookie
        }

        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedClientId.isEmpty && !trimmedClientSecret.isEmpty {
            headers[clientIdHeader] = trimmedClientId
            headers[clientSecretHeader] = trimmedClientSecret
        }

        return headers.isEmpty ? nil : headers
    }

    struct AccessRedirectDetails: Decodable, Sendable {
        let redirectURL: String?
        let authStatus: String?
        let serviceTokenStatus: Bool?

        private enum CodingKeys: String, CodingKey {
            case redirectURL = "redirect_url"
            case authStatus = "auth_status"
            case serviceTokenStatus = "service_token_status"
        }
    }

    static func accessRedirectLocation(in response: HTTPURLResponse) -> String? {
        guard response.statusCode == 302 || response.statusCode == 303,
            let location = response.value(forHTTPHeaderField: "Location"),
            isAccessRedirect(location)
        else {
            return nil
        }
        return location
    }

    static func isAccessRedirect(_ location: String) -> Bool {
        let lowercased = location.lowercased()
        return lowercased.contains("cloudflareaccess.com") || lowercased.contains("/cdn-cgi/access/")
    }

    /// The `meta` parameter is a JWT-shaped token; only its payload segment carries the denial reason.
    static func accessRedirectDetails(from location: String) -> AccessRedirectDetails? {
        guard let components = URLComponents(string: location),
            let metaToken = components.queryItems?.first(where: { $0.name == "meta" })?.value
        else {
            return nil
        }

        let segments = metaToken.split(separator: ".")
        guard segments.count >= 2,
            let payload = base64URLDecoded(String(segments[1]))
        else {
            return nil
        }

        return try? JSONDecoder().decode(AccessRedirectDetails.self, from: payload)
    }

    static func accessRejectionMessage(location: String, endpoint: String) -> String {
        guard let details = accessRedirectDetails(from: location) else {
            return "Cloudflare Access rejected the request. "
                + "Your service token may be invalid, expired, or not associated with the correct Access policy. "
                + "Try using 'Login with Browser' instead, or verify your Cloudflare service token in the Zero Trust dashboard."
        }

        var message = "Cloudflare Access rejected the request to \(endpoint)."

        if details.serviceTokenStatus == false {
            message +=
                " Cloudflare reported service_token_status=false, which means the service token was not accepted for this Access application."
        }

        if let authStatus = details.authStatus, !authStatus.isEmpty, authStatus != "NONE" {
            message += " auth_status=\(authStatus)."
        }

        if let redirectURL = details.redirectURL, !redirectURL.isEmpty {
            message += " redirect_url=\(redirectURL)."
        }

        message +=
            " Check the Zero Trust Access policy for this app and ensure it includes a Service Auth rule for the specific service token you entered."
        return message
    }

    static func htmlBodyIndicatesAccessBlock(_ data: Data) -> Bool {
        guard let preview = String(data: data.prefix(200), encoding: .utf8)?.lowercased() else { return false }
        return preview.contains("cloudflare access") || preview.contains("cloudflareaccess")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding != 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }

        return Data(base64Encoded: base64)
    }

    static func detectedServiceTokenConfiguration(
        from headers: [String: String]?
    ) -> (clientId: String, clientSecret: String, singleHeaderName: String?)? {
        guard let headers else { return nil }

        if let clientId = headers[clientIdHeader],
            let clientSecret = headers[clientSecretHeader]
        {
            return (clientId, clientSecret, nil)
        }

        for (_, value) in headers {
            if let payload = decodeSingleHeaderPayload(from: value) {
                return (payload.clientId, payload.clientSecret, nil)
            }
        }

        return nil
    }

    static func detectedBrowserHeaders(from headers: [String: String]?) -> [String: String]? {
        guard let cookieValue = headerValue(named: cookieHeader, in: headers), !cookieValue.isEmpty else {
            return nil
        }
        return [cookieHeader: cookieValue]
    }

    private static func headerValue(named name: String, in headers: [String: String]?) -> String? {
        headers?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func removeHeader(named name: String, from headers: inout [String: String]) {
        let matchingKeys = headers.keys.filter { $0.caseInsensitiveCompare(name) == .orderedSame }
        for key in matchingKeys {
            headers.removeValue(forKey: key)
        }
    }

    private static func removeServiceTokenHeaders(from headers: inout [String: String]) {
        headers.removeValue(forKey: clientIdHeader)
        headers.removeValue(forKey: clientSecretHeader)

        let headerNamesToRemove = headers.compactMap { headerName, value in
            decodeSingleHeaderPayload(from: value) != nil ? headerName : nil
        }

        for headerName in headerNamesToRemove {
            headers.removeValue(forKey: headerName)
        }
    }

    private static func decodeSingleHeaderPayload(from value: String) -> (clientId: String, clientSecret: String)? {
        guard let data = value.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let clientId = payload["cf-access-client-id"],
            let clientSecret = payload["cf-access-client-secret"]
        else {
            return nil
        }

        return (clientId, clientSecret)
    }
}

struct Library: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let type: String
    let providerId: UUID

    var uniqueId: String {
        "\(providerId)_\(id)"
    }
}

public struct Chapter: Identifiable, Codable, Hashable {
    public let id: String
    public let start: Double
    public let end: Double
    public let title: String
    public var index: Int = 0

    public init(id: String, start: Double, end: Double, title: String, index: Int = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
        self.index = index
    }

    public var duration: Double { end - start }

    public var startTime: Double { start }
    public var endTime: Double { end }

    enum CodingKeys: String, CodingKey {
        case id, start, end, title, index
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)

        start = try container.decodeIfPresent(Double.self, forKey: .start) ?? 0.0
        end = try container.decodeIfPresent(Double.self, forKey: .end) ?? 0.0
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
    }

    init(id: String, title: String, startTime: Double, endTime: Double, duration: Double? = nil, index: Int = 0) {
        self.id = id
        self.title = title
        self.start = startTime
        self.end = endTime
        self.index = index
    }

    init(id: String, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
        self.index = 0
    }
}

struct SeriesInfo: Codable, Hashable {
    let name: String
    let sequence: String?
}

struct Author: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let photoURL: URL?
}

struct Series: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let description: String?
    let books: [String]
    let bookSequences: [String: String]
    let bookCount: Int
    let libraryId: String
    let providerId: UUID
}

struct Collection: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let books: [String]
    let bookCount: Int
    let iconName: String
    let color: String
    let providerId: UUID?

    var parentID: String?
    var customCoverPath: String?
    var isSystem: Bool = false
    var isUserGenerated: Bool = false
    var remoteId: String?
    var serverIcon: String?
    var syncToKobo: Bool = false
    var displayOrder: Int = 0
    var isServerEditable: Bool = false

    var representativeThumbs: [String] = []

    var scopedID: String {
        "\(providerId?.uuidString ?? "local")-\(id)"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        books = try c.decodeIfPresent([String].self, forKey: .books) ?? []
        bookCount = try c.decodeIfPresent(Int.self, forKey: .bookCount) ?? 0
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName) ?? "books.vertical"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        providerId = try c.decodeIfPresent(UUID.self, forKey: .providerId)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        customCoverPath = try c.decodeIfPresent(String.self, forKey: .customCoverPath)
        isSystem = try c.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        isUserGenerated = try c.decodeIfPresent(Bool.self, forKey: .isUserGenerated) ?? false
        remoteId = try c.decodeIfPresent(String.self, forKey: .remoteId)
        serverIcon = try c.decodeIfPresent(String.self, forKey: .serverIcon)
        syncToKobo = try c.decodeIfPresent(Bool.self, forKey: .syncToKobo) ?? false
        displayOrder = try c.decodeIfPresent(Int.self, forKey: .displayOrder) ?? 0
        isServerEditable = try c.decodeIfPresent(Bool.self, forKey: .isServerEditable) ?? false
    }

    nonisolated init(
        id: String,
        name: String,
        description: String?,
        books: [String],
        bookCount: Int,
        iconName: String,
        color: String,
        providerId: UUID?,
        parentID: String? = nil,
        customCoverPath: String? = nil,
        isSystem: Bool = false,
        isUserGenerated: Bool = false,
        remoteId: String? = nil,
        serverIcon: String? = nil,
        syncToKobo: Bool = false,
        displayOrder: Int = 0,
        isServerEditable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.books = books
        self.bookCount = bookCount
        self.iconName = iconName
        self.color = color
        self.providerId = providerId
        self.parentID = parentID
        self.customCoverPath = customCoverPath
        self.isSystem = isSystem
        self.isUserGenerated = isUserGenerated
        self.remoteId = remoteId
        self.serverIcon = serverIcon
        self.syncToKobo = syncToKobo
        self.displayOrder = displayOrder
        self.isServerEditable = isServerEditable
    }
}
