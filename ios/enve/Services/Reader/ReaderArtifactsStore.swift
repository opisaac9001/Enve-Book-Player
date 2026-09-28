import Foundation
import Logging

@MainActor
final class ReaderArtifactsStore {
    static let shared = ReaderArtifactsStore()

    private static let bookmarksPrefix = "bookmarks_"
    private static let annotationsPrefix = "readerAnnotations_"
    private static let chaptersPrefix = "cachedChapters_"

    private static let migrationFlagKey = "enve.readerArtifactsMigratedToBookStoreV1"

    private let userDefaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        userDefaults = defaults
    }

    var hasMigratedToBookStore: Bool {
        userDefaults.bool(forKey: Self.migrationFlagKey)
    }

    func migrateToBookStoreIfNeeded(bookStore: any ReaderArtifactRepository) async {
        guard !hasMigratedToBookStore else { return }

        var migratedBookmarks = 0
        var migratedAnnotations = 0
        var migratedChapters = 0

        for (key, value) in userDefaults.dictionaryRepresentation() {
            guard let data = value as? Data else { continue }

            if key.hasPrefix(Self.bookmarksPrefix) {
                let bookId = String(key.dropFirst(Self.bookmarksPrefix.count))
                guard let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data),
                    !bookmarks.isEmpty
                else { continue }
                await bookStore.importLegacyBookmarks(bookmarks, bookStableId: bookId)
                migratedBookmarks += bookmarks.count
            } else if key.hasPrefix(Self.annotationsPrefix) {
                let bookId = String(key.dropFirst(Self.annotationsPrefix.count))
                guard let annotations = try? JSONDecoder().decode([ReaderAnnotation].self, from: data),
                    !annotations.isEmpty
                else { continue }
                await bookStore.importLegacyAnnotations(annotations, bookStableId: bookId)
                migratedAnnotations += annotations.count
            } else if key.hasPrefix(Self.chaptersPrefix) {
                let bookId = String(key.dropFirst(Self.chaptersPrefix.count))
                guard let chapters = try? JSONDecoder().decode([Chapter].self, from: data),
                    !chapters.isEmpty
                else { continue }
                await bookStore.cacheChapters(chapters, forBookStableId: bookId)
                migratedChapters += chapters.count
            }
        }

        userDefaults.set(true, forKey: Self.migrationFlagKey)
        AppLogger.general.info(
            "ReaderArtifactsStore migration: \(migratedBookmarks) bookmarks, \(migratedAnnotations) annotations, \(migratedChapters) chapters → SwiftData"
        )
    }

    func saveBookmarks(bookId: String, bookmarks: [Bookmark]) {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            userDefaults.set(encoded, forKey: Self.bookmarksPrefix + bookId)
        }
    }

    func loadBookmarks(bookId: String) -> [Bookmark] {
        guard let data = userDefaults.data(forKey: Self.bookmarksPrefix + bookId),
            let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data)
        else {
            return []
        }
        return bookmarks
    }

    func clearBookmarks(bookId: String) {
        userDefaults.removeObject(forKey: Self.bookmarksPrefix + bookId)
    }

    // Rekeys audio-owned bookmarks and cached chapters; the source is cleared only after the destination write lands.
    func migrateAudiobookArtifacts(fromBookId oldId: String, toBookId newId: String) {
        guard oldId != newId else { return }

        let source = loadBookmarks(bookId: oldId)
        let moved = source.filter { $0.mediaType == .audiobook }
        if !moved.isEmpty {
            var destination = loadBookmarks(bookId: newId)
            let destinationIds = Set(destination.map { $0.id })
            for bookmark in moved where !destinationIds.contains(bookmark.id) {
                destination.append(
                    Bookmark(
                        id: bookmark.id,
                        bookId: newId,
                        position: bookmark.position,
                        title: bookmark.title,
                        note: bookmark.note,
                        timestamp: bookmark.timestamp,
                        locator: bookmark.locator,
                        mediaType: .audiobook,
                        chapterTitle: bookmark.chapterTitle,
                        remoteID: bookmark.remoteID,
                        isRemotePlaceholder: bookmark.isRemotePlaceholder
                    )
                )
            }
            if let encoded = try? JSONEncoder().encode(destination) {
                userDefaults.set(encoded, forKey: Self.bookmarksPrefix + newId)
                let remaining = source.filter { $0.mediaType != .audiobook }
                if remaining.isEmpty {
                    clearBookmarks(bookId: oldId)
                } else {
                    saveBookmarks(bookId: oldId, bookmarks: remaining)
                }
            }
        }

        if let chapters = loadCachedChapters(bookId: oldId) {
            if loadCachedChapters(bookId: newId) == nil {
                saveCachedChapters(bookId: newId, chapters: chapters)
            }
            clearCachedChapters(bookId: oldId)
        }
    }

    func saveAnnotations(bookId: String, annotations: [ReaderAnnotation]) {
        do {
            let encoded = try JSONEncoder().encode(annotations)
            userDefaults.set(encoded, forKey: Self.annotationsPrefix + bookId)
        } catch {
            AppLogger.general.error(
                "Failed to encode reader annotations for bookId=\(DiagnosticLogSanitizer.identifier(for: bookId)): \(error.localizedDescription)"
            )
        }
    }

    func loadAnnotations(bookId: String) -> [ReaderAnnotation] {
        guard let data = userDefaults.data(forKey: Self.annotationsPrefix + bookId),
            let annotations = try? JSONDecoder().decode([ReaderAnnotation].self, from: data)
        else {
            return []
        }
        return annotations
    }

    func saveCachedChapters(bookId: String, chapters: [Chapter]) {
        if let encoded = try? JSONEncoder().encode(chapters) {
            userDefaults.set(encoded, forKey: Self.chaptersPrefix + bookId)
            AppLogger.network.debug(
                "Cached \(chapters.count) chapters for bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
            )
        }
    }

    func loadCachedChapters(bookId: String) -> [Chapter]? {
        guard let data = userDefaults.data(forKey: Self.chaptersPrefix + bookId),
            let chapters = try? JSONDecoder().decode([Chapter].self, from: data)
        else {
            return nil
        }
        return chapters
    }

    /// Drops a cache that holds untimed ebook contents so the audiobook's chapters are fetched again.
    func loadCachedAudioChapters(for book: Book) -> [Chapter]? {
        for bookId in book.id == book.stableId ? [book.stableId] : [book.stableId, book.id] {
            guard let chapters = loadCachedChapters(bookId: bookId) else { continue }
            if chapters.hasAudioTimeline { return chapters }
            clearCachedChapters(bookId: bookId)
        }
        return nil
    }

    func clearCachedChapters(bookId: String) {
        userDefaults.removeObject(forKey: Self.chaptersPrefix + bookId)
    }
}
