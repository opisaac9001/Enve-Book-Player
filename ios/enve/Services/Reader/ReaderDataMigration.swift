import Foundation
import Logging

struct ReaderDataMigration {

    private static let migrationVersionKey = "enve.reader.migrationVersion"
    private static let currentMigrationVersion = 3

    private static let adoptedOrphanKeysKey = "enve.reader.adoptedOrphanBookmarkKeys"

    static func runIfNeeded() {
        let currentVersion = UserDefaults.standard.integer(forKey: migrationVersionKey)
        guard currentVersion < currentMigrationVersion else { return }

        AppLogger.network.info("Running reader data migration from v\(currentVersion) to v\(currentMigrationVersion)")

        if currentVersion < 1 {
            migrateV0ToV1()
        }
        if currentVersion < 2 {
            migrateV1ToV2()
        }
        if currentVersion < 3 {
            migrateV2ToV3()
        }

        UserDefaults.standard.set(currentMigrationVersion, forKey: migrationVersionKey)
        AppLogger.network.info("Reader data migration complete")
    }

    private static func migrateV0ToV1() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        for key in allKeys where key.hasPrefix("bookmarks_") {
            guard let data = defaults.data(forKey: key) else { continue }
            var bookmarks: [Bookmark]
            do {
                bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
            } catch {
                AppLogger.network.warning("Migration v0→v1: failed to decode \(key): \(error.localizedDescription)")
                continue
            }

            var changed = false
            for i in bookmarks.indices {
                if bookmarks[i].locator != nil && bookmarks[i].mediaType == .audiobook {
                    bookmarks[i] = Bookmark(
                        id: bookmarks[i].id,
                        bookId: bookmarks[i].bookId,
                        position: bookmarks[i].position,
                        title: bookmarks[i].title,
                        note: bookmarks[i].note,
                        timestamp: bookmarks[i].timestamp,
                        locator: bookmarks[i].locator,
                        mediaType: .ebook,
                        chapterTitle: bookmarks[i].chapterTitle ?? bookmarks[i].title,
                        remoteID: bookmarks[i].remoteID,
                        isRemotePlaceholder: bookmarks[i].isRemotePlaceholder
                    )
                    changed = true
                }
            }

            if changed, let encoded = try? JSONEncoder().encode(bookmarks) {
                defaults.set(encoded, forKey: key)
            }
        }
    }

    private static func migrateV1ToV2() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        for key in allKeys where key.hasPrefix("readerAnnotations_") {
            guard let data = defaults.data(forKey: key) else { continue }
            let annotations: [ReaderAnnotation]
            do {
                annotations = try JSONDecoder().decode([ReaderAnnotation].self, from: data)
            } catch {
                AppLogger.network.warning("Migration v1→v2: failed to decode \(key): \(error.localizedDescription)")
                continue
            }

            if let encoded = try? JSONEncoder().encode(annotations) {
                defaults.set(encoded, forKey: key)
            }
        }

        #if os(iOS)
        let oldKeys = ["enve.reader.appearance", "enve.reader.appearance.v2"]
        for oldKey in oldKeys {
            if let data = defaults.data(forKey: oldKey) {
                if defaults.data(forKey: "enve.reader.appearance.v3") == nil {
                    if let decoded = try? JSONDecoder().decode(ReaderAppearance.self, from: data) {
                        if let newData = try? JSONEncoder().encode(decoded) {
                            defaults.set(newData, forKey: "enve.reader.appearance.v3")
                        }
                    }
                }
                defaults.removeObject(forKey: oldKey)
            }
        }
        #endif
    }

    private static func migrateV2ToV3() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        for key in allKeys where key.hasPrefix("readerAnnotations_") {
            guard let data = defaults.data(forKey: key) else { continue }
            let annotations: [ReaderAnnotation]
            do {
                annotations = try JSONDecoder().decode([ReaderAnnotation].self, from: data)
            } catch {
                AppLogger.network.warning("Migration v2→v3: failed to decode \(key): \(error.localizedDescription)")
                continue
            }
            if let encoded = try? JSONEncoder().encode(annotations) {
                defaults.set(encoded, forKey: key)
            }

            let bookId = String(key.dropFirst("readerAnnotations_".count))
            for annotation in annotations where annotation.remoteID == nil {
                AnnotationSyncService.shared.enqueue(
                    .createAnnotation(bookId: bookId, annotationId: annotation.id)
                )
            }
        }

        for key in allKeys where key.hasPrefix("bookmarks_") {
            guard let data = defaults.data(forKey: key) else { continue }
            let bookmarks: [Bookmark]
            do {
                bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
            } catch {
                AppLogger.network.warning("Migration v2→v3: failed to decode \(key): \(error.localizedDescription)")
                continue
            }
            let bookId = String(key.dropFirst("bookmarks_".count))
            for bookmark in bookmarks where bookmark.remoteID == nil {
                AnnotationSyncService.shared.enqueue(
                    .createBookmark(bookId: bookId, bookmarkId: bookmark.id)
                )
            }
        }
    }

    static func recoverOrphanedFileShareBookmarks(for book: Book, knownBookIds: Set<String>) {
        guard book.source == .local else { return }
        guard book.id.hasPrefix("file-sharing:") else { return }

        let defaults = UserDefaults.standard

        var adopted = defaults.stringArray(forKey: adoptedOrphanKeysKey) ?? []
        guard !adopted.contains(book.id) else { return }

        let bookDuration = book.duration ?? .infinity
        let claimedKeys = Set(knownBookIds.map { "bookmarks_\($0)" })
        let allKeys = defaults.dictionaryRepresentation().keys

        var orphanedBookmarks: [Bookmark] = []
        var scannedOrphanKeys: [String] = []

        for key in allKeys where key.hasPrefix("bookmarks_file-sharing:") {
            guard !claimedKeys.contains(key) else { continue }
            guard let data = defaults.data(forKey: key),
                let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data)
            else { continue }
            orphanedBookmarks.append(contentsOf: bookmarks)
            scannedOrphanKeys.append(key)
        }

        guard !orphanedBookmarks.isEmpty else {
            adopted.append(book.id)
            defaults.set(adopted, forKey: adoptedOrphanKeysKey)
            return
        }

        let existing = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.id)
        let existingIds = Set(existing.map { $0.id })
        let toAdopt = orphanedBookmarks.filter { bm in
            !existingIds.contains(bm.id) && bm.position >= 0 && bm.position <= bookDuration
        }

        if !toAdopt.isEmpty {
            let merged =
                existing
                + toAdopt.map { bm in

                    Bookmark(
                        id: bm.id,
                        bookId: book.id,
                        position: bm.position,
                        title: bm.title,
                        note: bm.note,
                        timestamp: bm.timestamp,
                        locator: bm.locator,
                        mediaType: bm.mediaType,
                        chapterTitle: bm.chapterTitle,
                        remoteID: bm.remoteID,
                        isRemotePlaceholder: bm.isRemotePlaceholder
                    )
                }
            ReaderArtifactsStore.shared.saveBookmarks(bookId: book.id, bookmarks: merged)
            AppLogger.network.debug(
                "Recovered \(toAdopt.count) orphaned bookmark(s) bookId=\(DiagnosticLogSanitizer.identifier(for: book.id))"
            )
        }

        adopted.append(book.id)
        defaults.set(adopted, forKey: adoptedOrphanKeysKey)
    }

    static func importFromBackupPlist(at url: URL) -> (annotations: Int, bookmarks: Int) {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            AppLogger.network.warning(
                "Could not read backup plist pathId=\(DiagnosticLogSanitizer.identifier(for: url.standardizedFileURL.path))"
            )
            return (0, 0)
        }

        var annotationCount = 0
        var bookmarkCount = 0

        for (key, value) in dict {
            if key.hasPrefix("readerAnnotations_"), let data = value as? Data {
                let bookId = String(key.dropFirst("readerAnnotations_".count))
                if let imported = try? JSONDecoder().decode([ReaderAnnotation].self, from: data) {
                    var existing = ReaderArtifactsStore.shared.loadAnnotations(bookId: bookId)
                    let existingIds = Set(existing.map { $0.id })
                    let newAnnotations = imported.filter { !existingIds.contains($0.id) }
                    existing.append(contentsOf: newAnnotations)
                    ReaderArtifactsStore.shared.saveAnnotations(bookId: bookId, annotations: existing)
                    annotationCount += newAnnotations.count
                }
            } else if key.hasPrefix("bookmarks_"), let data = value as? Data {
                let bookId = String(key.dropFirst("bookmarks_".count))
                if let imported = try? JSONDecoder().decode([Bookmark].self, from: data) {
                    var existing = ReaderArtifactsStore.shared.loadBookmarks(bookId: bookId)
                    let existingIds = Set(existing.map { $0.id })
                    let newBookmarks = imported.filter { !existingIds.contains($0.id) }
                    existing.append(contentsOf: newBookmarks)
                    ReaderArtifactsStore.shared.saveBookmarks(bookId: bookId, bookmarks: existing)
                    bookmarkCount += newBookmarks.count
                }
            }
        }

        AppLogger.network.info("Imported \(annotationCount) annotations and \(bookmarkCount) bookmarks from backup")
        return (annotationCount, bookmarkCount)
    }

    @discardableResult
    static func repairDataIntegrity() -> Int {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        var repairedCount = 0

        for key in allKeys {
            if key.hasPrefix("readerAnnotations_") {
                if let data = defaults.data(forKey: key) {
                    if (try? JSONDecoder().decode([ReaderAnnotation].self, from: data)) == nil {
                        defaults.removeObject(forKey: key)
                        repairedCount += 1
                        AppLogger.network.info("Removed corrupted annotation data for key: \(key)")
                    }
                }
            } else if key.hasPrefix("bookmarks_") {
                if let data = defaults.data(forKey: key) {
                    if (try? JSONDecoder().decode([Bookmark].self, from: data)) == nil {
                        defaults.removeObject(forKey: key)
                        repairedCount += 1
                        AppLogger.network.info("Removed corrupted bookmark data for key: \(key)")
                    }
                }
            }
        }

        return repairedCount
    }
}
