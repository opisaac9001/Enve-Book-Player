import Foundation

enum EpubLocationBridge {
    static let sourceEngineLocationKey = "enveSourceEngine"

    struct GrimmoryLocation {
        let href: String?
        let progression: Double?
        let epubCFI: String?
        let sourceEngine: ReaderEngineKind?
    }

    static func extractGrimmoryLocation(from readiumLocator: String?) -> GrimmoryLocation {
        guard let locator = readiumLocator, !locator.isEmpty,
            let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return GrimmoryLocation(
                href: nil,
                progression: nil,
                epubCFI: nil,
                sourceEngine: nil
            )
        }

        let href = json["href"] as? String
        let locations = json["locations"] as? [String: Any]
        let progression =
            locations?["totalProgression"] as? Double
            ?? locations?["progression"] as? Double
        let sourceEngine = sourceEngine(from: readiumLocator)
        let trustedCFI =
            sourceEngine == .foliate
            ? canonicalFullEPUBCFI(epubCFI(from: readiumLocator))
            : nil

        return GrimmoryLocation(
            href: href,
            progression: progression,
            epubCFI: trustedCFI,
            sourceEngine: sourceEngine
        )
    }

    static func sourceEngine(from locator: String?) -> ReaderEngineKind? {
        guard let rawValue = locatorLocations(locator)?[sourceEngineLocationKey] as? String else {
            return nil
        }
        return ReaderEngineKind(rawValue: rawValue)
    }

    static func markingSourceEngine(
        _ sourceEngine: ReaderEngineKind,
        in locator: String?
    ) -> String? {
        guard var json = locatorJSON(locator),
            var locations = json["locations"] as? [String: Any]
        else {
            return nil
        }
        locations[sourceEngineLocationKey] = sourceEngine.rawValue
        json["locations"] = locations
        return jsonString(json)
    }

    static func removingSourceEngineMarker(from locator: String?) -> String? {
        guard var json = locatorJSON(locator),
            var locations = json["locations"] as? [String: Any]
        else {
            return nil
        }
        locations.removeValue(forKey: sourceEngineLocationKey)
        json["locations"] = locations
        return jsonString(json)
    }

    static func removingEPUBCFI(from locator: String?) -> String? {
        guard var json = locatorJSON(locator),
            var locations = json["locations"] as? [String: Any]
        else {
            return nil
        }
        locations.removeValue(forKey: "cfi")
        locations.removeValue(forKey: "partialCfi")
        if let fragments = locations["fragments"] as? [Any] {
            let nonCFIFragments = fragments.compactMap { value -> String? in
                guard let fragment = value as? String,
                    normalizedEPUBCFI(fragment) == nil
                else {
                    return nil
                }
                return fragment
            }
            if nonCFIFragments.isEmpty {
                locations.removeValue(forKey: "fragments")
            } else {
                locations["fragments"] = nonCFIFragments
            }
        }
        json["locations"] = locations
        return jsonString(json)
    }

    static func totalProgression(from readiumLocator: String?) -> Double? {
        guard let locations = locatorLocations(readiumLocator) else { return nil }

        guard let progression = locations["totalProgression"] as? Double else { return nil }
        return min(max(progression, 0), 1)
    }

    static func canRestoreDirectly(_ readiumLocator: String?) -> Bool {
        guard let json = locatorJSON(readiumLocator) else { return false }

        if let text = json["text"] as? [String: Any],
            let highlight = text["highlight"] as? String,
            highlight.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        {
            return true
        }

        guard let locations = json["locations"] as? [String: Any] else { return false }
        if let fragments = locations["fragments"] as? [Any],
            fragments.compactMap({ $0 as? String }).contains(where: isHTMLIDFragment)
        {
            return true
        }

        let href = (json["href"] as? String).map(normalizedHref) ?? ""
        if !href.isEmpty, fraction(locations["progression"]) != nil {
            return true
        }

        return false
    }

    static func canStoreAlongsidePercentageSync(_ readiumLocator: String?) -> Bool {
        guard let json = locatorJSON(readiumLocator) else { return false }

        if let text = json["text"] as? [String: Any],
            let highlight = text["highlight"] as? String,
            highlight.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        {
            return true
        }

        guard let locations = json["locations"] as? [String: Any] else { return false }
        if let cssSelector = locations["cssSelector"] as? String, !cssSelector.isEmpty {
            return true
        }
        if locations["domRange"] as? [String: Any] != nil {
            return true
        }
        if let fragments = locations["fragments"] as? [Any],
            fragments.compactMap({ $0 as? String }).contains(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        {
            return true
        }
        if epubCFI(from: readiumLocator) != nil {
            return true
        }

        return false
    }

    static func epubCFI(from locator: String?) -> String? {
        guard let locator else { return nil }
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = normalizedEPUBCFI(trimmed) {
            return normalized
        }

        guard let locations = locatorLocations(trimmed) else { return nil }
        if let cfi = normalizedEPUBCFI(locations["cfi"] as? String) {
            return cfi
        }
        if let fragments = locations["fragments"] as? [Any] {
            return
                fragments
                .compactMap { normalizedEPUBCFI($0 as? String) }
                .first
        }
        return nil
    }

    static func epubCFIForProviderUpload(from locator: String?) -> String? {
        guard let locator, !locator.isEmpty else { return nil }
        if locator.hasPrefix("epubcfi(") {
            return locator
        }

        guard let locations = locatorLocations(locator) else { return nil }
        if let fragments = locations["fragments"] as? [String],
            let cfi = fragments.first(where: { $0.hasPrefix("epubcfi(") })
        {
            return cfi
        }
        if let cfi = locations["cfi"] as? String, cfi.hasPrefix("epubcfi(") {
            return cfi
        }
        return nil
    }

    static func normalizedEPUBCFI(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        if value.hasPrefix("epubcfi("), value.hasSuffix(")") {
            return value
        }
        if value.hasPrefix("/") {
            return "epubcfi(\(value))"
        }
        return nil
    }

    static func canonicalFullEPUBCFI(_ value: String?) -> String? {
        guard let cfi = normalizedEPUBCFI(value) else { return nil }
        let inner = cfi.dropFirst("epubcfi(".count).dropLast()
        guard inner.hasPrefix("/6/"), inner.contains("!") else { return nil }
        return cfi
    }

    static func normalizedHref(_ href: String) -> String {
        let withoutFragment =
            href
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? href
        return withoutFragment.removingPercentEncoding ?? withoutFragment
    }

    static func readiumLocator(
        href: String?,
        epubCFI: String? = nil,
        fraction: Double,
        resourceProgression: Double? = nil,
        sourceEngine: ReaderEngineKind? = nil
    ) -> String? {
        let clamped = min(max(fraction, 0), 1)
        let resolvedHref = href ?? ""
        let cfi = normalizedEPUBCFI(epubCFI)
        if resolvedHref.isEmpty && clamped <= 0 && cfi == nil {
            return nil
        }
        var locations: [String: Any] = ["totalProgression": clamped]
        if let resourceProgression {
            locations["progression"] = min(max(resourceProgression, 0), 1)
        }
        if let cfi {
            locations["cfi"] = cfi
        }
        if let sourceEngine {
            locations[sourceEngineLocationKey] = sourceEngine.rawValue
        }
        let locator: [String: Any] = [
            "href": resolvedHref,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: locator),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    static func readiumLocator(
        from position: EpubBridgePosition,
        sourceEngine: ReaderEngineKind? = nil
    ) -> String? {
        var locations: [String: Any] = [
            "totalProgression": min(max(position.totalProgression, 0), 1)
        ]
        if let progression = position.resourceProgression {
            locations["progression"] = min(max(progression, 0), 1)
        }
        if let cfi = normalizedEPUBCFI(position.epubCFI) {
            locations["cfi"] = cfi
        }
        if let partialCFI = position.partialCFI {
            locations["partialCfi"] = partialCFI
        }
        if let cssSelector = position.cssSelector {
            locations["cssSelector"] = cssSelector
        }
        if let domRange = position.domRange,
            let data = try? JSONEncoder().encode(domRange),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            locations["domRange"] = object
        }
        if let sourceEngine {
            locations[sourceEngineLocationKey] = sourceEngine.rawValue
        }

        var locator: [String: Any] = [
            "href": position.href,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        if let quote = position.textQuote {
            var text: [String: Any] = ["highlight": quote.exact]
            if let prefix = quote.prefix { text["before"] = prefix }
            if let suffix = quote.suffix { text["after"] = suffix }
            locator["text"] = text
        }
        guard JSONSerialization.isValidJSONObject(locator),
            let data = try? JSONSerialization.data(withJSONObject: locator)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func compactReturnLocator(from readiumLocator: String?) -> String? {
        guard sourceEngine(from: readiumLocator) == .foliate,
            let original = readiumLocator,
            let json = locatorJSON(original),
            let href = json["href"] as? String,
            let locations = json["locations"] as? [String: Any],
            let cfi = canonicalFullEPUBCFI(epubCFI(from: original))
        else {
            return readiumLocator
        }

        var compactLocations: [String: Any] = [
            "cfi": cfi,
            sourceEngineLocationKey: ReaderEngineKind.foliate.rawValue,
        ]
        if let totalProgression = fraction(locations["totalProgression"]) {
            compactLocations["totalProgression"] = totalProgression
        }
        if let progression = fraction(locations["progression"]) {
            compactLocations["progression"] = progression
        }

        return jsonString([
            "href": href,
            "type": json["type"] as? String ?? "application/xhtml+xml",
            "locations": compactLocations,
        ]) ?? original
    }

    static func locatorForReadiumRestore(_ readiumLocator: String?) -> String? {
        guard var json = locatorJSON(readiumLocator),
            var locations = json["locations"] as? [String: Any]
        else {
            return nil
        }

        locations.removeValue(forKey: "cfi")
        locations.removeValue(forKey: "partialCfi")
        locations.removeValue(forKey: "domRange")
        locations.removeValue(forKey: sourceEngineLocationKey)
        if let fragments = locations["fragments"] as? [Any] {
            let safeFragments = fragments.compactMap { value -> String? in
                guard let fragment = value as? String, isHTMLIDFragment(fragment) else {
                    return nil
                }
                return fragment
            }
            if safeFragments.isEmpty {
                locations.removeValue(forKey: "fragments")
            } else {
                locations["fragments"] = safeFragments
            }
        }
        json["locations"] = locations

        guard canRestoreDirectly(jsonString(json)),
            JSONSerialization.isValidJSONObject(json),
            let data = try? JSONSerialization.data(withJSONObject: json)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func locatorJSON(_ readiumLocator: String?) -> [String: Any]? {
        guard let locator = readiumLocator, !locator.isEmpty,
            let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func locatorLocations(_ readiumLocator: String?) -> [String: Any]? {
        locatorJSON(readiumLocator)?["locations"] as? [String: Any]
    }

    private static func fraction(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private static func isHTMLIDFragment(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !fragment.isEmpty,
            normalizedEPUBCFI(fragment) == nil,
            !fragment.contains(where: \.isWhitespace),
            !fragment.contains("=")
        else {
            return false
        }
        return true
    }

    private static func jsonString(_ json: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(json),
            let data = try? JSONSerialization.data(withJSONObject: json)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
