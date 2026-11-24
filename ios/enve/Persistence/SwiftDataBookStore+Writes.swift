import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func upsertBooks(_ books: [Book]) async {
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            AppLogger.general.error("BookStore.upsertBooks: rejected \(books.count - valid.count) book(s) with empty identity")
        }
        guard !valid.isEmpty else { return }
        let batchSize = 500
        var anyWritten = false
        for batchStart in stride(from: 0, to: valid.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, valid.count)
            let batch = Array(valid[batchStart..<batchEnd])
            let worker = makeWorker()
            do {
                try await worker.upsert(batch)
                anyWritten = true
            } catch {
                AppLogger.general.error("BookStore.upsert batch failed: \(error)")
            }
        }
        if anyWritten { BookStoreChangeNotifier.notify() }
    }

    @discardableResult
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int {
        let worker = makeWorker()
        do {
            let removed = try await worker.deleteBooksFromUnknownProviders(validProviderIds: validProviderIds)
            if removed > 0 { BookStoreChangeNotifier.notify() }
            return removed
        } catch {
            AppLogger.general.error("BookStore.deleteBooksFromUnknownProviders failed: \(error)")
            return 0
        }
    }

    @discardableResult
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int {
        let worker = makeWorker()
        do {
            let removed = try await worker.deleteBooksFromInactiveLibraries(
                validProviderIds: validProviderIds,
                restrictedLibraryIds: restrictedLibraryIds
            )
            if removed > 0 { BookStoreChangeNotifier.notify() }
            return removed
        } catch {
            AppLogger.general.error("BookStore.deleteBooksFromInactiveLibraries failed: \(error)")
            return 0
        }
    }

    func setHidden(_ hidden: Bool, stableId: String) async {
        guard !stableId.isEmpty else {
            AppLogger.general.error("BookStore.setHidden: rejecting empty stableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.setHidden(hidden, stableId: stableId)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.setHidden failed: \(error)")
        }
    }

    func setDeleted(_ deleted: Bool, stableId: String) async {
        guard !stableId.isEmpty else {
            AppLogger.general.error("BookStore.setDeleted: rejecting empty stableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.setDeleted(deleted, stableId: stableId)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.setDeleted failed: \(error)")
        }
    }

    func deleteBooks(uniqueIds: Set<String>) async {
        let valid = uniqueIds.filter { !$0.isEmpty }
        if valid.count != uniqueIds.count {
            AppLogger.general.error("BookStore.deleteBooks: filtered \(uniqueIds.count - valid.count) empty uniqueId(s)")
        }
        guard !valid.isEmpty else { return }
        let worker = makeWorker()
        do {
            try await worker.deleteBooks(uniqueIds: valid)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.deleteBooks failed: \(error)")
        }
    }

    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {
        let worker = makeWorker()
        do {
            try await worker.importLegacy(books, hiddenStableIds: hiddenStableIds, deletedStableIds: deletedStableIds)
            AppLogger.general.info("BookStore: imported \(books.count) legacy books")
        } catch {
            AppLogger.general.error("BookStore.importLegacy failed: \(error)")
        }
    }

    func clearAllData() async {
        let worker = makeWorker()
        do {
            try await worker.clearAllData()
        } catch {
            AppLogger.general.error("BookStore.clearAllData failed: \(error)")
        }
    }
}

extension SwiftDataBookStore.Worker {
    func upsert(_ books: [Book]) throws {
        let books = deduplicatedBooks(books)
        guard !books.isEmpty else { return }

        let incomingIds = Set(books.map(\.uniqueId))
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { incomingIds.contains($0.uniqueId) }
        )
        let existingRecords = try modelContext.fetch(descriptor)
        var existingByUniqueId = Dictionary(
            existingRecords.map { ($0.uniqueId, $0) },
            uniquingKeysWith: { _, new in new }
        )
        for book in books {
            if let existing = existingByUniqueId[book.uniqueId] {
                existing.update(from: book)
            } else {
                let record = BookRecord(from: book)
                modelContext.insert(record)
                existingByUniqueId[book.uniqueId] = record
            }
            try mirrorEbookProgressIfNeeded(
                bookUniqueId: book.uniqueId,
                stableId: book.stableId,
                currentTime: book.currentTime,
                duration: book.duration ?? 0,
                ebookProgress: book.ebookProgress,
                epubLocator: book.epubLocator,
                isFinished: book.isFinished,
                lastUpdate: book.lastUpdate,
                hideFromContinue: book.hideFromContinue
            )
        }
        try modelContext.save()
    }

    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) throws -> Int {
        let predicate = #Predicate<BookRecord> { record in
            record.source != "local" && record.source != "smb"
                && !validProviderIds.contains(record.providerId)
        }
        let count = try modelContext.fetchCount(FetchDescriptor<BookRecord>(predicate: predicate))
        guard count > 0 else { return 0 }
        try modelContext.delete(model: BookRecord.self, where: predicate)
        try modelContext.save()
        return count
    }

    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) throws -> Int {
        var totalDeleted = 0

        let unknownPredicate = #Predicate<BookRecord> { record in
            record.source != "local" && record.source != "smb"
                && !validProviderIds.contains(record.providerId)
        }
        let unknownCount = try modelContext.fetchCount(FetchDescriptor<BookRecord>(predicate: unknownPredicate))
        if unknownCount > 0 {
            try modelContext.delete(model: BookRecord.self, where: unknownPredicate)
            totalDeleted += unknownCount
        }

        for (providerId, allowedLibraryIds) in restrictedLibraryIds {
            let pid = providerId
            let allowed = allowedLibraryIds
            let restrictedPredicate = #Predicate<BookRecord> { record in
                record.providerId == pid
                    && record.source != "local" && record.source != "smb"
                    && !allowed.contains(record.libraryId)
            }
            let count = try modelContext.fetchCount(FetchDescriptor<BookRecord>(predicate: restrictedPredicate))
            if count > 0 {
                try modelContext.delete(model: BookRecord.self, where: restrictedPredicate)
                totalDeleted += count
            }
        }

        if totalDeleted > 0 {
            try modelContext.save()
        }
        return totalDeleted
    }

    func setHidden(_ hidden: Bool, stableId sid: String) throws {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.stableId == sid }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.isHidden = hidden
        try modelContext.save()
    }

    func setDeleted(_ deleted: Bool, stableId sid: String) throws {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.stableId == sid }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.isDeleted = deleted
        try modelContext.save()
    }

    func deleteBooks(uniqueIds: Set<String>) throws {
        guard !uniqueIds.isEmpty else { return }
        try modelContext.delete(model: BookRecord.self, where: #Predicate { uniqueIds.contains($0.uniqueId) })
    }

    func importLegacy(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) throws {
        let batchSize = 500
        for batchStart in stride(from: 0, to: books.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, books.count)
            let batch = books[batchStart..<batchEnd]
            for book in batch {
                let uid = book.uniqueId
                var descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate { $0.uniqueId == uid }
                )
                descriptor.fetchLimit = 1

                if let existing = try modelContext.fetch(descriptor).first {
                    existing.update(from: book)
                    existing.isHidden = hiddenStableIds.contains(book.stableId)
                    existing.isDeleted = deletedStableIds.contains(book.stableId)
                } else {
                    let record = BookRecord(from: book)
                    record.isHidden = hiddenStableIds.contains(book.stableId)
                    record.isDeleted = deletedStableIds.contains(book.stableId)
                    modelContext.insert(record)
                }
            }
            try modelContext.save()
        }
    }

    func clearAllData() throws {
        try modelContext.delete(model: BookRecord.self)
        try modelContext.delete(model: MediaProgressRecord.self)
        try modelContext.delete(model: LinkedBookPairRecord.self)
        try modelContext.delete(model: BookmarkRecord.self)
        try modelContext.delete(model: AnnotationRecord.self)
        try modelContext.delete(model: ChapterCacheRecord.self)
    }
}
