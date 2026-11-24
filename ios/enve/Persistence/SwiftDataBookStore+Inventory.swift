import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func bookCount() async -> Int {
        await read("count", fallback: 0) { try await $0.count() }
    }

    func bookCount(libraryId: String, providerId: UUID) async -> Int {
        await read("count(library)", fallback: 0) {
            try await $0.count(libraryId: libraryId, providerId: providerId.uuidString)
        }
    }

    func bookCount(providerId: UUID, mediaType: String?) async -> Int {
        await read("count(provider)", fallback: 0) {
            try await $0.count(providerId: providerId.uuidString, mediaType: mediaType)
        }
    }

    func hasData() async -> Bool {
        let worker = makeWorker()
        do {
            return try await worker.hasAny()
        } catch {
            return false
        }
    }

    func bookCount(mediaType: String) async -> Int {
        await read("bookCount(mediaType:)", fallback: 0) { try await $0.fetchBookCountByMediaType(mediaType) }
    }

    func bookCountWithReadAloudSource() async -> Int {
        await read("bookCountWithReadAloudSource", fallback: 0) {
            try await $0.fetchBookCountWithReadAloudSource()
        }
    }

    func hasBook(stableId: String, requiresWithoutReadAloudSource: Bool) async -> Bool {
        await read("hasBook", fallback: false) {
            try await $0.hasBook(stableId: stableId, requireWithoutReadAloudSource: requiresWithoutReadAloudSource)
        }
    }

    func bookPresence() async -> BookPresence {
        let worker = makeWorker()
        do { return try await worker.fetchBookPresence() } catch {
            AppLogger.general.error("BookStore.bookPresence failed: \(error)")
            return BookPresence(libraryKeys: [], smbBackendIds: [], hasReadAloud: false)
        }
    }

    func allBookUniqueIds() async -> Set<String> {
        let worker = makeWorker()
        do { return Set(try await worker.fetchAllBookUniqueIds()) } catch {
            AppLogger.general.error("BookStore.allBookUniqueIds failed: \(error)")
            return []
        }
    }

    func allBookIds() async -> Set<String> {
        let worker = makeWorker()
        do { return Set(try await worker.fetchAllBookIds()) } catch {
            AppLogger.general.error("BookStore.allBookIds failed: \(error)")
            return []
        }
    }

    func bookCountsBySource() async -> [(source: String, count: Int)] {
        let worker = await makeBackgroundWorker()
        do { return try await worker.fetchBookCountsBySource() } catch {
            AppLogger.general.error("BookStore.bookCountsBySource failed: \(error)")
            return []
        }
    }

    func bookCountsBySection(source: String) async -> [(libraryId: String, providerId: String, count: Int)] {
        let worker = await makeBackgroundWorker()
        do { return try await worker.fetchBookCountsBySection(source: source) } catch {
            AppLogger.general.error("BookStore.bookCountsBySection failed: \(error)")
            return []
        }
    }

    func titleAuthorPairs() async -> [(title: String, author: String)] {
        await read("titleAuthorPairs", fallback: []) { try await $0.fetchTitleAuthorPairs() }
    }
}

extension SwiftDataBookStore.Worker {
    func count() throws -> Int {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted }
        )
        return try modelContext.fetchCount(descriptor)
    }

    func count(libraryId: String, providerId: String) throws -> Int {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
            }
        )
        return try modelContext.fetchCount(descriptor)
    }

    func count(providerId: String, mediaType: String?) throws -> Int {
        let descriptor: FetchDescriptor<BookRecord>
        if let mt = mediaType {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.providerId == providerId && $0.mediaType == mt && !$0.isDeleted && !$0.isHidden
                }
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                }
            )
        }
        return try modelContext.fetchCount(descriptor)
    }

    func hasAny() throws -> Bool {
        var descriptor = FetchDescriptor<BookRecord>()
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func fetchBookCountByMediaType(_ mediaType: String) throws -> Int {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == mediaType && !$0.isDeleted && !$0.isHidden
            }
        )
        return try modelContext.fetchCount(descriptor)
    }

    func fetchBookCountWithReadAloudSource() throws -> Int {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.readAloudSourceStableId != nil && !$0.isDeleted && !$0.isHidden
            }
        )
        return try modelContext.fetchCount(descriptor)
    }

    func hasBook(stableId sid: String, requireWithoutReadAloudSource: Bool) throws -> Bool {
        var descriptor: FetchDescriptor<BookRecord>
        if requireWithoutReadAloudSource {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.stableId == sid && $0.readAloudSourceStableId == nil
                        && !$0.isDeleted && !$0.isHidden
                }
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.stableId == sid && !$0.isDeleted && !$0.isHidden
                }
            )
        }
        descriptor.fetchLimit = 1
        return try modelContext.fetchCount(descriptor) > 0
    }

    func fetchBookPresence() throws -> BookPresence {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
        )
        descriptor.propertiesToFetch = [
            \BookRecord.libraryId, \BookRecord.providerId,
            \BookRecord.source, \BookRecord.backendId,
            \BookRecord.readAloudSourceStableId,
        ]
        var libraryKeys = Set<String>()
        var smbBackendIds = Set<String>()
        var hasReadAloud = false
        for record in try modelContext.fetch(descriptor) {
            if record.readAloudSourceStableId != nil { hasReadAloud = true }
            if record.source == "smb" {
                if let id = record.backendId { smbBackendIds.insert(id) }
            } else {
                libraryKeys.insert("\(record.libraryId)|\(record.providerId)")
            }
        }
        return BookPresence(libraryKeys: libraryKeys, smbBackendIds: smbBackendIds, hasReadAloud: hasReadAloud)
    }

    func fetchAllBookUniqueIds() throws -> [String] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
        )
        descriptor.propertiesToFetch = [\BookRecord.uniqueId]
        return try modelContext.fetch(descriptor).map { $0.uniqueId }
    }

    func fetchAllBookIds() throws -> [String] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
        )
        descriptor.propertiesToFetch = [\BookRecord.bookId]
        return try modelContext.fetch(descriptor).map { $0.bookId }
    }

    private struct CountGroup: Hashable {
        let source: String
        let libraryId: String
        let providerId: String
    }

    private func fetchBookCounts(source: String? = nil) throws -> [CountGroup: Int] {
        var counts: [CountGroup: Int] = [:]
        var lowerBound = ""
        while true {
            try Task.checkCancellation()
            let cursor = lowerBound
            var descriptor: FetchDescriptor<BookRecord>
            if let source {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    !$0.isDeleted && $0.source == source && $0.uniqueId > cursor
                })
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    !$0.isDeleted && $0.uniqueId > cursor
                })
            }
            descriptor.sortBy = [SortDescriptor(\BookRecord.uniqueId, comparator: .lexical)]
            descriptor.fetchLimit = 1000
            descriptor.propertiesToFetch = [\BookRecord.uniqueId, \BookRecord.source, \BookRecord.libraryId, \BookRecord.providerId]
            let next = try autoreleasepool {
                let records = try modelContext.fetch(descriptor)
                for record in records {
                    let key = CountGroup(source: record.source, libraryId: record.libraryId, providerId: record.providerId)
                    counts[key, default: 0] += 1
                }
                return records.count == 1000 ? records.last?.uniqueId : nil
            }
            guard let next else { break }
            lowerBound = next
        }
        return counts
    }

    func fetchBookCountsBySource() throws -> [(source: String, count: Int)] {
        var sources: [String: Int] = [:]
        for (group, count) in try fetchBookCounts() {
            sources[group.source, default: 0] += count
        }
        return sources.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    func fetchBookCountsBySection(source: String) throws -> [(libraryId: String, providerId: String, count: Int)] {
        try fetchBookCounts(source: source).map { ($0.key.libraryId, $0.key.providerId, $0.value) }
            .sorted { $0.count > $1.count }
    }

    func fetchTitleAuthorPairs() throws -> [(title: String, author: String)] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
        )
        descriptor.propertiesToFetch = [\BookRecord.title, \BookRecord.author]
        return try modelContext.fetch(descriptor).map { ($0.title, $0.author ?? "") }
    }
}
