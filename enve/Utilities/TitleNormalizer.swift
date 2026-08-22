import Foundation

nonisolated enum TitleNormalizer {

    private static let leadingPatterns: [String] = [
        #"^(\d{1,3}(?:\.\d+)?)\s*[-\x{2013}\x{2014}:.]\s*"#,

        #"^(\d{1,3})\s+(?=[\p{L}'"“‘\[\(])"#,

        #"^#\s*(\d{1,3}(?:\.\d+)?)\s*[-\x{2013}\x{2014}:.]\s*"#,

        #"^[Bb]ook\s+(\d{1,3}(?:\.\d+)?|[Oo]ne|[Tt]wo|[Tt]hree|[Ff]our|[Ff]ive|[Ss]ix|[Ss]even|[Ee]ight|[Nn]ine|[Tt]en)\s*[-\x{2013}\x{2014}:.]\s*"#,

        #"^[Pp]art\s+(\d{1,3}(?:\.\d+)?|[Oo]ne|[Tt]wo|[Tt]hree|[Ff]our|[Ff]ive|[Ss]ix|[Ss]even|[Ee]ight|[Nn]ine|[Tt]en)\s*[-\x{2013}\x{2014}:.]\s*"#,

        #"^[Vv]ol(?:ume|\.? )?\s*(\d{1,3}(?:\.\d+)?)\s*[-\x{2013}\x{2014}:.]\s*"#,

        #"^[Cc]h(?:apter|\.? )?\s*(\d{1,3}(?:\.\d+)?)\s*[-\x{2013}\x{2014}:.]\s*"#,
    ]

    private static let compiledLeadingRegexes: [NSRegularExpression] = {
        leadingPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    static func normalize(_ title: String, mode: UserPreferences.TitleDisplayMode) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .preserve:
            return trimmed
        case .stripPrefix:
            return stripLeadingPrefix(trimmed)
        case .moveToSuffix:
            return moveLeadingPrefixToEnd(trimmed)
        case .extractToSeries:
            return stripLeadingPrefix(trimmed)
        }
    }

    static func normalize(_ title: String) -> String {
        return stripLeadingPrefix(title)
    }

    private static func stripLeadingPrefix(_ title: String) -> String {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.controlCharacters)
        var result = title.trimmingCharacters(in: set)

        for _ in 0..<3 {
            var matched = false
            for regex in compiledLeadingRegexes {
                let range = NSRange(result.startIndex..., in: result)
                if let match = regex.firstMatch(in: result, options: [], range: range) {
                    guard let matchRange = Range(match.range, in: result) else { continue }
                    result = String(result[matchRange.upperBound...])
                    result = result.trimmingCharacters(in: set)
                    matched = true
                    break
                }
            }
            if !matched { break }
        }

        if result.isEmpty {
            return title.trimmingCharacters(in: set)
        }

        return result
    }

    private static func moveLeadingPrefixToEnd(_ title: String) -> String {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.controlCharacters)
        let trimmed = title.trimmingCharacters(in: set)

        for regex in compiledLeadingRegexes {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range) {
                guard let matchRange = Range(match.range, in: trimmed) else { continue }
                let prefix = String(trimmed[matchRange])
                let rest = String(trimmed[matchRange.upperBound...]).trimmingCharacters(in: set)

                if rest.isEmpty {
                    return trimmed
                }

                let cleanedPrefix =
                    prefix
                    .trimmingCharacters(in: set)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-\u{2013}\u{2014}:. #"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleanedPrefix.isEmpty {
                    return "\(rest) (\(cleanedPrefix))"
                }
                return rest
            }
        }

        return trimmed
    }
}

class NameNormalizer {

    nonisolated private static func normalizeForComparison(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let noPeriods = trimmed.replacingOccurrences(of: ".", with: "")

        let noSpaces = noPeriods.replacingOccurrences(of: " ", with: "")

        return noSpaces.lowercased()
    }

    static func canonicalName(for name: String, from allNames: [String]) -> String {
        let normalized = normalizeForComparison(name)

        let variants = allNames.filter {
            normalizeForComparison($0) == normalized
        }

        guard !variants.isEmpty else { return name }

        if variants.count == 1 {
            return variants[0]
        }

        var variantCounts: [String: Int] = [:]
        for variant in variants {
            variantCounts[variant] = allNames.filter { $0 == variant }.count
        }

        let mostCommon = variantCounts.max { a, b in
            if a.value == b.value {
                let aHasUpper = a.key.rangeOfCharacter(from: .uppercaseLetters) != nil
                let bHasUpper = b.key.rangeOfCharacter(from: .uppercaseLetters) != nil
                return !aHasUpper && bHasUpper
            }
            return a.value < b.value
        }

        return mostCommon?.key ?? name
    }

    struct CanonicalMap: Sendable {
        fileprivate let lookup: [String: String]
    }

    nonisolated static func buildCanonicalMap(from allNames: [String]) -> CanonicalMap {
        var groups: [String: [String: Int]] = [:]
        for name in allNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalizeForComparison(trimmed)
            if groups[key] == nil {
                groups[key] = [:]
            }
            groups[key, default: [:]][trimmed, default: 0] += 1
        }

        var lookup: [String: String] = [:]
        for (key, variants) in groups {
            let best = variants.max { a, b in
                if a.value == b.value {
                    let aHasUpper = a.key.rangeOfCharacter(from: .uppercaseLetters) != nil
                    let bHasUpper = b.key.rangeOfCharacter(from: .uppercaseLetters) != nil
                    return !aHasUpper && bHasUpper
                }
                return a.value < b.value
            }
            lookup[key] = best?.key ?? variants.keys.first ?? key
        }

        return CanonicalMap(lookup: lookup)
    }

    nonisolated static func canonicalName(for name: String, using map: CanonicalMap) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        let key = normalizeForComparison(trimmed)
        return map.lookup[key] ?? trimmed
    }

    nonisolated static func normalizeSeriesName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }

        let patterns: [String] = [
            #"[,;:]\s*(?:book|vol\.?|volume|part|tome|episode|ep\.?)\s*#?\d+(?:\.\d+)?\s*$"#,
            #"\s+[-\x{2013}\x{2014}]\s*(?:book|vol\.?|volume|part|tome|episode|ep\.?)\s*#?\d+(?:\.\d+)?\s*$"#,
            #"\s+(?:book|vol\.?|volume|part|tome|episode|ep\.?)\s*#?\d+(?:\.\d+)?\s*$"#,
            #"\s*#\d+(?:\.\d+)?\s*$"#,
            #"\s+[-\x{2013}\x{2014}]\s*\d+(?:\.\d+)?\s*$"#,
            #"(?<=\p{L})\s+\d+(?:\.\d+)?\s*$"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range) {
                guard let matchRange = Range(match.range, in: trimmed) else { continue }
                let candidate = String(trimmed[trimmed.startIndex..<matchRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= 2 {
                    return candidate
                }
            }
        }

        return trimmed
    }
}
