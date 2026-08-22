import Foundation

enum AudibleTagFilter {
    private static let ignoredTerms = [
        "audiobook",
        "unabridged",
        "abridged",
        "fiction",
        "nonfiction",
    ]

    static func filter(_ tags: [String], droppingFirst: Bool) -> [String] {
        let candidates = droppingFirst ? Array(tags.dropFirst()) : tags
        var seen = Set<String>()

        return candidates.filter { tag in
            let normalized = tag.lowercased()
            guard !ignoredTerms.contains(where: normalized.contains) else { return false }
            return seen.insert(normalized).inserted
        }
    }
}
