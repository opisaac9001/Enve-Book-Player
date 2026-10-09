import CryptoKit
import Foundation

enum ABSCrossProviderHistory {
    static func session(
        from source: HistorySession,
        targetConnectionId: UUID,
        targetAccountId: String,
        targetBook: Book,
        currentProgress: TimeInterval
    ) -> ABSLocalListeningStore.Session? {
        guard source.source == .local,
            source.mediaType == "audiobook",
            source.durationSeconds >= 10,
            targetBook.providerId == targetConnectionId,
            targetBook.source == .audiobookshelf,
            !targetAccountId.isEmpty,
            currentProgress >= 0
        else { return nil }
        let wallClock = max(0, source.endTime.timeIntervalSince(source.startTime))
        let actual = min(TimeInterval(source.durationSeconds), wallClock)
        guard actual >= 10 else { return nil }
        let identity = "\(targetConnectionId.uuidString):\(targetAccountId):\(AudiobookshelfProvider.libraryItemId(for: targetBook)):\(source.id)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.dateFormat = "EEEE"
        return ABSLocalListeningStore.Session(
            id: id.uuidString.lowercased(),
            connectionId: targetConnectionId,
            libraryItemId: AudiobookshelfProvider.libraryItemId(for: targetBook),
            episodeId: nil,
            displayTitle: targetBook.title,
            displayAuthor: targetBook.author,
            day: formatter.string(from: source.endTime),
            dayOfWeek: weekday.string(from: source.endTime),
            duration: targetBook.duration ?? 0,
            timeListening: actual,
            currentTime: currentProgress,
            startedAt: Int64(source.startTime.timeIntervalSince1970 * 1_000),
            updatedAt: Int64(source.endTime.timeIntervalSince1970 * 1_000),
            needsUpload: true,
            accountId: targetAccountId
        )
    }
}
