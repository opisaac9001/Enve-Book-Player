import Foundation

struct BookloreJWT {
    let exp: TimeInterval?
    let nbf: TimeInterval?

    static func normalizedToken(_ value: String) -> String? {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { return nil }
        return token
    }

    init?(_ token: String) {
        guard let token = Self.normalizedToken(token) else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        exp = json["exp"] as? TimeInterval
        nbf = json["nbf"] as? TimeInterval
    }

    func isActive(at date: Date = Date()) -> Bool {
        guard let nbf else { return true }
        return date.timeIntervalSince1970 >= nbf
    }

    func isExpiring(buffer: TimeInterval = 60) -> Bool {
        guard let exp else { return false }
        return Date().timeIntervalSince1970 >= exp - buffer
    }
}
