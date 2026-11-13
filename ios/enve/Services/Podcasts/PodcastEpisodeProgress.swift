import Foundation

// RSS episodes use the player's stable-ID progress store because feed reloads rebuild their library identity.
nonisolated enum PodcastEpisodeProgress {
    typealias Stored = (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)

    static func hydrate(_ episode: Book, stored: Stored?) -> Book {
        guard let stored else { return episode }
        var book = episode
        if (book.duration ?? 0) <= 0, stored.duration > 0 {
            book.duration = stored.duration
        }
        book.currentTime = max(0, stored.progress)
        book.lastUpdate = Date(timeIntervalSince1970: stored.lastUpdated)
        book.isFinished = isFinished(stored, duration: book.duration)
        return book
    }

    static func isFinished(_ stored: Stored, duration: TimeInterval?) -> Bool {
        let length = duration.flatMap { $0 > 0 ? $0 : nil } ?? stored.duration
        guard length > 0 else { return false }
        return stored.progress >= length * Book.finishedProgressThreshold
    }
}
