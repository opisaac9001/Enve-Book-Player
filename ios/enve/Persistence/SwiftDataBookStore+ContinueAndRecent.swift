import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func continueListeningBooks(limit: Int) async -> [Book] {
        await read("continueListening", fallback: []) { try await $0.fetchContinueListening(limit: limit) }
    }

    func continueReadingBooks(limit: Int) async -> [Book] {
        await read("continueReading", fallback: []) { try await $0.fetchContinueReading(limit: limit) }
    }

    func recentBooks(limit: Int) async -> [Book] {
        await read("recentBooks", fallback: []) { try await $0.fetchRecent(mediaType: "audiobook", limit: limit) }
    }

    func recentEbooks(limit: Int) async -> [Book] {
        await read("recentEbooks", fallback: []) { try await $0.fetchRecent(mediaType: "ebook", limit: limit) }
    }
}

extension SwiftDataBookStore.Worker {
    private func fetchContinueBooks(_ descriptor: FetchDescriptor<BookRecord>, limit: Int) throws -> [Book] {
        guard limit > 0 else { return [] }
        var page = descriptor
        page.fetchLimit = limit
        var books: [Book] = []
        while books.count < limit {
            let records = try modelContext.fetch(page)
            guard !records.isEmpty else { break }
            books += records.compactMap { $0.toBook() }.filter { book in
                book.source != .booklore || book.serverReadStatus == nil
                    || ["READING", "RE_READING", "IN_PROGRESS"].contains(book.serverReadStatus ?? "")
            }
            if records.count < limit { break }
            page.fetchOffset = (page.fetchOffset ?? 0) + records.count
        }
        return Array(books.prefix(limit))
    }

    func fetchContinueListening(limit: Int) throws -> [Book] {
        let audioType = "audiobook"
        let readStatus = "READ"

        var audioDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == audioType
                    && !$0.isFinished
                    && !$0.isDeleted
                    && !$0.isHidden
                    && !$0.hideFromContinue
                    && $0.currentTime > 0
                    && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
            },
            sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
        )
        audioDescriptor.fetchLimit = limit

        return try fetchContinueBooks(audioDescriptor, limit: limit)
    }

    func fetchContinueReading(limit: Int) throws -> [Book] {
        let ebookType = "ebook"
        let readStatus = "READ"

        var progressDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == ebookType
                    && !$0.isFinished
                    && !$0.isDeleted
                    && !$0.isHidden
                    && !$0.hideFromContinue
                    && ($0.ebookProgress ?? 0) > 0.001
                    && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
            },
            sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
        )
        progressDescriptor.fetchLimit = limit

        var linkedAudiobookDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == ebookType
                    && !$0.isFinished
                    && !$0.isDeleted
                    && !$0.isHidden
                    && !$0.hideFromContinue
                    && $0.currentTime > 0
                    && $0.linkedAudiobookStableId != nil
                    && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
            },
            sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
        )
        linkedAudiobookDescriptor.fetchLimit = limit

        var readAloudDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == ebookType
                    && !$0.isFinished
                    && !$0.isDeleted
                    && !$0.isHidden
                    && !$0.hideFromContinue
                    && $0.currentTime > 0
                    && $0.readAloudSourceStableId != nil
                    && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
            },
            sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
        )
        readAloudDescriptor.fetchLimit = limit

        var mediaOverlayDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == ebookType
                    && !$0.isFinished
                    && !$0.isDeleted
                    && !$0.isHidden
                    && !$0.hideFromContinue
                    && $0.currentTime > 0
                    && $0.epub3HasMediaOverlay
                    && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
            },
            sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
        )
        mediaOverlayDescriptor.fetchLimit = limit

        let progressBooks = try fetchContinueBooks(progressDescriptor, limit: limit)
        let linkedBooks = try fetchContinueBooks(linkedAudiobookDescriptor, limit: limit)
        let readAloudBooks = try fetchContinueBooks(readAloudDescriptor, limit: limit)
        let mediaOverlayBooks = try fetchContinueBooks(mediaOverlayDescriptor, limit: limit)
        var seen = Set<String>()
        return (progressBooks + linkedBooks + readAloudBooks + mediaOverlayBooks)
            .filter { seen.insert($0.stableId).inserted }
            .sorted { $0.lastUpdate > $1.lastUpdate }
            .prefix(limit)
            .map { $0 }
    }

    func fetchRecent(mediaType: String, limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == mediaType && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }
}
