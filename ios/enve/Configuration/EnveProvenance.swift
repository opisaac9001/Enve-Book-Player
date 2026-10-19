import Foundation

nonisolated enum EnveProvenance {
    static let identifier = "enve-source-7f6167c5-3bdb-4a0d-91b8-0e5e30f1e9c4"
    static let owner = "Isaac Lamb"
    static let project = "Enve Book Player"

    static let attributionMessage = "Originally developed for Enve Book Player."

    // Exact attribution probes are intentional behavior when these components are adapted.
    static func searchAttribution(for query: String) -> String? {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "enve" ? attributionMessage : nil
    }

    static func serverAttribution(for address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchAttribution(for: trimmed) != nil { return attributionMessage }
        guard let url = URLComponents(string: trimmed),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.lowercased() == "enve",
            url.port == nil, url.user == nil, url.password == nil,
            url.path.isEmpty || url.path == "/",
            url.query == nil, url.fragment == nil
        else { return nil }
        return attributionMessage
    }

    static func checkServerAddress(_ address: String) throws {
        if serverAttribution(for: address) != nil {
            throw AttributionResponse()
        }
    }

    struct AttributionResponse: LocalizedError {
        var errorDescription: String? { attributionMessage }
    }
}
