import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func downloadedAudiobooks(storageKeys: Set<String>) async -> [Book] {
        guard !storageKeys.isEmpty else { return [] }
        let worker = await makeBackgroundWorker()
        do {
            if let storeURL = persistentStoreURL {
                do {
                    let lookup = Task.detached(priority: .userInitiated) {
                        try BookStoreSQLTuner.downloadedAudiobookIDs(at: storeURL, storageKeys: storageKeys)
                    }
                    let ids = try await withTaskCancellationHandler {
                        try await lookup.value
                    } onCancel: {
                        lookup.cancel()
                    }
                    try Task.checkCancellation()
                    return try await worker.fetchBooksByStableIds(ids: ids).values.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                } catch is CancellationError {
                    return []
                } catch {
                    AppLogger.general.warning("BookStore download identity lookup failed; using the model store: \(error)")
                }
            }
            return try await worker.fetchDownloadedAudiobooks(storageKeys: storageKeys)
        } catch {
            AppLogger.general.error("BookStore.downloadedAudiobooks failed: \(error)")
            return []
        }
    }

    func booksForDownloadImport(stableIds: Set<String>) async throws -> [Book] {
        try Task.checkCancellation()
        let ids = stableIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        let worker = await makeBackgroundWorker()
        try Task.checkCancellation()
        return try await worker.fetchBooksForDownloadImport(stableIds: ids)
    }

    func downloadedEbooks(limit: Int) async -> [Book] {
        guard limit > 0 else { return [] }
        let worker = await makeBackgroundWorker()
        do {
            let pageSize = 200
            let availability = await ebookImporter.offlineAvailability()
            var cursor: Worker.DownloadedEbookCursor?
            var books: [Book] = []
            repeat {
                try Task.checkCancellation()
                let page = try await worker.fetchDownloadedEbookCandidates(after: cursor, limit: pageSize)
                let offline = await availability.existingBooks(in: page.books)
                books.append(contentsOf: offline.prefix(limit - books.count))
                cursor = page.next
            } while books.count < limit && cursor != nil
            return books
        } catch is CancellationError {
            return []
        } catch {
            AppLogger.general.error("BookStore.downloadedEbooks failed: \(error)")
            return []
        }
    }

    func registerDownloadIfMissing(_ book: Book) async throws {
        guard !book.uniqueId.isEmpty, !book.stableId.isEmpty else { return }
        try await makeWorker().registerDownloadIfMissing(book)
        BookStoreChangeNotifier.notify()
    }

    func updateDownloadedEbook(uniqueId: String, fileURL: URL, epub3Features: EPUB3Features?) async throws -> Bool {
        guard !uniqueId.isEmpty else { return false }
        let stored = try await makeWorker().updateDownloadedEbook(
            uniqueId: uniqueId, path: fileURL.path, hasMediaOverlay: epub3Features?.hasMediaOverlay
        )
        if stored { BookStoreChangeNotifier.notify() }
        return stored
    }

    func updateEbookFileURL(uniqueId: String, url: URL?) async {
        guard !uniqueId.isEmpty else {
            AppLogger.general.error("BookStore.updateEbookFileURL: rejecting empty uniqueId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.updateEbookFileURL(uniqueId: uniqueId, path: url?.path)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.updateEbookFileURL failed: \(error)")
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchDownloadedAudiobooks(storageKeys: Set<String>) throws -> [Book] {
        guard !storageKeys.isEmpty else { return [] }
        let audioType = AppMediaType.audiobook.rawValue
        var stableIds = Set<String>()
        var lowerBound = ""
        while true {
            try Task.checkCancellation()
            let cursor = lowerBound
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == audioType && !$0.isDeleted && $0.uniqueId > cursor
                },
                sortBy: [SortDescriptor(\BookRecord.uniqueId, comparator: .lexical)]
            )
            descriptor.fetchLimit = 1000
            descriptor.propertiesToFetch = [\BookRecord.uniqueId, \BookRecord.stableId]
            let next = try autoreleasepool {
                let records = try modelContext.fetch(descriptor)
                for record in records where storageKeys.contains(LocalStorageManager.sanitizedId(for: record.stableId)) {
                    stableIds.insert(record.stableId)
                }
                return records.count == 1000 ? records.last?.uniqueId : nil
            }
            guard let next else { break }
            lowerBound = next
        }
        return try fetchBooksByStableIds(ids: stableIds).values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func fetchBooksForDownloadImport(stableIds: Set<String>) throws -> [Book] {
        let ids = Array(stableIds)
        var books: [String: Book] = [:]
        for offset in stride(from: 0, to: ids.count, by: 400) {
            try Task.checkCancellation()
            let batch = Set(ids[offset..<min(offset + 400, ids.count)])
            let downloaded = try modelContext.fetch(FetchDescriptor<BookRecord>(predicate: #Predicate {
                !$0.isDeleted && batch.contains($0.stableId)
            })).compactMap { $0.toBook() }
            let linkedIds = Set(downloaded.flatMap {
                [$0.linkedAudiobookStableId, $0.readAloudSourceStableId].compactMap { $0 }
            })
            let linked = linkedIds.isEmpty ? [] : try modelContext.fetch(FetchDescriptor<BookRecord>(predicate: #Predicate {
                !$0.isDeleted && linkedIds.contains($0.stableId)
            })).compactMap { $0.toBook() }
            let optionalIds = batch.map { Optional($0) }
            let reverseLinks = FetchDescriptor<BookRecord>(predicate: #Predicate {
                !$0.isDeleted && (optionalIds.contains($0.linkedAudiobookStableId)
                    || optionalIds.contains($0.readAloudSourceStableId))
            })
            for book in downloaded { books[book.uniqueId] = book }
            for book in linked { books[book.uniqueId] = book }
            for record in try modelContext.fetch(reverseLinks) {
                try Task.checkCancellation()
                if let book = record.toBook() { books[book.uniqueId] = book }
            }
        }
        try Task.checkCancellation()
        return books.values.sorted {
            if $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            return $0.uniqueId < $1.uniqueId
        }
    }

    typealias DownloadedEbookCursor = (lastUpdate: Date, uniqueId: String)

    func fetchDownloadedEbookCandidates(
        after cursor: DownloadedEbookCursor?,
        limit: Int
    ) throws -> (books: [Book], next: DownloadedEbookCursor?) {
        let ebookType = "ebook"
        let localSource = Book.BookSource.local.rawValue
        // Matching index order avoids sorting the catalog again for every page.
        let sort = [
            SortDescriptor(\BookRecord.lastUpdate, order: .reverse),
            SortDescriptor(\BookRecord.uniqueId, comparator: .lexical, order: .reverse),
        ]
        var descriptor: FetchDescriptor<BookRecord>
        if let cursor {
            let cursorDate = cursor.lastUpdate
            let cursorId = cursor.uniqueId
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isDeleted
                        && !$0.isHidden
                        && ($0.ebookFileURLPath != nil || ($0.source == localSource && $0.filePath != nil))
                        && $0.lastUpdate <= cursorDate
                        && ($0.lastUpdate < cursorDate || $0.uniqueId < cursorId)
                },
                sortBy: sort
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isDeleted
                        && !$0.isHidden
                        && ($0.ebookFileURLPath != nil || ($0.source == localSource && $0.filePath != nil))
                },
                sortBy: sort
            )
        }
        descriptor.fetchLimit = limit
        return try autoreleasepool {
            let records = try modelContext.fetch(descriptor)
            let next = records.count == limit
                ? records.last.map { (lastUpdate: $0.lastUpdate, uniqueId: $0.uniqueId) }
                : nil
            return (records.compactMap { $0.toBook() }, next)
        }
    }

    func registerDownloadIfMissing(_ book: Book) throws {
        let uid = book.uniqueId
        var descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.uniqueId == uid })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return }
        modelContext.insert(BookRecord(from: book))
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
        try modelContext.save()
    }

    func updateDownloadedEbook(uniqueId uid: String, path: String, hasMediaOverlay: Bool?) throws -> Bool {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.uniqueId == uid && !$0.isDeleted }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return false }
        record.ebookFileURLPath = path
        if let hasMediaOverlay { record.epub3HasMediaOverlay = hasMediaOverlay }
        try modelContext.save()
        return true
    }

    func updateEbookFileURL(uniqueId uid: String, path: String?) throws {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.uniqueId == uid }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.ebookFileURLPath = path
        try modelContext.save()
    }
}
