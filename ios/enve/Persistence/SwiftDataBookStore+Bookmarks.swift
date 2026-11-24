import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func bookmarkedBookStableIds() async -> Set<String> {
        await read("bookmarkedBookStableIds", fallback: []) { try await $0.fetchBookmarkedBookStableIds() }
    }

    func bookmarks(forBookStableId sid: String) async -> [Bookmark] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchBookmarks(forBookStableId: sid)
            return await MainActor.run {
                snapshots.map { s in
                    Bookmark(
                        id: s.id,
                        bookId: s.bookStableId,
                        position: s.position,
                        title: s.title,
                        note: s.note,
                        timestamp: s.timestamp,
                        locator: s.locator,
                        mediaType: AppMediaType(rawValue: s.mediaType) ?? .audiobook,
                        chapterTitle: s.chapterTitle,
                        remoteID: s.remoteID,
                        isRemotePlaceholder: s.isRemotePlaceholder
                    )
                }
            }
        } catch {
            AppLogger.general.error("BookStore.bookmarks failed: \(error)")
            return []
        }
    }

    func upsertBookmark(_ bookmark: Bookmark, bookStableId: String) async {
        guard !bookmark.id.isEmpty, !bookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertBookmark: rejecting empty bookmark id or bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertBookmarkRecord(
                id: bookmark.id,
                bookStableId: bookStableId,
                title: bookmark.title,
                position: bookmark.position,
                timestamp: bookmark.timestamp,
                note: bookmark.note,
                locator: bookmark.locator,
                mediaType: bookmark.mediaType.rawValue,
                chapterTitle: bookmark.chapterTitle,
                remoteID: bookmark.remoteID,
                isRemotePlaceholder: bookmark.isRemotePlaceholder
            )
        } catch {
            AppLogger.general.error("BookStore.upsertBookmark failed: \(error)")
        }
    }

    func deleteBookmark(id: String) async {
        guard !id.isEmpty else {
            AppLogger.general.error("BookStore.deleteBookmark: rejecting empty id")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.deleteBookmarkRecord(id: id)
        } catch {
            AppLogger.general.error("BookStore.deleteBookmark failed: \(error)")
        }
    }

    func replaceBookmarks(forBookStableId sid: String, bookmarks: [Bookmark]) async {
        guard !sid.isEmpty else {
            AppLogger.general.error("BookStore.replaceBookmarks: rejecting empty bookStableId")
            return
        }
        let validBookmarks = bookmarks.filter { !$0.id.isEmpty }
        if validBookmarks.count != bookmarks.count {
            AppLogger.general.error(
                "BookStore.replaceBookmarks: rejected \(bookmarks.count - validBookmarks.count) bookmark(s) with empty id"
            )
        }
        let worker = makeWorker()
        do {
            let tuples = validBookmarks.map {
                (
                    id: $0.id, title: $0.title, position: $0.position, timestamp: $0.timestamp,
                    note: $0.note, locator: $0.locator, mediaType: $0.mediaType.rawValue,
                    chapterTitle: $0.chapterTitle, remoteID: $0.remoteID,
                    isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.replaceBookmarkRecords(forBookStableId: sid, bookmarks: tuples)
        } catch {
            AppLogger.general.error("BookStore.replaceBookmarks failed: \(error)")
        }
    }

    func importLegacyBookmarks(_ bookmarks: [Bookmark], bookStableId: String) async {
        let worker = makeWorker()
        do {
            let tuples = bookmarks.map {
                (
                    id: $0.id, title: $0.title, position: $0.position, timestamp: $0.timestamp,
                    note: $0.note, locator: $0.locator, mediaType: $0.mediaType.rawValue,
                    chapterTitle: $0.chapterTitle, remoteID: $0.remoteID,
                    isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.importBookmarkRecords(tuples, bookStableId: bookStableId)
            AppLogger.general.info("BookStore: imported \(bookmarks.count) legacy bookmarks for \(bookStableId)")
        } catch {
            AppLogger.general.error("BookStore.importLegacyBookmarks failed: \(error)")
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchBookmarkedBookStableIds() throws -> Set<String> {

        var descriptor = FetchDescriptor<BookmarkRecord>()
        descriptor.propertiesToFetch = [\BookmarkRecord.bookStableId]
        let rows = try modelContext.fetch(descriptor)
        return Set(rows.map { $0.bookStableId })
    }

    func fetchBookmarks(forBookStableId sid: String) throws -> [BookmarkSnapshot] {
        let descriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate { $0.bookStableId == sid },
            sortBy: [SortDescriptor(\.position)]
        )
        return try modelContext.fetch(descriptor).map {
            BookmarkSnapshot(
                id: $0.id,
                bookStableId: $0.bookStableId,
                title: $0.title,
                position: $0.position,
                timestamp: $0.timestamp,
                note: $0.note,
                locator: $0.locator,
                mediaType: $0.mediaType,
                chapterTitle: $0.chapterTitle,
                remoteID: $0.remoteID,
                isRemotePlaceholder: $0.isRemotePlaceholder
            )
        }
    }

    func upsertBookmarkRecord(
        id: String,
        bookStableId: String,
        title: String,
        position: Double,
        timestamp: Date,
        note: String?,
        locator: String?,
        mediaType: String,
        chapterTitle: String?,
        remoteID: Int?,
        isRemotePlaceholder: Bool
    ) throws {
        let bid = id
        var descriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate { $0.id == bid }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.title = title
            existing.position = position
            existing.note = note
            existing.locator = locator
            existing.chapterTitle = chapterTitle
            existing.remoteID = remoteID
            existing.isRemotePlaceholder = isRemotePlaceholder
        } else {
            modelContext.insert(
                BookmarkRecord(
                    id: id,
                    bookStableId: bookStableId,
                    title: title,
                    position: position,
                    timestamp: timestamp,
                    note: note,
                    locator: locator,
                    mediaType: mediaType,
                    chapterTitle: chapterTitle,
                    remoteID: remoteID,
                    isRemotePlaceholder: isRemotePlaceholder
                )
            )
        }
        try modelContext.save()
    }

    func deleteBookmarkRecord(id bid: String) throws {
        var descriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate { $0.id == bid }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    func replaceBookmarkRecords(
        forBookStableId sid: String,
        bookmarks: [(
            id: String, title: String, position: Double,
            timestamp: Date, note: String?, locator: String?,
            mediaType: String, chapterTitle: String?,
            remoteID: Int?, isRemotePlaceholder: Bool
        )]
    ) throws {
        let existing = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate { $0.bookStableId == sid }
        )
        for record in try modelContext.fetch(existing) {
            modelContext.delete(record)
        }
        for b in bookmarks {
            modelContext.insert(
                BookmarkRecord(
                    id: b.id,
                    bookStableId: sid,
                    title: b.title,
                    position: b.position,
                    timestamp: b.timestamp,
                    note: b.note,
                    locator: b.locator,
                    mediaType: b.mediaType,
                    chapterTitle: b.chapterTitle,
                    remoteID: b.remoteID,
                    isRemotePlaceholder: b.isRemotePlaceholder
                )
            )
        }
        try modelContext.save()
    }

    func importBookmarkRecords(
        _ bookmarks: [(
            id: String, title: String, position: Double,
            timestamp: Date, note: String?, locator: String?,
            mediaType: String, chapterTitle: String?,
            remoteID: Int?, isRemotePlaceholder: Bool
        )],
        bookStableId: String
    ) throws {
        let existingDescriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate { $0.bookStableId == bookStableId }
        )
        let existingIds = Set(try modelContext.fetch(existingDescriptor).map { $0.id })
        for b in bookmarks where !existingIds.contains(b.id) {
            modelContext.insert(
                BookmarkRecord(
                    id: b.id,
                    bookStableId: bookStableId,
                    title: b.title,
                    position: b.position,
                    timestamp: b.timestamp,
                    note: b.note,
                    locator: b.locator,
                    mediaType: b.mediaType,
                    chapterTitle: b.chapterTitle,
                    remoteID: b.remoteID,
                    isRemotePlaceholder: b.isRemotePlaceholder
                )
            )
        }
        try modelContext.save()
    }
}
