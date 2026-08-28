import Foundation
import Logging

struct RecentlyPlayedSnapshot: Codable {
    let stableId: String
    let book: Book
    let lastUpdated: Double
}

@MainActor
final class BookProgressStore {
    static let shared = BookProgressStore()

    private let userDefaults: UserDefaults
    private var lastNotificationAt: TimeInterval = 0
    private let notificationMinInterval: TimeInterval = 1.0

    init(defaults: UserDefaults = .standard) {
        userDefaults = defaults
    }

    func storageKey(for book: Book) -> String {
        "bookProgress_\(book.stableId)"
    }

    func saveProgress(for book: Book, progress: TimeInterval, duration: TimeInterval, at date: Date = Date()) {
        let stableKey = storageKey(for: book)
        if let existing = userDefaults.dictionary(forKey: stableKey),
            let oldProgress = existing["progress"] as? TimeInterval,
            let oldDuration = existing["duration"] as? TimeInterval,
            abs(oldProgress - progress) < 1.0,
            abs(oldDuration - duration) < 1.0
        {
            return
        }

        let progressData: [String: Any] = [
            "progress": progress,
            "duration": duration,
            "lastUpdated": date.timeIntervalSince1970,
        ]

        userDefaults.set(progressData, forKey: stableKey)

        let now = Date().timeIntervalSince1970
        userDefaults.set(now, forKey: "bookProgressLastUpdated")

        emitDidChange(now: now, object: book.stableId)
    }

    func saveProgress(_ updates: [(book: Book, progress: UserMediaProgress)]) {
        guard !updates.isEmpty else { return }
        var didChange = false

        for update in updates {
            let progressData: [String: Any] = [
                "progress": update.progress.currentTime,
                "duration": update.progress.duration,
                "lastUpdated": update.progress.lastUpdate.timeIntervalSince1970,
            ]
            let stableKey = storageKey(for: update.book)
            if let existing = userDefaults.dictionary(forKey: stableKey),
                let oldProgress = existing["progress"] as? TimeInterval,
                let oldDuration = existing["duration"] as? TimeInterval,
                let oldTimestamp = existing["lastUpdated"] as? TimeInterval,
                abs(oldProgress - update.progress.currentTime) < 1.0,
                abs(oldDuration - update.progress.duration) < 1.0,
                oldTimestamp == update.progress.lastUpdate.timeIntervalSince1970
            {
                continue
            }

            userDefaults.set(progressData, forKey: stableKey)
            didChange = true
        }

        if didChange {
            let now = Date().timeIntervalSince1970
            userDefaults.set(now, forKey: "bookProgressLastUpdated")
            emitDidChange(now: now, object: updates[0].book.stableId)
        }
    }

    func loadProgress(for book: Book) -> (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)? {
        readProgress(forKey: storageKey(for: book))
    }

    func saveProgress(bookId: String, progress: TimeInterval, duration: TimeInterval) {
        let key = "bookProgress_\(bookId)"
        if let existing = userDefaults.dictionary(forKey: key),
            let oldProgress = existing["progress"] as? TimeInterval,
            let oldDuration = existing["duration"] as? TimeInterval,
            abs(oldProgress - progress) < 1.0,
            abs(oldDuration - duration) < 1.0
        {
            return
        }

        let progressData: [String: Any] = [
            "progress": progress,
            "duration": duration,
            "lastUpdated": Date().timeIntervalSince1970,
        ]
        userDefaults.set(progressData, forKey: key)

        let now = Date().timeIntervalSince1970
        userDefaults.set(now, forKey: "bookProgressLastUpdated")
        emitDidChange(now: now, object: bookId)
    }

    func loadProgress(bookId: String) -> (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)? {
        readProgress(forKey: "bookProgress_\(bookId)")
    }

    func clearProgress(for bookId: String) {
        userDefaults.removeObject(forKey: "bookProgress_\(bookId)")
        AppLogger.network.debug(
            "Cleared progress bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
        )
    }

    func saveServerStamp(for book: Book, _ date: Date) {
        let ts = date.timeIntervalSince1970
        userDefaults.set(ts, forKey: "serverStamp_\(book.stableId)")
    }

    func loadServerStamp(for book: Book) -> Date? {
        if let ts = userDefaults.object(forKey: "serverStamp_\(book.stableId)") as? TimeInterval {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }

    private static let recentlyPlayedKey = "recentlyPlayedBooks"
    private let recentlyPlayedLimit = 50

    func saveRecentlyPlayed(_ book: Book) {
        saveRecentlyPlayed(book, date: Date())
    }

    func saveRecentlyPlayed(_ book: Book, date: Date) {
        let stableId = book.stableId
        let newSnapshot = RecentlyPlayedSnapshot(stableId: stableId, book: book, lastUpdated: date.timeIntervalSince1970)
        let key = Self.recentlyPlayedKey
        let limit = recentlyPlayedLimit

        Task.detached(priority: .utility) {
            guard let data = UserDefaults.standard.data(forKey: key),
                var existing = try? JSONDecoder().decode([RecentlyPlayedSnapshot].self, from: data)
            else {
                if let encoded = try? JSONEncoder().encode([newSnapshot]) {
                    UserDefaults.standard.set(encoded, forKey: key)
                }
                return
            }
            existing.removeAll { $0.stableId == stableId }
            existing.insert(newSnapshot, at: 0)
            if existing.count > limit {
                existing = Array(existing.prefix(limit))
            }
            if let encoded = try? JSONEncoder().encode(existing) {
                UserDefaults.standard.set(encoded, forKey: key)
            }
        }
    }

    func loadRecentlyPlayed() -> [Book] {
        loadSnapshots().map { $0.book }
    }

    func loadSnapshots() -> [RecentlyPlayedSnapshot] {
        guard let data = userDefaults.data(forKey: Self.recentlyPlayedKey),
            let decoded = try? JSONDecoder().decode([RecentlyPlayedSnapshot].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func remove(stableId: String) {
        var existing = loadSnapshots()
        let before = existing.count
        existing.removeAll { $0.stableId == stableId }
        if existing.count != before {
            persistSnapshots(existing)
        }
    }

    func migrateProgress(from oldBook: Book, to newBook: Book) {
        if let oldProgress = loadProgress(for: oldBook) {
            if let newProgress = loadProgress(for: newBook) {
                if oldProgress.lastUpdated > newProgress.lastUpdated {
                    saveProgress(for: newBook, progress: oldProgress.progress, duration: oldProgress.duration)
                }
            } else {
                saveProgress(for: newBook, progress: oldProgress.progress, duration: oldProgress.duration)
            }
        }

        if let oldStamp = loadServerStamp(for: oldBook),
            loadServerStamp(for: newBook) == nil || oldStamp > (loadServerStamp(for: newBook) ?? .distantPast)
        {
            saveServerStamp(for: newBook, oldStamp)
        }

        var snapshots = loadSnapshots()
        var didChange = false
        for index in snapshots.indices
        where snapshots[index].stableId == oldBook.stableId || snapshots[index].book.uniqueId == oldBook.uniqueId {
            snapshots[index] = RecentlyPlayedSnapshot(
                stableId: newBook.stableId,
                book: newBook,
                lastUpdated: snapshots[index].lastUpdated
            )
            didChange = true
        }
        if didChange {
            var seen = Set<String>()
            snapshots.removeAll { snapshot in
                if seen.contains(snapshot.stableId) { return true }
                seen.insert(snapshot.stableId)
                return false
            }
            persistSnapshots(snapshots)
        }
    }

    func removeOrphaned(bookIds: [String]) {
        var existing = loadSnapshots()
        let before = existing.count
        existing.removeAll { snapshot in
            bookIds.contains(snapshot.book.id)
        }
        let removed = before - existing.count
        if removed > 0 {
            persistSnapshots(existing)
            AppLogger.network.info("Removed \(removed) orphaned books from recently played")
        }
    }

    private func readProgress(forKey key: String) -> (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)? {
        guard let dict = userDefaults.dictionary(forKey: key),
            let progress = dict["progress"] as? TimeInterval,
            let duration = dict["duration"] as? TimeInterval,
            let lastUpdated = dict["lastUpdated"] as? TimeInterval
        else {
            return nil
        }
        return (progress, duration, lastUpdated)
    }

    private func persistSnapshots(_ snapshots: [RecentlyPlayedSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        userDefaults.set(data, forKey: Self.recentlyPlayedKey)
    }

    private func emitDidChange(now: TimeInterval, object: String) {
        guard now - lastNotificationAt >= notificationMinInterval else { return }
        lastNotificationAt = now
        NotificationCenter.default.post(name: .bookProgressDidChange, object: object)
    }
}
