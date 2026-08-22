import CryptoKit
import Foundation

struct CanonicalBookIdentity: Codable, Hashable, Sendable {
    let normalizedTitle: String

    let normalizedAuthor: String

    let durationSeconds: Int

    let seriesName: String?

    let seriesIndex: Double?

    let originalTitle: String

    let originalAuthor: String?

    var recordID: String {
        let components = [
            normalizedTitle,
            normalizedAuthor,
            String(durationSeconds),
            seriesIndex.map { String(Int($0)) } ?? "",
        ].joined(separator: "|")

        let data = Data(components.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    init(title: String, author: String?, duration: TimeInterval?, seriesName: String? = nil, seriesIndex: Double? = nil) {
        self.originalTitle = title
        self.originalAuthor = author
        self.normalizedTitle = Self.normalize(title: title)
        self.normalizedAuthor = Self.normalize(author: author)
        self.durationSeconds = Int(duration ?? 0)
        self.seriesName = seriesName.flatMap { Self.normalizeSeriesName($0) }
        self.seriesIndex = seriesIndex
    }

    init(from book: Book) {
        self.init(
            title: book.title,
            author: book.canonicalAuthorKey.isEmpty ? nil : book.canonicalAuthorKey,
            duration: book.duration,
            seriesName: book.series,
            seriesIndex: book.seriesNumber.map { Double($0) }
        )
    }

    private static func normalize(title: String) -> String {
        var result = title.lowercased()

        let suffixesToRemove = [
            "(unabridged)",
            "(abridged)",
            "- unabridged",
            "- abridged",
            "[unabridged]",
            "[abridged]",
            "audiobook",
            "audio book",
            "(audiobook)",
            "[audiobook]",
        ]

        for suffix in suffixesToRemove {
            result = result.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }

        result = result.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()

        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        result = result.trimmingCharacters(in: .whitespaces)

        return result
    }

    private static func normalize(author: String?) -> String {
        guard let author = author, !author.isEmpty else { return "" }

        var result = author.lowercased()

        let prefixesToRemove = ["by ", "written by ", "author: "]
        for prefix in prefixesToRemove {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
            }
        }

        if result.hasPrefix("[") && result.contains("]") {
            if let endIndex = result.firstIndex(of: "]") {
                result = String(result[result.index(after: endIndex)...])
            }
        }

        result = result.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()

        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizeSeriesName(_ series: String) -> String? {
        let normalized = normalize(title: series)
        return normalized.isEmpty ? nil : normalized
    }

    func matches(_ other: CanonicalBookIdentity, durationTolerance: Int = 5) -> MatchResult {
        guard normalizedTitle == other.normalizedTitle else {
            return .noMatch
        }

        let authorMatches =
            normalizedAuthor == other.normalizedAuthor || normalizedAuthor.isEmpty || other.normalizedAuthor.isEmpty
            || normalizedAuthor.contains(other.normalizedAuthor) || other.normalizedAuthor.contains(normalizedAuthor)

        guard authorMatches else {
            return .noMatch
        }

        let durationDiff = abs(durationSeconds - other.durationSeconds)
        let maxTolerance = max(durationTolerance, Int(Double(max(durationSeconds, other.durationSeconds)) * 0.005))

        if durationSeconds > 0 && other.durationSeconds > 0 {
            if durationDiff <= maxTolerance {
                if let myIndex = seriesIndex, let otherIndex = other.seriesIndex {
                    if myIndex == otherIndex {
                        return .exactMatch
                    } else {
                        return .noMatch
                    }
                }
                return .exactMatch
            } else {
                return .possibleMatch(confidence: 0.5)
            }
        }

        return .possibleMatch(confidence: 0.7)
    }

    enum MatchResult: Equatable {
        case exactMatch
        case possibleMatch(confidence: Double)
        case noMatch

        var isMatch: Bool {
            switch self {
            case .exactMatch, .possibleMatch: return true
            case .noMatch: return false
            }
        }

        var confidence: Double {
            switch self {
            case .exactMatch: return 1.0
            case .possibleMatch(let c): return c
            case .noMatch: return 0.0
            }
        }
    }
}

extension CanonicalBookIdentity: CustomStringConvertible {
    var description: String {
        "CanonicalBookIdentity(title: \"\(originalTitle)\", author: \"\(originalAuthor ?? "unknown")\", duration: \(durationSeconds)s, recordID: \(recordID.prefix(12))...)"
    }
}
