import Foundation

/// Match preferred languages by exact tag, then primary subtag, with deterministic fallbacks.
nonisolated enum OPDSLanguagePreference {
    /// The reader's language tags, most preferred first.
    static var readerLanguages: [String] { Locale.preferredLanguages }

    static func select(from translations: [String: String]) -> String? {
        select(from: translations, preferring: readerLanguages)
    }

    static func select(from translations: [String: String], preferring languages: [String]) -> String? {
        guard let key = bestKey(among: Array(translations.keys), preferring: languages) else { return nil }
        return translations[key]
    }

    /// `nil` only when there is nothing to choose from.
    static func bestKey(among keys: [String], preferring languages: [String]) -> String? {
        guard !keys.isEmpty else { return nil }

        for language in languages {
            if let exact = keys.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
                return exact
            }
            let subtag = primarySubtag(of: language)
            if let related = keys
                .filter({ primarySubtag(of: $0) == subtag })
                .min(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count })
            {
                return related
            }
        }

        // `und` is Readium's own key for a string whose language the publisher did not state.
        for fallback in ["en", "und"] {
            if let match = keys.first(where: { primarySubtag(of: $0) == fallback }) { return match }
        }
        return keys.sorted().first
    }

    private static func primarySubtag(of tag: String) -> String {
        tag.lowercased().split(separator: "-").first.map(String.init) ?? tag.lowercased()
    }
}
