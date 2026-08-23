import Foundation
import Logging

enum ServerURLNormalizer {

    static func normalize(rawURL: String, providerType: ProviderType) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = ensureScheme(trimmed, providerType: providerType)
        let withoutTrailingSlash = stripTrailingSlashes(withScheme)
        return URL(string: withoutTrailingSlash)
    }

    private static func ensureScheme(_ raw: String, providerType: ProviderType) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return raw
        }
        return inferDefaultScheme(for: raw, providerType: providerType) + raw
    }

    private static func inferDefaultScheme(for raw: String, providerType: ProviderType) -> String {
        switch providerType {
        case .jellyfin, .emby:
            if raw.contains(":8920") { return "https://" }
            if raw.contains(":8096") { return "http://" }
            return isLikelyLocalHost(raw) ? "http://" : "https://"
        case .booklore:
            return "http://"
        default:
            return isLikelyLocalHost(raw) ? "http://" : "https://"
        }
    }

    private static func stripTrailingSlashes(_ str: String) -> String {
        var result = str
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func isLikelyLocalHost(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.hasPrefix("localhost") || lower.contains("://localhost") { return true }
        if lower.hasPrefix("127.") || lower.contains("://127.") { return true }
        if lower.hasSuffix(".local") || lower.hasSuffix(".lan") { return true }
        if lower.contains(".local:") || lower.contains(".lan:") { return true }
        if lower.hasPrefix("10.") || lower.contains("://10.") { return true }
        if lower.hasPrefix("192.168.") || lower.contains("://192.168.") { return true }
        if lower.hasPrefix("172.") || lower.contains("://172.") {

            let token =
                lower
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            let parts = token.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}

#if DEBUG
extension ServerURLNormalizer {

    static func compareAgainstFixture(
        rawURL: String,
        providerType: ProviderType,
        expected: String,
        site: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let normalized = normalize(rawURL: rawURL, providerType: providerType)?.absoluteString ?? ""
        guard normalized != expected else { return }
        AppLogger.network.warning(
            "[ServerURLNormalizer] divergence at \(site): raw=\(rawURL) provider=\(providerType.rawValue) normalised=\(normalized) expected=\(expected) (\(file):\(line))"
        )
    }
}
#endif
