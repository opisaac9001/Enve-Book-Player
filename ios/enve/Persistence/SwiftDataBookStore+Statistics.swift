import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func finishedBookSummaries() async -> [FinishedBookSummary] {
        await read("finishedBookSummaries", fallback: []) { try await $0.fetchFinishedBookSummaries() }
    }

    func bookStatisticsSlices() async -> [BookStatisticsSlice] {
        await read("bookStatisticsSlices", fallback: []) { try await $0.fetchBookStatisticsSlices() }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchFinishedBookSummaries() throws -> [FinishedBookSummary] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.isFinished && !$0.isDeleted }
        )
        descriptor.propertiesToFetch = [
            \BookRecord.stableId,
            \BookRecord.mediaType,
            \BookRecord.lastUpdate,
        ]
        return try modelContext.fetch(descriptor).compactMap { record in
            guard let mediaType = AppMediaType(rawValue: record.mediaType) else { return nil }
            return FinishedBookSummary(
                stableId: record.stableId,
                mediaType: mediaType,
                lastUpdate: record.lastUpdate
            )
        }
    }

    func fetchBookStatisticsSlices() throws -> [BookStatisticsSlice] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && !$0.isPodcastEpisode }
        )
        descriptor.propertiesToFetch = [
            \BookRecord.bookId,
            \BookRecord.title,
            \BookRecord.mediaType,
            \BookRecord.author,
            \BookRecord.narrator,
            \BookRecord.series,
            \BookRecord.publisher,
            \BookRecord.genres,
            \BookRecord.language,
            \BookRecord.isbn,
            \BookRecord.thumb,
            \BookRecord.publishedYear,
            \BookRecord.addedAt,
            \BookRecord.duration,
            \BookRecord.isFinished,
            \BookRecord.currentTime,
            \BookRecord.ebookProgress,
            \BookRecord.epubLocator,
        ]
        return try modelContext.fetch(descriptor).compactMap { record in
            guard let mediaType = AppMediaType(rawValue: record.mediaType) else { return nil }

            let progress: Double
            if record.isFinished {
                progress = 1
            } else if mediaType == .ebook {
                let stored = Book.normalizedFractionProgress(record.ebookProgress) ?? 0
                if let locator = Book.progressFromEbookLocator(record.epubLocator) {
                    progress = stored <= 0.001 || locator > stored + 0.02 ? locator : stored
                } else {
                    progress = stored
                }
            } else if let duration = record.duration, duration > 0 {
                progress = min(max(record.currentTime / duration, 0), 1)
            } else {
                progress = 0
            }

            return BookStatisticsSlice(
                id: record.bookId,
                title: record.title,
                mediaType: mediaType,
                author: record.author,
                narrator: record.narrator,
                series: record.series,
                publisher: record.publisher,
                genres: record.genres,
                language: record.language,
                isbn: record.isbn,
                thumb: record.thumb,
                publishedYear: record.publishedYear,
                addedAt: record.addedAt,
                duration: record.duration,
                isFinished: record.isFinished,
                progress: progress
            )
        }
    }
}
