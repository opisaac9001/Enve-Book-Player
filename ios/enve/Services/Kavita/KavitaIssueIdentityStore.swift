import Foundation

final class KavitaIssueIdentityStore {
    private let defaults: UserDefaults
    private let key = "kavitaLegacyChapterIds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func legacyChapterId(connectionId: UUID, seriesId: Int, firstChapterId: Int) -> Int {
        legacyChapterIds(connectionId: connectionId, firstChapters: [(seriesId, firstChapterId)])[seriesId]!
    }

    func legacyChapterIds(connectionId: UUID, firstChapters: [(seriesId: Int, chapterId: Int)]) -> [Int: Int] {
        guard !firstChapters.isEmpty else { return [:] }
        var chapters = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        var resolved: [Int: Int] = [:]
        var changed = false
        for (seriesId, firstChapterId) in firstChapters {
            let identity = "\(connectionId.uuidString):\(seriesId)"
            if chapters[identity] == nil {
                chapters[identity] = firstChapterId
                changed = true
            }
            resolved[seriesId] = chapters[identity]
        }
        if changed { defaults.set(chapters, forKey: key) }
        return resolved
    }
}
