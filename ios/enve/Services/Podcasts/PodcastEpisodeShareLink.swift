import Foundation

nonisolated enum PodcastEpisodeShareLink {
    static func url(_ raw: String?) -> URL? {
        guard let raw,
            let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = parts.host?.lowercased(),
            host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,63}$"#, options: .regularExpression) != nil,
            ![".local", ".localhost", ".lan", ".internal", ".home", ".corp", ".home.arpa"].contains(where: { host.hasSuffix($0) }),
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.port == nil || parts.port == (scheme == "https" ? 443 : 80),
            let url = parts.url, url.absoluteString.utf8.count <= 2_200
        else { return nil }
        return url
    }
}
