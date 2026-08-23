import Foundation

@MainActor
final class BookHotCache {
    private let capacity: Int
    private var entries: [String: Book] = [:]
    private var stableIdToUniqueId: [String: String] = [:]
    private var pinned: Set<String> = []
    private var accessCounter: UInt64 = 0
    private var lastAccess: [String: UInt64] = [:]

    init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func book(uniqueId: String) -> Book? {
        guard let b = entries[uniqueId] else { return nil }
        touch(uniqueId)
        return b
    }

    func book(stableId: String) -> Book? {
        guard let uid = stableIdToUniqueId[stableId] else { return nil }
        return book(uniqueId: uid)
    }

    func contains(uniqueId: String) -> Bool {
        entries[uniqueId] != nil
    }

    func insert(_ book: Book) {
        let uid = book.uniqueId
        let isUpdate = entries[uid] != nil
        entries[uid] = book
        stableIdToUniqueId[book.stableId] = uid
        touch(uid)
        if !isUpdate { evictIfNeeded() }
    }

    func insertMany(_ books: [Book]) {
        for b in books {
            entries[b.uniqueId] = b
            stableIdToUniqueId[b.stableId] = b.uniqueId
            accessCounter &+= 1
            lastAccess[b.uniqueId] = accessCounter
        }
        evictIfNeeded()
    }

    func remove(uniqueId: String) {
        guard let removed = entries.removeValue(forKey: uniqueId) else { return }
        stableIdToUniqueId.removeValue(forKey: removed.stableId)
        lastAccess.removeValue(forKey: uniqueId)
        pinned.remove(uniqueId)
    }

    func remove(stableId: String) {
        if let uid = stableIdToUniqueId[stableId] { remove(uniqueId: uid) }
    }

    func pin(uniqueId: String) {
        guard entries[uniqueId] != nil else { return }
        pinned.insert(uniqueId)
    }

    func unpin(uniqueId: String) {
        pinned.remove(uniqueId)
    }

    func setPinned(uniqueIds: Set<String>) {
        pinned = uniqueIds.intersection(Set(entries.keys))
    }

    private func touch(_ uniqueId: String) {
        accessCounter &+= 1
        lastAccess[uniqueId] = accessCounter
    }

    private func evictIfNeeded() {
        while entries.count > capacity {

            var oldestUid: String? = nil
            var oldestStamp: UInt64 = UInt64.max
            for (uid, _) in entries where !pinned.contains(uid) {
                let stamp = lastAccess[uid] ?? 0
                if stamp < oldestStamp {
                    oldestStamp = stamp
                    oldestUid = uid
                }
            }
            guard let evict = oldestUid else { return }
            remove(uniqueId: evict)
        }
    }
}
