import Foundation

/// The item audio time Enve last pushed to, or took from, a server that keeps one progress record
/// (and one `lastUpdate`) for an item's audio and its ebook. The server audio side is newer only when
/// its time differs from this one.
final class NarratedAudioPositionStore {
    static let shared = NarratedAudioPositionStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private var syncedTimes: [String: TimeInterval]
    private var observedServerTimes: [String: TimeInterval] = [:]
    private var narrationTimes: [String: TimeInterval] = [:]

    init(defaults: UserDefaults = .standard, storageKey: String = "narratedAudioSyncedTimes") {
        self.defaults = defaults
        self.storageKey = storageKey
        syncedTimes = defaults.dictionary(forKey: storageKey) as? [String: TimeInterval] ?? [:]
    }

    static func itemKey(connectionId: UUID, itemId: String) -> String {
        "\(connectionId.uuidString)|\(itemId)"
    }

    func isServerAudioNewer(_ serverTime: TimeInterval, forItem key: String) -> Bool {
        guard let synced = syncedTimes[key] else { return true }
        return abs(serverTime - synced) > 0.5
    }

    func noteServerAudioTime(_ time: TimeInterval, forItem key: String) {
        observedServerTimes[key] = time
    }

    /// A push without an audio time leaves the server's audio as it was, which Enve has now seen and moved past.
    func recordPush(audioTime: TimeInterval?, forItem key: String) {
        guard let time = audioTime ?? observedServerTimes[key] else { return }
        observedServerTimes[key] = time
        guard syncedTimes[key] != time else { return }
        syncedTimes[key] = time
        defaults.set(syncedTimes, forKey: storageKey)
    }

    /// Only narration yields an audio time for an ebook push; plain reading records none.
    func recordNarration(audioTime: TimeInterval, for book: Book) {
        narrationTimes[book.stableId] = audioTime
        if let sourceStableId = book.readAloudSourceStableId {
            narrationTimes[sourceStableId] = audioTime
        }
    }

    func narrationAudioTime(for book: Book) -> TimeInterval? {
        narrationTimes[book.stableId]
    }
}
