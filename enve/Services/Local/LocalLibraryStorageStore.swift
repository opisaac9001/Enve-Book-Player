import Foundation
import Logging

struct MergeLibraryCache: Codable {
    let lastDedupDate: Date
    let bookStableIds: Set<String>
    let bookCount: Int
}

@MainActor
final class LocalLibraryStorageStore {
    nonisolated static let shared = LocalLibraryStorageStore()

    private static let librariesKey = "localLibraries"
    private static let booksPrefix = "localLibraryBooks_"
    nonisolated private static let bookmarkPrefix = "libraryBookmark_"
    private static let mergeCacheKey = "mergeLibraryCache"

    private let userDefaults = UserDefaults.standard

    nonisolated private init() {}

    func saveLibrary(_ library: LocalLibrary) {
        var libraries = loadLibraries()
        if let index = libraries.firstIndex(where: { $0.id == library.id }) {
            libraries[index] = library
        } else {
            libraries.append(library)
        }
        persist(libraries: libraries)
        AppLogger.network.info("Saved local library: \(library.name)")
    }

    func loadLibraries() -> [LocalLibrary] {
        decode([LocalLibrary].self, forKey: Self.librariesKey) ?? []
    }

    func deleteLibrary(id: String) {
        var libraries = loadLibraries()
        libraries.removeAll { $0.id == id }
        persist(libraries: libraries)
        AppLogger.network.info("Deleted local library: \(id)")
    }

    func updateLibraryScanDate(id: String) {
        var libraries = loadLibraries()
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        var updated = libraries[index]
        updated.lastScanned = Date()
        libraries[index] = updated
        persist(libraries: libraries)
    }

    func saveScanResult(_ result: LocalLibraryScanResult) {
        let key = Self.booksPrefix + result.localLibraryId
        encode(result.booksFound, forKey: key)
        updateLibraryScanDate(id: result.localLibraryId)
        AppLogger.network.info("Saved \(result.booksFound.count) books from library scan")
    }

    func loadBooks(libraryId: String) -> [LocalBookFile] {
        let key = Self.booksPrefix + libraryId
        let books = decode([LocalBookFile].self, forKey: key) ?? []

        let serverRoot = LocalEbookImporter.shared.serverEbooksRoot.standardizedFileURL.path
        let localRoot = LocalEbookImporter.shared.localEbooksRoot.standardizedFileURL.path
        let filtered = books.filter { book in
            let path = book.filePath
            if path.hasPrefix(serverRoot) && !path.hasPrefix(localRoot) { return false }
            return true
        }
        if filtered.count != books.count {
            AppLogger.network.info("Filtered \(books.count - filtered.count) stale server-cached ebook(s) from persisted scan cache")
        }
        return filtered
    }

    func deleteBooks(libraryId: String) {
        userDefaults.removeObject(forKey: Self.booksPrefix + libraryId)
    }

    nonisolated func saveBookmark(_ bookmark: Data, for libraryId: String) {
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkPrefix + libraryId)
        AppLogger.network.info("Saved bookmark for library: \(libraryId)")
    }

    nonisolated func loadBookmark(for libraryId: String) -> Data? {
        UserDefaults.standard.data(forKey: Self.bookmarkPrefix + libraryId)
    }

    nonisolated func deleteBookmark(for libraryId: String) {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkPrefix + libraryId)
    }

    func saveMergeCache(bookStableIds: Set<String>) {
        let cache = MergeLibraryCache(
            lastDedupDate: Date(),
            bookStableIds: bookStableIds,
            bookCount: bookStableIds.count
        )
        encode(cache, forKey: Self.mergeCacheKey)
        AppLogger.network.info("Saved merge library cache: \(cache.bookCount) books")
    }

    func loadMergeCache() -> MergeLibraryCache? {
        decode(MergeLibraryCache.self, forKey: Self.mergeCacheKey)
    }

    func clearMergeCache() {
        userDefaults.removeObject(forKey: Self.mergeCacheKey)
        AppLogger.network.info("Cleared merge library cache")
    }

    private func persist(libraries: [LocalLibrary]) {
        encode(libraries, forKey: Self.librariesKey)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = userDefaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(type, from: data)
        else {
            return nil
        }
        return decoded
    }
}
