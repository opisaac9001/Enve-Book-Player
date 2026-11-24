import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool = false) async {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.replaceLibrary: rejecting empty libraryId")
            return
        }
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            AppLogger.general.error("BookStore.replaceLibrary: rejected \(books.count - valid.count) book(s) with empty identity")
        }
        let worker = makeWorker()
        do {
            try await worker.replaceLibrary(
                books: valid,
                libraryId: libraryId,
                providerId: providerId.uuidString,
                allowSparseResult: allowSparseResult
            )
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.replaceLibrary failed: \(error)")
        }
    }

    func beginReconciliation(libraryId: String, providerId: UUID) async throws -> ReconciliationStart {
        let worker = makeWorker()
        return try await worker.beginReconciliation(libraryId: libraryId, providerId: providerId.uuidString)
    }

    func upsertReconciledPage(books: [Book], generation: Int, notifyChange: Bool) async throws {
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            throw BookStoreWriteError.invalidBookIdentity
        }
        guard !valid.isEmpty else { return }
        let worker = makeWorker()
        try await worker.upsertReconciledPage(books: valid, generation: generation)
        if notifyChange {
            BookStoreChangeNotifier.notify()
        }
    }

    func endReconciliation(
        libraryId: String,
        providerId: UUID,
        generation: Int,
        existingCountBefore: Int
    ) async throws -> ReconciliationOutcome {
        let worker = makeWorker()
        let outcome = try await worker.endReconciliation(
            libraryId: libraryId,
            providerId: providerId.uuidString,
            generation: generation,
            existingCountBefore: existingCountBefore
        )
        BookStoreChangeNotifier.notify()
        return outcome
    }

    func applyDelta(books: [Book], libraryId: String, providerId: UUID, cursor: Date) async {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.applyDelta: rejecting empty libraryId")
            return
        }
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            AppLogger.general.error("BookStore.applyDelta: rejected \(books.count - valid.count) book(s) with empty identity")
        }
        let worker = makeWorker()
        do {
            if !valid.isEmpty {
                try await worker.applyDelta(books: valid, libraryId: libraryId, providerId: providerId.uuidString)
            }
            try await worker.saveCursor(
                providerId: providerId.uuidString,
                libraryId: libraryId,
                lastSyncedAt: cursor,
                lastFullReconciledAt: nil
            )
            if !valid.isEmpty { BookStoreChangeNotifier.notify() }
        } catch {
            AppLogger.general.error("BookStore.applyDelta failed: \(error)")
        }
    }

    func loadCursor(providerId: UUID, libraryId: String) async -> LibrarySyncCursorSnapshot? {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.loadCursor: rejecting empty libraryId")
            return nil
        }
        return await read("loadCursor", fallback: nil) {
            try await $0.loadCursor(providerId: providerId.uuidString, libraryId: libraryId)
        }
    }

    func markFullReconciled(providerId: UUID, libraryId: String, at date: Date) async {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.markFullReconciled: rejecting empty libraryId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.saveCursor(
                providerId: providerId.uuidString,
                libraryId: libraryId,
                lastSyncedAt: date,
                lastFullReconciledAt: date
            )
        } catch {
            AppLogger.general.error("BookStore.markFullReconciled failed: \(error)")
        }
    }
}

extension SwiftDataBookStore.Worker {
    func replaceLibrary(books: [Book], libraryId: String, providerId: String, allowSparseResult: Bool) throws {
        let books = deduplicatedBooks(books)

        let start = try beginReconciliation(libraryId: libraryId, providerId: providerId)

        let pageSize = 500
        for chunkStart in stride(from: 0, to: books.count, by: pageSize) {
            let chunkEnd = Swift.min(chunkStart + pageSize, books.count)
            try upsertReconciledPage(books: Array(books[chunkStart..<chunkEnd]), generation: start.generation)
        }
        _ = try endReconciliation(
            libraryId: libraryId,
            providerId: providerId,
            generation: start.generation,
            existingCountBefore: start.existingCount,
            allowSparseResult: allowSparseResult
        )
    }

    func beginReconciliation(libraryId: String, providerId: String) throws -> ReconciliationStart {
        let generation = Int(Date().timeIntervalSinceReferenceDate * 1000)
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.libraryId == libraryId && $0.providerId == providerId }
        )
        let existingCount = try modelContext.fetchCount(descriptor)
        return ReconciliationStart(generation: generation, existingCount: existingCount)
    }

    func upsertReconciledPage(books: [Book], generation: Int) throws {
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
            if let record = existingByUniqueId[book.uniqueId] {
                record.update(from: book)
                record.syncGeneration = generation
            } else {
                let record = BookRecord(from: book)
                record.syncGeneration = generation
                modelContext.insert(record)
                existingByUniqueId[book.uniqueId] = record
            }
        }
        try modelContext.save()
    }

    func endReconciliation(
        libraryId: String,
        providerId: String,
        generation: Int,
        existingCountBefore: Int,
        allowSparseResult: Bool = false
    ) throws -> ReconciliationOutcome {
        let incomingDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.libraryId == libraryId
                    && $0.providerId == providerId
                    && $0.syncGeneration == generation
            }
        )
        let incomingCount = try modelContext.fetchCount(incomingDescriptor)

        if existingCountBefore >= 100
            && incomingCount * 2 < existingCountBefore
            && !allowSparseResult
        {
            AppLogger.general.error(
                "BookStore.endReconciliation: refusing sparse response for libraryId=\(libraryId) - incoming \(incomingCount) vs existing \(existingCountBefore). Orphans preserved."
            )
            return .refusedSparseResponse(existing: existingCountBefore, incoming: incomingCount)
        }

        let orphanDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.libraryId == libraryId
                    && $0.providerId == providerId
                    && $0.syncGeneration != generation
            }
        )
        let toDeleteCount = try modelContext.fetchCount(orphanDescriptor)

        try modelContext.delete(
            model: BookRecord.self,
            where: #Predicate {
                $0.libraryId == libraryId
                    && $0.providerId == providerId
                    && $0.syncGeneration != generation
            }
        )
        try modelContext.save()

        return .completed(deleted: toDeleteCount, kept: incomingCount)
    }

    func applyDelta(books: [Book], libraryId: String, providerId: String) throws {
        let books = deduplicatedBooks(books)
        guard !books.isEmpty else { return }
        let incomingIds = Set(books.map { $0.uniqueId })
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { record in
                record.libraryId == libraryId
                    && record.providerId == providerId
                    && incomingIds.contains(record.uniqueId)
            }
        )
        let existingRecords = try modelContext.fetch(descriptor)
        var existingByUniqueId = Dictionary(
            existingRecords.map { ($0.uniqueId, $0) },
            uniquingKeysWith: { _, new in new }
        )

        for book in books {
            if let record = existingByUniqueId[book.uniqueId] {
                record.update(from: book)
            } else {
                let record = BookRecord(from: book)
                modelContext.insert(record)
                existingByUniqueId[book.uniqueId] = record
            }
        }
        try modelContext.save()
    }

    func loadCursor(providerId: String, libraryId: String) throws -> LibrarySyncCursorSnapshot? {
        let descriptor = FetchDescriptor<LibrarySyncCursor>(
            predicate: #Predicate { $0.providerId == providerId && $0.libraryId == libraryId }
        )
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        return LibrarySyncCursorSnapshot(
            providerId: row.providerId,
            libraryId: row.libraryId,
            lastSyncedAt: row.lastSyncedAt,
            lastFullReconciledAt: row.lastFullReconciledAt
        )
    }

    func saveCursor(providerId: String, libraryId: String, lastSyncedAt: Date, lastFullReconciledAt: Date?) throws {
        let descriptor = FetchDescriptor<LibrarySyncCursor>(
            predicate: #Predicate { $0.providerId == providerId && $0.libraryId == libraryId }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.lastSyncedAt = lastSyncedAt
            if let full = lastFullReconciledAt {
                existing.lastFullReconciledAt = full
            }
        } else {
            modelContext.insert(
                LibrarySyncCursor(
                    providerId: providerId,
                    libraryId: libraryId,
                    lastSyncedAt: lastSyncedAt,
                    lastFullReconciledAt: lastFullReconciledAt ?? .distantPast
                )
            )
        }
        try modelContext.save()
    }
}
