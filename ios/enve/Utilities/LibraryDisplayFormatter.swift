import Foundation

enum LibraryDisplayFormatter {
    private static let cache = NSCache<NSString, NSString>()

    static func clearCache() {
        cache.removeAllObjects()
    }

    static func displayTitle(_ title: String) -> String {
        let prefs = Theme.currentPreferences
        let mode = prefs.titleDisplayMode
        let subtitleHandling = prefs.subtitleHandling

        let cacheKey = "\(mode.rawValue)|\(subtitleHandling.rawValue)|\(title)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached as String
        }

        var normalized = TitleNormalizer.normalize(title, mode: mode)

        if subtitleHandling == .remove {
            normalized = normalized.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? normalized
        }

        cache.setObject(normalized as NSString, forKey: cacheKey)

        return normalized
    }
}
