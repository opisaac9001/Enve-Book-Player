import Combine
import Foundation
import Logging

@MainActor
protocol CurrentBookSession: AnyObject {
    var currentBook: Book? { get set }
}

@MainActor
protocol LibraryStartupGating: AnyObject {
    var isStartupCacheLoaded: Bool { get }
}

@MainActor
final class LibraryBookCache {
    let changes = PassthroughSubject<Void, Never>()
    let hot = BookHotCache()

    weak var session: (any CurrentBookSession)?

    private let writer: any BookWriting

    var suppressNotifications = false
    var skipsDeduplication = false
    var skipsIndexRebuild = false
    private(set) var mutationCount = 0
    private(set) var uniqueIdIndex: [String: Int] = [:]
    private(set) var stableIdIndex: [String: Int] = [:]

    init(writer: any BookWriting = BookStoreManager.shared.repository) {
        self.writer = writer
    }

    var books: [Book] = [] {
        didSet {
            mutationCount += 1
            #if DEBUG
            let delta = books.count - oldValue.count
            AppLogger.general.debug(
                "Library cache mutation=\(mutationCount) oldCount=\(oldValue.count) newCount=\(books.count) delta=\(delta) memoryMB=\(AppState.currentMemoryMB())"
            )
            #endif

            if !skipsDeduplication {
                var seen = Set<String>(minimumCapacity: books.count)
                if books.contains(where: { !seen.insert($0.uniqueId).inserted }) {
                    seen.removeAll(keepingCapacity: true)
                    let deduplicated = books.filter { seen.insert($0.uniqueId).inserted }
                    skipsDeduplication = true
                    books = deduplicated
                    skipsDeduplication = false
                    if !skipsIndexRebuild {
                        rebuildIndices()
                    }
                    if !suppressNotifications {
                        changes.send(())
                    }
                    return
                }
            }

            if !skipsIndexRebuild {
                rebuildIndices()
            }
            if !suppressNotifications {
                changes.send(())
            }
        }
    }

    func rebuildIndices() {
        var uniqueIds = [String: Int](minimumCapacity: books.count)
        var stableIds = [String: Int](minimumCapacity: books.count)
        for (index, book) in books.enumerated() {
            uniqueIds[book.uniqueId] = index
            stableIds[book.stableId] = index
        }
        uniqueIdIndex = uniqueIds
        stableIdIndex = stableIds
    }

    func currentStableIdIndex() -> [String: Int] {
        var index = [String: Int](minimumCapacity: books.count)
        for (offset, book) in books.enumerated() {
            index[book.stableId] = offset
        }
        return index
    }

    func indexInMemory(uniqueId: String) -> Int? { uniqueIdIndex[uniqueId] }

    func indexInMemory(stableId: String) -> Int? { stableIdIndex[stableId] }

    func book(uniqueId: String) -> Book? {
        guard let index = uniqueIdIndex[uniqueId], books.indices.contains(index) else { return nil }
        return books[index]
    }

    func bookInMemory(uniqueId: String) -> Book? {
        if let cached = hot.book(uniqueId: uniqueId) { return cached }
        guard let book = book(uniqueId: uniqueId) else { return nil }
        hot.insert(book)
        return book
    }

    func bookInMemory(stableId: String) -> Book? {
        if let cached = hot.book(stableId: stableId) { return cached }
        guard let index = stableIdIndex[stableId], books.indices.contains(index) else { return nil }
        let book = books[index]
        hot.insert(book)
        return book
    }

    func load(_ snapshot: [Book]) {
        let priorSkip = skipsDeduplication
        skipsDeduplication = true
        books = snapshot
        skipsDeduplication = priorSkip
        hot.insertMany(snapshot)
    }

    func ensureBookInMemory(_ book: Book) {
        guard stableIdIndex[book.stableId] == nil else { return }
        books.append(book)
    }

    @discardableResult
    func replaceExisting(_ book: Book) -> Bool {
        guard let index = uniqueIdIndex[book.uniqueId], books.indices.contains(index) else { return false }
        let previousSkip = skipsIndexRebuild
        skipsIndexRebuild = true
        books[index] = book
        skipsIndexRebuild = previousSkip
        hot.insert(book)
        return true
    }

    @discardableResult
    func mutateBook(uniqueId: String, _ transform: (inout Book) -> Void) -> Book? {
        let updated: Book
        if let index = uniqueIdIndex[uniqueId], books.indices.contains(index) {
            transform(&books[index])
            updated = books[index]
        } else if var cached = hot.book(uniqueId: uniqueId) {
            transform(&cached)
            updated = cached
        } else {
            return nil
        }
        commit([updated], matchingSession: { $0.uniqueId == updated.uniqueId })
        return updated
    }

    @discardableResult
    func mutateBook(stableId: String, _ transform: (inout Book) -> Void) -> Book? {
        let updated: Book
        if let index = stableIdIndex[stableId], books.indices.contains(index) {
            transform(&books[index])
            updated = books[index]
        } else if var cached = hot.book(stableId: stableId) {
            transform(&cached)
            updated = cached
        } else {
            return nil
        }
        commit([updated], matchingSession: { $0.stableId == updated.stableId })
        return updated
    }

    @discardableResult
    func mutateBooks(_ updates: [(uniqueId: String, transform: (inout Book) -> Void)]) -> [Book] {
        guard !updates.isEmpty else { return [] }
        var snapshots: [Book] = []
        snapshots.reserveCapacity(updates.count)
        performBatch {
            for (uniqueId, transform) in updates {
                guard let index = uniqueIdIndex[uniqueId] else { continue }
                transform(&books[index])
                snapshots.append(books[index])
            }
        }
        commit(snapshots, matchingSession: nil)
        return snapshots
    }

    @discardableResult
    func mutateBooksByStableId(_ updates: [(stableId: String, transform: (inout Book) -> Void)]) -> [Book] {
        guard !updates.isEmpty else { return [] }
        var snapshots: [Book] = []
        snapshots.reserveCapacity(updates.count)
        performBatch {
            for (stableId, transform) in updates {
                guard let index = stableIdIndex[stableId] else { continue }
                transform(&books[index])
                snapshots.append(books[index])
            }
        }
        commit(snapshots, matchingSession: nil)
        return snapshots
    }

    func performBatch(_ body: () -> Void) {
        let priorSkipDedup = skipsDeduplication
        let priorSkipRebuild = skipsIndexRebuild
        let priorSuppress = suppressNotifications
        skipsDeduplication = true
        skipsIndexRebuild = true
        suppressNotifications = true
        body()
        skipsDeduplication = priorSkipDedup
        skipsIndexRebuild = priorSkipRebuild
        suppressNotifications = priorSuppress
        if !skipsIndexRebuild {
            rebuildIndices()
        }
    }

    func performTransaction(_ body: () async -> Void) async {
        let priorSuppress = suppressNotifications
        let priorSkipRebuild = skipsIndexRebuild
        let priorSkipDedup = skipsDeduplication
        suppressNotifications = true
        skipsIndexRebuild = true
        skipsDeduplication = true
        await body()
        suppressNotifications = priorSuppress
        skipsIndexRebuild = priorSkipRebuild
        skipsDeduplication = priorSkipDedup
        if !skipsIndexRebuild {
            rebuildIndices()
        }
        if !suppressNotifications {
            changes.send(())
        }
    }

    func persist(_ books: [Book]) {
        guard !books.isEmpty else { return }
        Task(priority: .background) { [writer] in await writer.upsertBooks(books) }
    }

    private func commit(_ snapshots: [Book], matchingSession: ((Book) -> Bool)?) {
        guard !snapshots.isEmpty else { return }
        hot.insertMany(snapshots)
        if let matchingSession, let selected = session?.currentBook, matchingSession(selected) {
            session?.currentBook = snapshots[0]
        }
        persist(snapshots)
    }
}
