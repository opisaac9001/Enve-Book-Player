import Foundation

struct AudiobookGroupingOverride: Codable, Hashable, Sendable {
    let source: Book.BookSource
    let sourceId: String
    let filePath: String
}

@MainActor
final class AudiobookGroupingOverrideStore {
    static let shared = AudiobookGroupingOverrideStore()

    private static let storageKey = "audiobookGroupingOverrides"
    private let userDefaults = UserDefaults.standard

    private init() {}

    func forceStandalone(source: Book.BookSource, sourceId: String, filePath: String) {
        var overrides = loadOverrides()
        overrides.insert(
            AudiobookGroupingOverride(
                source: source,
                sourceId: sourceId,
                filePath: normalizedPath(filePath, source: source)
            )
        )
        save(overrides)
    }

    func forcedStandalonePaths(source: Book.BookSource, sourceId: String) -> Set<String> {
        Set(
            loadOverrides()
                .filter { $0.source == source && $0.sourceId == sourceId }
                .map(\.filePath)
        )
    }

    func removeForcedStandalone(source: Book.BookSource, sourceId: String, filePath: String) {
        var overrides = loadOverrides()
        overrides.remove(
            AudiobookGroupingOverride(
                source: source,
                sourceId: sourceId,
                filePath: normalizedPath(filePath, source: source)
            )
        )
        save(overrides)
    }

    private func loadOverrides() -> Set<AudiobookGroupingOverride> {
        guard let data = userDefaults.data(forKey: Self.storageKey),
            let overrides = try? JSONDecoder().decode(Set<AudiobookGroupingOverride>.self, from: data)
        else {
            return []
        }
        return overrides
    }

    private func save(_ overrides: Set<AudiobookGroupingOverride>) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func normalizedPath(_ path: String, source: Book.BookSource) -> String {
        source == .local ? URL(fileURLWithPath: path).standardizedFileURL.path : path
    }
}
