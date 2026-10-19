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
        store(book)
        if !isUpdate { evictIfNeeded() }
    }

    func insertMany(_ books: [Book]) {
        for book in books { store(book) }
        evictIfNeeded()
    }

    func remove(uniqueId: String) {
        guard let removed = entries.removeValue(forKey: uniqueId) else { return }
        if stableIdToUniqueId[removed.stableId] == uniqueId {
            stableIdToUniqueId.removeValue(forKey: removed.stableId)
        }
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

    private func touch(_ uniqueId: String) {
        accessCounter &+= 1
        lastAccess[uniqueId] = accessCounter
    }

    private func store(_ book: Book) {
        let uid = book.uniqueId
        if let previous = entries[uid], previous.stableId != book.stableId,
            stableIdToUniqueId[previous.stableId] == uid
        {
            stableIdToUniqueId.removeValue(forKey: previous.stableId)
        }
        entries[uid] = book
        stableIdToUniqueId[book.stableId] = uid
        touch(uid)
    }

    private func evictIfNeeded() {
        let excess = entries.count - capacity
        guard excess > 0 else { return }
        let candidates = entries.keys.filter { !pinned.contains($0) }
        if excess == 1 {
            if let oldest = candidates.min(by: { lastAccess[$0, default: 0] < lastAccess[$1, default: 0] }) {
                remove(uniqueId: oldest)
            }
        } else {
            let oldest = candidates.sorted { lastAccess[$0, default: 0] < lastAccess[$1, default: 0] }
            for uid in oldest.prefix(excess) { remove(uniqueId: uid) }
        }
    }
}
