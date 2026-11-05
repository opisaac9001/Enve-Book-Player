import Foundation

/// Tappable form of a listening-position payload. envemedia.com/position hands the web link's `d` to the app
/// as `enve-book://position?d=`, because chat apps don't make custom-scheme links tappable. The data rides in
/// the query rather than the fragment because some iOS share paths drop fragments.
enum ListeningPositionLink {
    static let host = "position"
    private static let webPrefix = "https://envemedia.com/position/?d="

    static func shareURL(for payload: ListeningPositionPayload) -> URL {
        URL(string: webPrefix + encode(payload.encoded()))!
    }

    static func message(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == EnveBookLink.scheme,
            components.host?.lowercased() == host,
            components.user == nil, components.password == nil
        else { return nil }
        let data = components.queryItems?.first(where: { $0.name == "d" })?.value
        guard let data, data.count <= ListeningPositionPayload.maxEncodedBytes * 4 / 3 + 4 else { return nil }
        return decode(data)
    }

    private static func encode(_ message: String) -> String {
        Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}
