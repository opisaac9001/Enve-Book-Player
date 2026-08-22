import Foundation

struct TextNormalizer {

    nonisolated static func normalizeTitle(_ title: String) -> String {
        var normalized = title.lowercased().trimmingCharacters(in: .whitespaces)

        normalized = removeSubtitle(normalized)

        normalized = removeLeadingArticles(normalized)

        let prefixes = ["audible audio edition", "unabridged", "abridged", "audiobook"]
        for prefix in prefixes {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        normalized = normalized.replacingOccurrences(of: "\u{2019}", with: "'")
        normalized = normalized.replacingOccurrences(of: "\u{201C}", with: "\"")
        normalized = normalized.replacingOccurrences(of: "\u{201D}", with: "\"")

        normalized = normalized.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()

        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func removeSubtitle(_ title: String) -> String {
        let genericSubtitles = [
            #":\s*(?:a\s+)?(?:novel|story|tale|memoir|biography|autobiography)\s*$"#,
            #":\s*(?:the\s+)?(?:complete|full|unabridged|abridged)\s+(?:edition|version)\s*$"#,
            #"\s*\((?:unabridged|abridged)\)\s*$"#,
            #",\s*(?:a|an|the)\s+(?:novel|story|tale)\s*$"#,
        ]

        var result = title
        for pattern in genericSubtitles {
            if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                result = String(result[..<range.lowerBound])
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func removeLeadingArticles(_ title: String) -> String {
        let articles = ["the ", "a ", "an "]
        for article in articles {
            if title.hasPrefix(article) {
                return String(title.dropFirst(article.count))
            }
        }
        return title
    }

    nonisolated static func normalizeAuthor(_ author: String) -> String {
        var normalized = author.lowercased().trimmingCharacters(in: .whitespaces)

        if normalized.isEmpty || normalized == "unknown" || normalized == "unknown author"
            || (normalized.hasPrefix("[") && normalized.hasSuffix("]"))
        {
            return "unknown author"
        }

        let prefixes = ["by ", "written by ", "author: "]
        for prefix in prefixes {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        if normalized.contains(",") && !normalized.contains(" and ") && !normalized.contains(" & ") {
            let parts = normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                normalized = "\(parts[1]) \(parts[0])"
            }
        }

        normalized = normalized.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()

        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func normalizeNarratorList(_ narrators: String) -> [String] {
        let separators = [", ", " and ", " & ", "; ", " / "]
        var parts = [narrators]

        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }

        return
            parts
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    nonisolated static func normalizeSeries(_ series: String) -> String {
        var normalized = series.lowercased().trimmingCharacters(in: .whitespaces)

        let suffixes = [" series", " trilogy", " saga", " chronicles", " books"]
        for suffix in suffixes {
            if normalized.hasSuffix(suffix) {
                normalized = String(normalized.dropLast(suffix.count))
            }
        }

        if normalized.hasPrefix("the ") {
            normalized = String(normalized.dropFirst(4))
        }

        normalized = normalized.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()

        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func extractSeriesNumber(from text: String) -> Int? {
        let patterns = [
            #"vol\.?\s*(\d+)"#,
            #"volume\s+(\d+)"#,
            #"book\s+(\d+)"#,
            #"#(\d+)"#,
            #"\b(\d{1,3})\s*[-\x{2013}\x{2014}:.]\s*"#,
        ]

        let lower = text.lowercased()
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: lower),
                let number = Int(lower[range])
            {
                return number
            }
        }

        return nil
    }
}
