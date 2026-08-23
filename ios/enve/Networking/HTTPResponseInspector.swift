import Foundation

enum HTTPResponseInspector {
    // Login walls sometimes return markup without a text/html content type.
    static func looksLikeHTML(data: Data, response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/html") { return true }
        guard data.count > 5 else { return false }
        return String(data: data.prefix(20), encoding: .utf8)?.contains("<") == true
    }

    static func mergedCookieHeader(existing: String?, response: HTTPURLResponse) -> String? {
        guard let responseURL = response.url else { return nil }

        let fieldMap = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String,
                let value = entry.value as? String
            else { return }
            result[key] = value
        }
        guard !fieldMap.isEmpty else { return nil }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fieldMap, for: responseURL)
        guard !cookies.isEmpty else { return nil }

        var merged: [(name: String, value: String)] = []
        var indexByName: [String: Int] = [:]
        for pair in (existing ?? "").split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator])
            indexByName[name] = merged.count
            merged.append((name, String(trimmed[trimmed.index(after: separator)...])))
        }
        for cookie in cookies {
            if let existingIndex = indexByName[cookie.name] {
                merged[existingIndex].value = cookie.value
            } else {
                indexByName[cookie.name] = merged.count
                merged.append((cookie.name, cookie.value))
            }
        }

        let header = merged.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }
}
