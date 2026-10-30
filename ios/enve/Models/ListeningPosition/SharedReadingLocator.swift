import Foundation

nonisolated enum SharedReadingLocator {
    static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func encoded(_ object: [String: Any]) -> String {
        func canonical(_ value: Any) -> String {
            if let object = value as? [String: Any] {
                return "{" + object.keys.sorted().map { canonical($0) + ":" + canonical(object[$0]!) }.joined(separator: ",") + "}"
            }
            if let array = value as? [Any] { return "[" + array.map(canonical).joined(separator: ",") + "]" }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                let value = number.doubleValue
                if value == 0 { return "0" }
                let parts = abs(value).description.lowercased().split(separator: "e")
                let coefficient = String(parts[0])
                let digits = coefficient.replacingOccurrences(of: ".", with: "")
                let point = coefficient.prefix { $0 != "." }.count + (parts.count > 1 ? Int(parts[1])! : 0)
                var result: String
                if point <= 0 {
                    result = "0." + String(repeating: "0", count: -point) + digits
                } else if point >= digits.count {
                    result = digits + String(repeating: "0", count: point - digits.count)
                } else {
                    let split = digits.index(digits.startIndex, offsetBy: point)
                    result = digits[..<split] + "." + digits[split...]
                }
                if result.contains(".") {
                    while result.last == "0" { result.removeLast() }
                    if result.last == "." { result.removeLast() }
                }
                return (value < 0 ? "-" : "") + result
            }
            return String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        }
        return canonical(object)
    }

    static func validCFI(_ value: String) -> Bool {
        guard value.utf8.count <= 2048, value.hasPrefix("epubcfi("), value.hasSuffix(")"),
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let body = String(value.dropFirst(8).dropLast())
        guard !body.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            !body.contains(where: { "<>{}\"'".contains($0) }) else { return false }
        var depth = 0
        var escaped = false
        var bang: String.Index?
        for index in body.indices {
            let character = body[index]
            if escaped { escaped = false; continue }
            if character == "^" { escaped = true; continue }
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1; if depth < 0 { return false } }
            if character == "!", depth == 0 {
                guard bang == nil else { return false }
                bang = index
            }
        }
        guard !escaped, depth == 0, let bang else { return false }
        func path(_ value: Substring, range: Bool) -> Bool {
            func components(_ value: Substring, separator: Character) -> [Substring] {
                var parts: [Substring] = []
                var start = value.startIndex
                var depth = 0
                var escaped = false
                for index in value.indices {
                    let character = value[index]
                    if escaped { escaped = false; continue }
                    if character == "^" { escaped = true; continue }
                    if character == "[" { depth += 1 }
                    if character == "]" { depth -= 1 }
                    if character == separator, depth == 0 {
                        parts.append(value[start..<index])
                        start = value.index(after: index)
                    }
                }
                parts.append(value[start...])
                return parts
            }
            guard value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
            let branches = components(value, separator: ",")
            guard branches.count == 1 || (range && branches.count == 3), !branches[0].isEmpty else { return false }
            if branches.count == 3 && branches.dropFirst().allSatisfy({ $0.isEmpty }) { return false }
            return branches.filter { !$0.isEmpty }.allSatisfy { branch in
                let steps = components(branch, separator: "/")
                return (branch.hasPrefix("/") ? Array(steps.dropFirst()) : steps).allSatisfy {
                    $0.first.map { $0.isASCII && $0.isNumber } == true
                }
            }
        }
        return path(body[..<bang], range: false) && path(body[body.index(after: bang)...], range: true)
    }

    static func sanitized(_ raw: String, strict: Bool) throws(ListeningPositionPayloadError) -> String {
        guard let source = object(raw), let href = source["href"] as? String,
            ListeningPositionReadingLocation.validHref(href)
        else { throw .invalidField("l") }
        let type = (source["type"] as? String).flatMap { ["application/xhtml+xml", "text/html"].contains($0) ? $0 : nil }
        let sourceLocations = source["locations"] as? [String: Any]
        if strict && (type == nil || sourceLocations == nil) { throw .invalidField("l") }
        let inputLocations = sourceLocations ?? [:]
        func text(_ value: Any?, allowControls: Bool = false) -> String? {
            (value as? String).flatMap {
                $0.utf8.count <= 2048 && (allowControls || !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }) ? $0 : nil
            }
        }
        func number(_ value: Any?, maximum: Double, integral: Bool = false, minimum: Double = 0) -> NSNumber? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let n = value.doubleValue
            guard n.isFinite, n >= minimum, n <= maximum, !integral || n == n.rounded() else { return nil }
            return integral ? NSNumber(value: Int64(n)) : value
        }
        func point(_ value: Any?) -> [String: Any]? {
            guard let input = value as? [String: Any], let selector = text(input["cssSelector"]), !selector.isEmpty,
                let index = number(input["textNodeIndex"], maximum: 1_000_000_000, integral: true) else { return nil }
            var result: [String: Any] = ["cssSelector": selector, "textNodeIndex": index]
            if let rawOffset = input["charOffset"] {
                if let offset = number(rawOffset, maximum: 1_000_000_000, integral: true) {
                    result["charOffset"] = offset
                } else if strict { return nil }
            }
            return result
        }
        var locations: [String: Any] = [:]
        for (key, value) in inputLocations {
            let cleaned: Any?
            switch key {
            case "progression", "totalProgression": cleaned = number(value, maximum: 1)
            case "position": cleaned = number(value, maximum: 1_000_000_000, integral: true, minimum: 1)
            case "cssSelector", "partialCfi": cleaned = text(value)
            case "cfi": cleaned = (value as? String).flatMap { validCFI($0) ? $0 : nil }
            case "enveSourceEngine": cleaned = (value as? String).flatMap { ["readium", "foliate"].contains($0) ? $0 : nil }
            case "fragments":
                if let values = value as? [Any], values.count <= 32 {
                    let kept = values.compactMap { text($0) }.filter { $0.unicodeScalars.count <= 512 }
                    cleaned = strict && kept.count != values.count ? nil : kept
                } else { cleaned = nil }
            case "domRange":
                if let range = value as? [String: Any], let start = point(range["start"]),
                    !strict || range["end"] == nil || point(range["end"]) != nil {
                    var result: [String: Any] = ["start": start]
                    result["end"] = point(range["end"])
                    cleaned = result
                } else { cleaned = nil }
            default: continue
            }
            if cleaned == nil && strict { throw .invalidField("l") }
            locations[key] = cleaned
        }
        var result: [String: Any] = ["href": href, "type": type ?? "application/xhtml+xml", "locations": locations]
        if let rawText = source["text"] {
            guard let inputText = rawText as? [String: Any] else {
                if strict { throw .invalidField("l") }
                return encoded(result)
            }
            var quote: [String: Any] = [:]
            for key in ["before", "highlight", "after"] where inputText[key] != nil {
                let value = text(inputText[key], allowControls: true)
                if value == nil && strict { throw .invalidField("l") }
                quote[key] = value
            }
            if !quote.isEmpty { result["text"] = quote }
        }
        return encoded(result)
    }

    static func representations(from raw: String?) -> (cfi: String?, locator: String?) {
        guard let raw else { return (nil, nil) }
        if validCFI(raw) { return (raw, nil) }
        guard let source = object(raw) else { return (nil, nil) }
        var locator = source
        if source["schemaVersion"] != nil {
            locator = object(source["readiumLocatorJSON"] as? String ?? source["nativeReadiumLocatorJson"] as? String) ?? [:]
            locator["href"] = source["href"] ?? locator["href"]
            locator["type"] = "application/xhtml+xml"
            var locations = locator["locations"] as? [String: Any] ?? [:]
            for (key, sourceKey) in [("progression", "resourceProgression"), ("totalProgression", "totalProgression"),
                ("cfi", "epubCFI"), ("partialCfi", "partialCFI"), ("cssSelector", "cssSelector"),
                ("domRange", "domRange"), ("enveSourceEngine", "sourceEngine")] {
                if let value = source[sourceKey], !(value is NSNull) { locations[key] = value }
            }
            if let cfi = source["epubCfi"] as? String { locations["cfi"] = cfi }
            locator["locations"] = locations
            if let quote = source["textQuote"] as? [String: Any] {
                var text: [String: Any] = [:]
                for (key, sourceKey) in [("highlight", "exact"), ("before", "prefix"), ("after", "suffix")] {
                    if let value = quote[sourceKey], !(value is NSNull) { text[key] = value }
                }
                locator["text"] = text
            }
        }
        let locations = locator["locations"] as? [String: Any] ?? [:]
        let cfi = ([locations["cfi"] as? String] + (locations["fragments"] as? [String] ?? []).map(Optional.some))
            .compactMap { $0 }.first(where: validCFI)
        return (cfi, try? sanitized(encoded(locator), strict: false))
    }
}
