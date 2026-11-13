import Foundation

nonisolated enum PodcastFeedURL {
    nonisolated enum PrivacyConcern: Equatable, Sendable {
        case credentials
        case accessKey
        case privateFeed
        case opaqueToken

        var explanation: String {
            switch self {
            case .credentials: "Contains a username or password"
            case .accessKey: "Contains an access key"
            case .privateFeed: "Looks like a private or supporter feed"
            case .opaqueToken: "Contains what looks like a personal token"
            }
        }
    }

    private static let schemeAliases = ["feed:", "itpc:", "pcast:", "podcast:"]
    private static let sensitiveQueryNames: Set<String> = [
        "key", "sig", "pass", "pwd", "sid", "hash", "code", "jwt", "login", "user", "username", "email",
    ]
    private static let sensitiveQueryFragments = [
        "token", "auth", "secret", "signature", "password", "apikey", "api_key", "accesskey", "access_key", "session",
    ]
    private static let privatePathSegments: Set<String> = [
        "private", "premium", "patron", "patrons", "member", "members", "subscriber", "subscribers", "supporter",
        "supporters", "paid",
    ]
    private static let privateHostSuffixes = [
        "patreon.com", "supercast.com", "supercast.tech", "supportingcast.fm", "memberful.com", "memberfulcontent.com",
        "glow.fm", "subscribestar.com", "subscribestar.adult",
    ]

    /// Returns an http(s) URL with feed-scheme aliases resolved, a lowercased host, and no fragment or default port.
    static func canonical(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096 else { return nil }
        let lowered = text.lowercased()
        if let alias = schemeAliases.first(where: { lowered.hasPrefix($0) }) {
            let rest = text.dropFirst(alias.count)
            text = rest.hasPrefix("//") ? "http:" + rest : String(rest)
        }
        guard var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.string
    }

    /// Identity used for duplicate detection; http and https spellings of one feed share a key.
    static func key(_ raw: String) -> String {
        guard let canonical = canonical(raw) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if canonical.hasPrefix("https://") { return String(canonical.dropFirst(8)) }
        if canonical.hasPrefix("http://") { return String(canonical.dropFirst(7)) }
        return canonical
    }

    /// Conservative: plain public feeds with harmless query items (format, id, page) are not flagged.
    static func privacyConcern(_ raw: String) -> PrivacyConcern? {
        guard let components = URLComponents(string: canonical(raw) ?? raw) else { return nil }
        if components.user != nil || components.password != nil { return .credentials }

        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if sensitiveQueryNames.contains(name) || sensitiveQueryFragments.contains(where: { name.contains($0) }) {
                return .accessKey
            }
            if let value = item.value, isOpaqueToken(value) { return .accessKey }
        }

        let host = (components.host ?? "").lowercased()
        if privateHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .privateFeed }

        let segments = components.path.split(separator: "/").map(String.init)
        if segments.contains(where: { privatePathSegments.contains($0.lowercased()) }) { return .privateFeed }
        if segments.contains(where: { isOpaqueToken(($0 as NSString).deletingPathExtension) }) { return .opaqueToken }
        return nil
    }

    // 32+ mixed letters and digits; shorter IDs (Acast's 24-character show IDs) and plain UUIDs are public identifiers.
    private static func isOpaqueToken(_ value: String) -> Bool {
        guard value.count >= 32, UUID(uuidString: value) == nil else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard value.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return false }
        return value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
    }
}
