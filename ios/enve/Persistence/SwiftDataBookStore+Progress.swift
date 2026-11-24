import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func updateProgress(uniqueId: String, currentTime: TimeInterval, isFinished: Bool, lastUpdate: Date) async {
        guard !uniqueId.isEmpty else {
            AppLogger.general.error("BookStore.updateProgress: rejecting empty uniqueId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.updateProgress(uniqueId: uniqueId, currentTime: currentTime, isFinished: isFinished, lastUpdate: lastUpdate)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.updateProgress failed: \(error)")
        }
    }

    func applyAuthoritativeProgress(_ updates: [AuthoritativeProgressUpdate]) async {
        guard !updates.isEmpty else { return }
        let worker = makeWorker()
        do {
            try await worker.applyAuthoritativeProgress(updates)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.applyAuthoritativeProgress failed: \(error)")
        }
    }

    func updateEbookProgress(uniqueId: String, ebookProgress: Double?, epubLocator: String?, isFinished: Bool, lastUpdate: Date) async {
        guard !uniqueId.isEmpty else {
            AppLogger.general.error("BookStore.updateEbookProgress: rejecting empty uniqueId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.updateEbookProgress(
                uniqueId: uniqueId,
                ebookProgress: ebookProgress,
                epubLocator: epubLocator,
                isFinished: isFinished,
                lastUpdate: lastUpdate
            )
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.updateEbookProgress failed: \(error)")
        }
    }

    func upsertProgress(
        bookUniqueId: String,
        stableId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        ebookProgress: Double?,
        epubLocator: String?,
        isFinished: Bool,
        lastUpdate: Date,
        hideFromContinue: Bool,
        preserveEbookPosition: Bool
    ) async {
        guard !bookUniqueId.isEmpty, !stableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertProgress: rejecting empty bookUniqueId or stableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertProgressRecord(
                bookUniqueId: bookUniqueId,
                stableId: stableId,
                currentTime: currentTime,
                duration: duration,
                ebookProgress: ebookProgress,
                epubLocator: epubLocator,
                isFinished: isFinished,
                lastUpdate: lastUpdate,
                hideFromContinue: hideFromContinue,
                preserveEbookPosition: preserveEbookPosition
            )
        } catch {
            AppLogger.general.error("BookStore.upsertProgress failed: \(error)")
        }
    }

    func progress(forBookUniqueId uid: String) async -> BookProgressSnapshot? {
        await read("progress", fallback: nil) { try await $0.fetchProgress(forBookUniqueId: uid) }
    }

    func importLegacyProgress(
        _ entries: [(
            bookUniqueId: String, stableId: String, currentTime: TimeInterval,
            duration: TimeInterval, isFinished: Bool, lastUpdate: Date
        )]
    ) async {
        let worker = makeWorker()
        do {
            try await worker.importProgressEntries(entries)
            AppLogger.general.info("BookStore: imported \(entries.count) legacy progress entries")
        } catch {
            AppLogger.general.error("BookStore.importLegacyProgress failed: \(error)")
        }
    }

    func booksWithProgress(providerId: UUID) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksWithProgress(
                providerId: providerId.uuidString
            )
        } catch {
            AppLogger.general.error("BookStore.booksWithProgress failed: \(error)")
            return []
        }
    }
}

extension SwiftDataBookStore.Worker {
    func updateProgress(uniqueId uid: String, currentTime: TimeInterval, isFinished: Bool, lastUpdate: Date) throws {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.uniqueId == uid }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        guard lastUpdate >= record.lastUpdate else { return }
        record.currentTime = currentTime
        record.isFinished = isFinished
        record.lastUpdate = lastUpdate
        if let source = Book.BookSource(rawValue: record.source) {
            record.serverReadStatus = Book.readStatusAfterLocalProgress(
                record.serverReadStatus,
                source: source,
                hasProgress: currentTime > 0,
                isFinished: isFinished
            )
        }
        record.refreshSortKeys()
        try modelContext.save()
    }

    func applyAuthoritativeProgress(_ updates: [AuthoritativeProgressUpdate]) throws {
        guard !updates.isEmpty else { return }
        let uniqueIds = Set(updates.map(\.bookUniqueId))

        let bookDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { uniqueIds.contains($0.uniqueId) }
        )
        var booksByUniqueId: [String: BookRecord] = [:]
        for record in try modelContext.fetch(bookDescriptor) {
            booksByUniqueId[record.uniqueId] = record
        }

        let progressDescriptor = FetchDescriptor<MediaProgressRecord>(
            predicate: #Predicate { uniqueIds.contains($0.bookUniqueId) }
        )
        var progressByUniqueId: [String: MediaProgressRecord] = [:]
        for record in try modelContext.fetch(progressDescriptor) {
            progressByUniqueId[record.bookUniqueId] = record
        }

        for update in updates {
            if let book = booksByUniqueId[update.bookUniqueId] {
                book.currentTime = update.currentTime
                book.ebookProgress = update.ebookProgress
                book.epubLocator = update.epubLocator
                book.isFinished = update.isFinished
                book.lastUpdate = update.lastUpdate
                book.hideFromContinue = update.hideFromContinue
                book.serverReadStatus = update.serverReadStatus
                book.refreshSortKeys()
            }

            if let progress = progressByUniqueId[update.bookUniqueId] {
                progress.stableId = update.stableId
                progress.currentTime = update.currentTime
                progress.duration = update.duration
                progress.ebookProgress = update.ebookProgress
                progress.epubLocator = update.epubLocator
                progress.isFinished = update.isFinished
                progress.lastUpdate = update.lastUpdate
                progress.hideFromContinue = update.hideFromContinue
            } else {
                let progress = MediaProgressRecord(
                    bookUniqueId: update.bookUniqueId,
                    stableId: update.stableId,
                    currentTime: update.currentTime,
                    duration: update.duration,
                    ebookProgress: update.ebookProgress,
                    epubLocator: update.epubLocator,
                    isFinished: update.isFinished,
                    lastUpdate: update.lastUpdate,
                    hideFromContinue: update.hideFromContinue
                )
                modelContext.insert(progress)
                progressByUniqueId[update.bookUniqueId] = progress
            }
        }

        try modelContext.save()
    }

    func updateEbookProgress(
        uniqueId uid: String,
        ebookProgress: Double?,
        epubLocator: String?,
        isFinished: Bool,
        lastUpdate: Date
    ) throws {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.uniqueId == uid }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        guard lastUpdate >= record.lastUpdate else { return }
        record.ebookProgress = ebookProgress
        record.epubLocator = epubLocator
        record.isFinished = isFinished
        record.lastUpdate = lastUpdate
        if let source = Book.BookSource(rawValue: record.source) {
            record.serverReadStatus = Book.readStatusAfterLocalProgress(
                record.serverReadStatus,
                source: source,
                hasProgress: (ebookProgress ?? 0) > 0,
                isFinished: isFinished
            )
        }
        record.refreshSortKeys()

        try mirrorEbookProgressIfNeeded(
            bookUniqueId: record.uniqueId,
            stableId: record.stableId,
            currentTime: record.currentTime,
            duration: record.duration ?? 0,
            ebookProgress: ebookProgress,
            epubLocator: epubLocator,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            hideFromContinue: record.hideFromContinue
        )
        try modelContext.save()
    }

    func upsertProgressRecord(
        bookUniqueId: String,
        stableId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        ebookProgress: Double?,
        epubLocator: String?,
        isFinished: Bool,
        lastUpdate: Date,
        hideFromContinue: Bool,
        preserveEbookPosition: Bool
    ) throws {
        let uid = bookUniqueId
        var descriptor = FetchDescriptor<MediaProgressRecord>(
            predicate: #Predicate { $0.bookUniqueId == uid }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            guard lastUpdate >= existing.lastUpdate else { return }
            existing.stableId = stableId
            existing.currentTime = currentTime
            existing.duration = duration
            if preserveEbookPosition {
                if let ebookProgress {
                    existing.ebookProgress = ebookProgress
                }
                if let epubLocator {
                    existing.epubLocator = epubLocator
                }
            } else {
                existing.ebookProgress = ebookProgress
                existing.epubLocator = epubLocator
            }
            existing.isFinished = isFinished
            existing.lastUpdate = lastUpdate
            existing.hideFromContinue = hideFromContinue
        } else {
            modelContext.insert(
                MediaProgressRecord(
                    bookUniqueId: bookUniqueId,
                    stableId: stableId,
                    currentTime: currentTime,
                    duration: duration,
                    ebookProgress: ebookProgress,
                    epubLocator: epubLocator,
                    isFinished: isFinished,
                    lastUpdate: lastUpdate,
                    hideFromContinue: hideFromContinue
                )
            )
        }
        try modelContext.save()
    }

    func fetchProgress(forBookUniqueId uid: String) throws -> BookProgressSnapshot? {
        var descriptor = FetchDescriptor<MediaProgressRecord>(
            predicate: #Predicate { $0.bookUniqueId == uid }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return BookProgressSnapshot(
            bookUniqueId: record.bookUniqueId,
            stableId: record.stableId,
            currentTime: record.currentTime,
            duration: record.duration,
            ebookProgress: record.ebookProgress,
            epubLocator: record.epubLocator,
            isFinished: record.isFinished,
            lastUpdate: record.lastUpdate,
            hideFromContinue: record.hideFromContinue
        )
    }

    func importProgressEntries(
        _ entries: [(
            bookUniqueId: String, stableId: String, currentTime: TimeInterval,
            duration: TimeInterval, isFinished: Bool, lastUpdate: Date
        )]
    ) throws {
        for entry in entries {
            let uid = entry.bookUniqueId
            var descriptor = FetchDescriptor<MediaProgressRecord>(
                predicate: #Predicate { $0.bookUniqueId == uid }
            )
            descriptor.fetchLimit = 1
            if try modelContext.fetch(descriptor).first == nil {
                modelContext.insert(
                    MediaProgressRecord(
                        bookUniqueId: entry.bookUniqueId,
                        stableId: entry.stableId,
                        currentTime: entry.currentTime,
                        duration: entry.duration,
                        ebookProgress: nil,
                        epubLocator: nil,
                        isFinished: entry.isFinished,
                        lastUpdate: entry.lastUpdate,
                        hideFromContinue: false
                    )
                )
            }
        }
        try modelContext.save()
    }

    func mirrorEbookProgressIfNeeded(
        bookUniqueId: String,
        stableId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        ebookProgress: Double?,
        epubLocator: String?,
        isFinished: Bool,
        lastUpdate: Date,
        hideFromContinue: Bool
    ) throws {
        let locator = epubLocator.flatMap { $0.isEmpty ? nil : $0 }
        guard ebookProgress != nil || locator != nil else { return }

        var descriptor = FetchDescriptor<MediaProgressRecord>(
            predicate: #Predicate { $0.bookUniqueId == bookUniqueId }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            guard lastUpdate >= existing.lastUpdate else { return }
            existing.stableId = stableId
            existing.currentTime = currentTime
            existing.duration = duration
            existing.ebookProgress = ebookProgress
            existing.epubLocator = locator
            existing.isFinished = isFinished
            existing.lastUpdate = lastUpdate
            existing.hideFromContinue = hideFromContinue
        } else {
            modelContext.insert(
                MediaProgressRecord(
                    bookUniqueId: bookUniqueId,
                    stableId: stableId,
                    currentTime: currentTime,
                    duration: duration,
                    ebookProgress: ebookProgress,
                    epubLocator: locator,
                    isFinished: isFinished,
                    lastUpdate: lastUpdate,
                    hideFromContinue: hideFromContinue
                )
            )
        }
    }

    func fetchBooksWithProgress(providerId: String) throws -> [Book] {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.providerId == providerId
                    && !$0.isDeleted
                    && ($0.currentTime > 0 || $0.ebookProgress != nil || $0.isFinished || $0.hideFromContinue)
            }
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }
}
