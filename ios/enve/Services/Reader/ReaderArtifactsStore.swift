import Foundation
import Logging

@MainActor
final class ReaderArtifactsStore {
    static let shared = ReaderArtifactsStore()

    private static let bookmarksPrefix = "bookmarks_"
    private static let annotationsPrefix = "readerAnnotations_"
    private static let chaptersPrefix = "cachedChapters_"

    private static let migrationFlagKey = "enve.readerArtifactsMigratedToBookStoreV1"

    private let userDefaults = UserDefaults.standard

    private init() {}

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

    func bookmarkedBookIds() -> Set<String> {
        var result = Set<String>()
        for (key, value) in userDefaults.dictionaryRepresentation() where key.hasPrefix(Self.bookmarksPrefix) {
            guard let data = value as? Data,
                let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data),
                !bookmarks.isEmpty
            else { continue }
            result.insert(String(key.dropFirst(Self.bookmarksPrefix.count)))
        }
        return result
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

    func clearCachedChapters(bookId: String) {
        userDefaults.removeObject(forKey: Self.chaptersPrefix + bookId)
    }
}
