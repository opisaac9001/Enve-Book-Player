import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func readerArtifactBookStableIds() async -> Set<String> {
        await read("readerArtifactBookStableIds", fallback: []) { try await $0.fetchReaderArtifactBookStableIds() }
    }

    @discardableResult
    func migrateAudiobookArtifacts(fromBookStableId oldId: String, toBookStableId newId: String) async -> Bool {
        guard !oldId.isEmpty, !newId.isEmpty, oldId != newId else { return false }
        let worker = makeWorker()
        do {
            try await worker.migrateAudiobookArtifactRecords(fromBookStableId: oldId, toBookStableId: newId)
            return true
        } catch {
            AppLogger.general.error("BookStore.migrateAudiobookArtifacts failed: \(error)")
            return false
        }
    }

    func cachedChapters(forBookStableId sid: String) async -> [Chapter]? {
        await read("cachedChapters", fallback: nil) { try await $0.fetchCachedChapters(forBookStableId: sid) }
    }

    func cacheChapters(_ chapters: [Chapter], forBookStableId sid: String) async {
        guard !sid.isEmpty else {
            AppLogger.general.error("BookStore.cacheChapters: rejecting empty bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.cacheChapterRecords(chapters, forBookStableId: sid)
        } catch {
            AppLogger.general.error("BookStore.cacheChapters failed: \(error)")
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchReaderArtifactBookStableIds() throws -> Set<String> {
        var annotationDescriptor = FetchDescriptor<AnnotationRecord>()
        annotationDescriptor.propertiesToFetch = [
            \AnnotationRecord.bookStableId,
            \AnnotationRecord.isRemotePlaceholder,
        ]
        var stableIds: Set<String> = Set(
            try modelContext.fetch(annotationDescriptor).compactMap { record in
                guard !record.isRemotePlaceholder else { return nil }
                return record.bookStableId
            }
        )

        var bookmarkDescriptor = FetchDescriptor<BookmarkRecord>()
        bookmarkDescriptor.propertiesToFetch = [
            \BookmarkRecord.bookStableId,
            \BookmarkRecord.note,
            \BookmarkRecord.isRemotePlaceholder,
        ]
        for record in try modelContext.fetch(bookmarkDescriptor) {
            guard !record.isRemotePlaceholder,
                let note = record.note,
                !note.isEmpty
            else { continue }
            stableIds.insert(record.bookStableId)
        }
        return stableIds
    }

    // One transaction so the source is never cleared without the destination write.
    func migrateAudiobookArtifactRecords(fromBookStableId oldId: String, toBookStableId newId: String) throws {
        let audioType = AppMediaType.audiobook.rawValue
        let sourceDescriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate { $0.bookStableId == oldId && $0.mediaType == audioType }
        )
        let sourceBookmarks = try modelContext.fetch(sourceDescriptor)
        if !sourceBookmarks.isEmpty {
            let destinationDescriptor = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.bookStableId == newId }
            )
            let destinationIds = Set(try modelContext.fetch(destinationDescriptor).map { $0.id })
            for record in sourceBookmarks {
                if destinationIds.contains(record.id) {
                    modelContext.delete(record)
                } else {
                    record.bookStableId = newId
                }
            }
        }

        var sourceChapters = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.bookStableId == oldId }
        )
        sourceChapters.fetchLimit = 1
        if let chapterCache = try modelContext.fetch(sourceChapters).first {
            var destinationChapters = FetchDescriptor<ChapterCacheRecord>(
                predicate: #Predicate { $0.bookStableId == newId }
            )
            destinationChapters.fetchLimit = 1
            if try modelContext.fetch(destinationChapters).first == nil {
                chapterCache.bookStableId = newId
            } else {
                modelContext.delete(chapterCache)
            }
        }

        try modelContext.save()
    }

    func fetchCachedChapters(forBookStableId sid: String) throws -> [Chapter]? {
        var descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.bookStableId == sid }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toChapters()
    }

    func cacheChapterRecords(_ chapters: [Chapter], forBookStableId sid: String) throws {
        var descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.bookStableId == sid }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.chaptersJSON = (try? JSONEncoder().encode(chapters)) ?? Data()
            existing.lastUpdate = Date()
        } else {
            modelContext.insert(ChapterCacheRecord(bookStableId: sid, chapters: chapters))
        }
        try modelContext.save()
    }
}
