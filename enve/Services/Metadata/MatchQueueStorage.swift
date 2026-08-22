import Foundation
import Logging

final class MatchQueueStorage: @unchecked Sendable {
    static let shared = MatchQueueStorage()

    private let userDefaults = UserDefaults.standard
    private let matchQueueKey = "matchQueue"
    private let queue = DispatchQueue(label: "com.enve.matchQueueStorage")

    private init() {}

    func readMatchQueue() -> MatchQueue {
        queue.sync {
            guard let data = userDefaults.data(forKey: matchQueueKey) else {
                return MatchQueue(entries: [], version: "1.0", lastUpdated: ISO8601DateFormatter().string(from: Date()))
            }

            let decoder = JSONDecoder()
            return (try? decoder.decode(MatchQueue.self, from: data)) ?? MatchQueue()
        }
    }

    func writeMatchQueue(_ matchQueue: MatchQueue) {
        queue.sync {
            var updatedQueue = matchQueue
            updatedQueue.lastUpdated = ISO8601DateFormatter().string(from: Date())

            updatedQueue.entries = updatedQueue.entries.filter { $0.status == .pending }

            if updatedQueue.entries.count > 100 {
                updatedQueue.entries.sort { entry1, entry2 in
                    let date1 = ISO8601DateFormatter().date(from: entry1.createdAt) ?? Date.distantPast
                    let date2 = ISO8601DateFormatter().date(from: entry2.createdAt) ?? Date.distantPast
                    return date1 > date2
                }
                updatedQueue.entries = Array(updatedQueue.entries.prefix(100))
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(updatedQueue) {
                userDefaults.set(data, forKey: matchQueueKey)
            }
        }
    }

    func addMatchQueueEntry(_ entry: MatchQueueEntry) {
        var matchQueue = readMatchQueue()

        if let index = matchQueue.entries.firstIndex(where: { $0.id == entry.id }) {
            matchQueue.entries[index] = entry
        } else {
            matchQueue.entries.append(entry)
        }

        writeMatchQueue(matchQueue)
    }

    func removeMatchQueueEntry(entryId: String) {
        var matchQueue = readMatchQueue()
        matchQueue.entries.removeAll { $0.id == entryId }
        writeMatchQueue(matchQueue)
    }

    func updateMatchQueueEntry(_ entry: MatchQueueEntry) {
        addMatchQueueEntry(entry)
    }

    func getPendingMatches() -> [MatchQueueEntry] {
        let matchQueue = readMatchQueue()
        return matchQueue.entries.filter { $0.status == .pending }
    }

    func clearPendingMatches() {
        var matchQueue = readMatchQueue()
        matchQueue.entries.removeAll { $0.status == .pending }
        matchQueue.lastUpdated = ISO8601DateFormatter().string(from: Date())
        writeMatchQueue(matchQueue)
        AppLogger.network.info("Cleared all pending matches")
    }
}
