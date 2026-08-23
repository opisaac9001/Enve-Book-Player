import Combine
import Foundation
import Logging

@MainActor
@Observable
final class AnnotationSyncService {
    static let shared = AnnotationSyncService()

    var isSyncing = false
    var lastSyncDate: Date?

    private static let pendingQueueKey = "enve.annotationSync.pendingQueue"
    private static let lastSyncKey = "enve.annotationSync.lastSync"

    enum SyncOperation: Codable, Equatable {
        case createAnnotation(bookId: String, annotationId: String)
        case updateAnnotation(bookId: String, annotationId: String)
        case deleteAnnotation(remoteId: Int)
        case createBookmark(bookId: String, bookmarkId: String)
        case deleteBookmark(remoteId: Int)
        case createBookNote(bookId: String, annotationId: String)
    }

    private var pendingQueue: [SyncOperation] = []

    private init() {
        loadPendingQueue()
        if let ts = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date {
            lastSyncDate = ts
        }
    }

    func enqueue(_ op: SyncOperation) {
        pendingQueue.removeAll { $0 == op }
        pendingQueue.append(op)
        savePendingQueue()
    }

    private func loadPendingQueue() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingQueueKey),
            let queue = try? JSONDecoder().decode([SyncOperation].self, from: data)
        else {
            pendingQueue = []
            return
        }
        pendingQueue = queue
    }

    private func savePendingQueue() {
        if let data = try? JSONEncoder().encode(pendingQueue) {
            UserDefaults.standard.set(data, forKey: Self.pendingQueueKey)
        }
    }

    func flushPending(for book: Book) async {
        guard !isSyncing else { return }
        guard let provider = AppState.shared.getProvider(book.providerId) as? BookloreProvider else { return }
        isSyncing = true
        defer { isSyncing = false }
        await pushPendingOperations(for: book, provider: provider)
    }

    func flushAllPending(books: [Book]) async {
        guard !pendingQueue.isEmpty else { return }

        let bookIds: Set<String> = Set(
            pendingQueue.compactMap { op -> String? in
                switch op {
                case .createAnnotation(let bookId, _),
                    .updateAnnotation(let bookId, _),
                    .createBookmark(let bookId, _),
                    .createBookNote(let bookId, _):
                    return bookId
                case .deleteAnnotation, .deleteBookmark:
                    return nil
                }
            }
        )

        for bookId in bookIds {
            guard let book = books.first(where: { $0.stableId == bookId }) else { continue }
            await flushPending(for: book)
        }
    }

    func syncAnnotations(for book: Book) async {
        guard let provider = AppState.shared.getProvider(book.providerId) as? BookloreProvider else {
            AppLogger.sync.info(
                "Annotation sync skipped for '\(book.title)' - provider does not support annotation sync (Booklore/Grimmory only)"
            )
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: Self.lastSyncKey)
        }

        do {

            await pushPendingOperations(for: book, provider: provider)

            async let remoteAnnotationsTask = provider.fetchRemoteAnnotations(for: book)
            async let remoteBookmarksTask = provider.fetchRemoteBookmarks(for: book)
            async let remoteBookNotesTask = provider.fetchBookNotes(for: book)

            let remoteAnnotations = try await remoteAnnotationsTask
            let remoteBookmarks = try await remoteBookmarksTask
            let remoteBookNotes = try await remoteBookNotesTask

            var localAnnotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
            var localBookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)

            let remoteAnnotationIds = Set(remoteAnnotations.map { $0.id })
            for record in remoteAnnotations {
                mergeRemoteAnnotationRecord(record, into: &localAnnotations, bookId: book.stableId)
            }

            for noteRecord in remoteBookNotes {
                mergeRemoteBookNote(noteRecord, into: &localAnnotations, bookId: book.stableId)
            }

            let remoteBookmarkIds = Set(remoteBookmarks.map { $0.id })
            for record in remoteBookmarks {
                mergeRemoteBookmarkRecord(record, into: &localBookmarks, bookId: book.stableId)
            }

            localAnnotations.removeAll { annotation in
                if let remoteID = annotation.remoteID, !remoteAnnotationIds.contains(remoteID) {
                    let isBookNote = remoteBookNotes.contains(where: { $0.id == remoteID })
                    return !isBookNote
                }
                return false
            }

            localBookmarks.removeAll { bookmark in
                if let remoteID = bookmark.remoteID, !remoteBookmarkIds.contains(remoteID) {
                    return true
                }
                return false
            }

            ReaderArtifactsStore.shared.saveAnnotations(bookId: book.stableId, annotations: localAnnotations)
            ReaderArtifactsStore.shared.saveBookmarks(bookId: book.stableId, bookmarks: localBookmarks)

        } catch {
            AppLogger.sync.error("Sync failed: \(error)")
        }
    }

    private func mergeRemoteAnnotationRecord(
        _ record: BookloreProvider.RemoteAnnotationRecord,
        into local: inout [ReaderAnnotation],
        bookId: String
    ) {
        let remoteDate = parseDate(record.updatedAt) ?? parseDate(record.createdAt) ?? Date()

        if let idx = local.firstIndex(where: { $0.remoteID == record.id }) {
            if remoteDate > local[idx].updatedAt {
                let resolvedLocator: String?
                if let serverCFI = record.cfi, !serverCFI.isEmpty {
                    resolvedLocator = buildLocatorJSON(from: serverCFI, existingLocator: local[idx].locator)
                } else {
                    resolvedLocator = local[idx].locator
                }

                local[idx] = ReaderAnnotation(
                    id: local[idx].id,
                    bookId: bookId,
                    locator: resolvedLocator,
                    position: local[idx].position,
                    text: record.text ?? local[idx].text,
                    note: record.note,
                    colorHex: record.color ?? local[idx].colorHex,
                    style: ReaderAnnotationStyle(rawValue: record.style ?? "highlight") ?? .highlight,
                    chapterTitle: record.chapterTitle ?? local[idx].chapterTitle,
                    createdAt: local[idx].createdAt,
                    updatedAt: remoteDate,
                    remoteID: record.id,
                    isRemotePlaceholder: resolvedLocator == nil
                )
            } else if local[idx].isRemotePlaceholder, let serverCFI = record.cfi, !serverCFI.isEmpty {
                local[idx] = ReaderAnnotation(
                    id: local[idx].id,
                    bookId: bookId,
                    locator: buildLocatorJSON(from: serverCFI, existingLocator: nil),
                    position: local[idx].position,
                    text: local[idx].text,
                    note: local[idx].note,
                    colorHex: local[idx].colorHex,
                    style: local[idx].style,
                    chapterTitle: local[idx].chapterTitle ?? record.chapterTitle,
                    createdAt: local[idx].createdAt,
                    updatedAt: local[idx].updatedAt,
                    remoteID: record.id,
                    isRemotePlaceholder: false
                )
            }
        } else {

            if let remoteCFI = record.cfi, !remoteCFI.isEmpty,
                let idx = local.firstIndex(where: { $0.remoteID == nil && extractCFIFromLocator($0.locator) == remoteCFI })
            {
                local[idx] = ReaderAnnotation(
                    id: local[idx].id,
                    bookId: bookId,
                    locator: local[idx].locator ?? buildLocatorJSON(from: record.cfi, existingLocator: nil),
                    position: local[idx].position,
                    text: local[idx].text,
                    note: record.note ?? local[idx].note,
                    colorHex: local[idx].colorHex,
                    style: local[idx].style,
                    chapterTitle: record.chapterTitle ?? local[idx].chapterTitle,
                    createdAt: local[idx].createdAt,
                    updatedAt: max(local[idx].updatedAt, remoteDate),
                    remoteID: record.id,
                    isRemotePlaceholder: false
                )
                return
            }

            let locatorJSON: String?
            if let cfi = record.cfi, !cfi.isEmpty {
                locatorJSON = buildLocatorJSON(from: cfi, existingLocator: nil)
            } else {
                locatorJSON = nil
            }

            let annotation = ReaderAnnotation(
                bookId: bookId,
                locator: locatorJSON,
                position: 0,
                text: record.text ?? "",
                note: record.note,
                colorHex: record.color ?? "#FFF59D",
                style: ReaderAnnotationStyle(rawValue: record.style ?? "highlight") ?? .highlight,
                chapterTitle: record.chapterTitle,
                createdAt: parseDate(record.createdAt) ?? Date(),
                updatedAt: remoteDate,
                remoteID: record.id,
                isRemotePlaceholder: locatorJSON == nil
            )
            local.append(annotation)
        }
    }

    private func mergeRemoteBookNote(_ record: BookloreProvider.RemoteBookNoteRecord, into local: inout [ReaderAnnotation], bookId: String)
    {
        let syntheticRemoteID = record.id + 1_000_000

        if local.contains(where: { $0.remoteID == syntheticRemoteID }) {
            return
        }

        let locatorJSON: String?
        if let cfi = record.cfi, !cfi.isEmpty {
            locatorJSON = buildLocatorJSON(from: cfi, existingLocator: nil)
        } else {
            locatorJSON = nil
        }

        let annotation = ReaderAnnotation(
            bookId: bookId,
            locator: locatorJSON,
            position: 0,
            text: record.selectedText ?? "",
            note: record.noteContent,
            colorHex: record.color ?? "#00FF00",
            style: .highlight,
            chapterTitle: record.chapterTitle,
            createdAt: parseDate(record.createdAt) ?? Date(),
            updatedAt: parseDate(record.updatedAt) ?? Date(),
            remoteID: syntheticRemoteID,
            isRemotePlaceholder: locatorJSON == nil
        )
        local.append(annotation)
    }

    private func mergeRemoteBookmarkRecord(_ record: BookloreProvider.RemoteBookmarkRecord, into local: inout [Bookmark], bookId: String) {
        let remoteDate = parseDate(record.updatedAt) ?? parseDate(record.createdAt) ?? Date()

        if let idx = local.firstIndex(where: { $0.remoteID == record.id }) {
            if remoteDate > local[idx].timestamp || (local[idx].isRemotePlaceholder && record.cfi != nil) {
                let resolvedLocator: String?
                if let serverCFI = record.cfi, !serverCFI.isEmpty {
                    resolvedLocator = buildLocatorJSON(from: serverCFI, existingLocator: local[idx].locator)
                } else {
                    resolvedLocator = local[idx].locator
                }

                local[idx] = Bookmark(
                    id: local[idx].id,
                    bookId: bookId,
                    position: local[idx].position,
                    title: record.title ?? local[idx].title,
                    note: record.notes ?? local[idx].note,
                    timestamp: max(local[idx].timestamp, remoteDate),
                    locator: resolvedLocator,
                    mediaType: record.positionMs != nil ? .audiobook : .ebook,
                    chapterTitle: local[idx].chapterTitle,
                    remoteID: record.id,
                    isRemotePlaceholder: resolvedLocator == nil
                )
            }
            return
        }

        let locatorJSON: String?
        if let cfi = record.cfi, !cfi.isEmpty {
            locatorJSON = buildLocatorJSON(from: cfi, existingLocator: nil)
        } else {
            locatorJSON = nil
        }

        let mediaType: AppMediaType = record.positionMs != nil ? .audiobook : .ebook
        let position: TimeInterval
        if let ms = record.positionMs {
            position = ms / 1000.0
        } else {
            position = 0
        }

        let bookmark = Bookmark(
            bookId: bookId,
            position: position,
            title: record.title ?? "Synced Bookmark",
            note: record.notes,
            timestamp: remoteDate,
            locator: locatorJSON,
            mediaType: mediaType,
            chapterTitle: nil,
            remoteID: record.id,
            isRemotePlaceholder: locatorJSON == nil && record.positionMs == nil
        )
        local.append(bookmark)
    }

    private func pushPendingOperations(for book: Book, provider: BookloreProvider) async {
        var remaining: [SyncOperation] = []

        for op in pendingQueue {
            do {
                switch op {
                case .createAnnotation(let bookId, let annotationId):
                    guard bookId == book.stableId else { remaining.append(op); continue }
                    let annotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: bookId)
                    guard let annotation = annotations.first(where: { $0.id == annotationId }) else { continue }
                    guard annotation.remoteID == nil else { continue }
                    let record: BookloreProvider.RemoteAnnotationRecord
                    do {
                        record = try await provider.createRemoteAnnotation(for: book, annotation: annotation)
                    } catch ProviderError.noCFI {
                        continue
                    }
                    var updated = annotations
                    if let idx = updated.firstIndex(where: { $0.id == annotationId }) {
                        updated[idx] = ReaderAnnotation(
                            id: updated[idx].id,
                            bookId: bookId,
                            locator: updated[idx].locator,
                            position: updated[idx].position,
                            text: updated[idx].text,
                            note: updated[idx].note,
                            colorHex: updated[idx].colorHex,
                            style: updated[idx].style,
                            chapterTitle: updated[idx].chapterTitle,
                            createdAt: updated[idx].createdAt,
                            updatedAt: updated[idx].updatedAt,
                            remoteID: record.id,
                            isRemotePlaceholder: false
                        )
                        ReaderArtifactsStore.shared.saveAnnotations(bookId: bookId, annotations: updated)
                    }

                case .updateAnnotation(let bookId, let annotationId):
                    guard bookId == book.stableId else { remaining.append(op); continue }
                    let annotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: bookId)
                    guard let annotation = annotations.first(where: { $0.id == annotationId }),
                        let remoteId = annotation.remoteID
                    else { continue }
                    _ = try await provider.updateRemoteAnnotation(id: remoteId, annotation: annotation)

                case .deleteAnnotation(let remoteId):
                    try await provider.deleteRemoteAnnotation(id: remoteId)

                case .createBookmark(let bookId, let bookmarkId):
                    guard bookId == book.stableId else { remaining.append(op); continue }
                    let bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: bookId)
                    guard let bookmark = bookmarks.first(where: { $0.id == bookmarkId }) else { continue }
                    guard bookmark.remoteID == nil else { continue }
                    let posMs: Int? = bookmark.mediaType == .audiobook ? Int(bookmark.position * 1000) : nil
                    let record = try await provider.createRemoteBookmark(
                        for: book,
                        title: bookmark.title,
                        note: bookmark.note,
                        locator: bookmark.locator,
                        positionMs: posMs
                    )
                    var updated = bookmarks
                    if let idx = updated.firstIndex(where: { $0.id == bookmarkId }) {
                        updated[idx] = Bookmark(
                            id: updated[idx].id,
                            bookId: bookId,
                            position: updated[idx].position,
                            title: updated[idx].title,
                            note: updated[idx].note,
                            timestamp: updated[idx].timestamp,
                            locator: updated[idx].locator,
                            mediaType: updated[idx].mediaType,
                            chapterTitle: updated[idx].chapterTitle,
                            remoteID: record.id,
                            isRemotePlaceholder: false
                        )
                        ReaderArtifactsStore.shared.saveBookmarks(bookId: bookId, bookmarks: updated)
                    }

                case .deleteBookmark(let remoteId):
                    try await provider.deleteRemoteBookmark(id: remoteId)

                case .createBookNote(let bookId, let annotationId):
                    guard bookId == book.stableId else { remaining.append(op); continue }
                    let annotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: bookId)
                    guard let annotation = annotations.first(where: { $0.id == annotationId }),
                        let noteContent = annotation.note, !noteContent.isEmpty
                    else { continue }
                    guard let cfi = extractCFIFromLocator(annotation.locator) else {

                        AppLogger.sync.info(
                            "Skipping Grimmory book-note push for annotation \(annotationId): no CFI derivable, keeping local only"
                        )
                        continue
                    }
                    _ = try await provider.createBookNote(
                        for: book,
                        cfi: cfi,
                        selectedText: annotation.text,
                        noteContent: noteContent,
                        color: annotation.colorHex,
                        chapterTitle: annotation.chapterTitle
                    )
                }
            } catch {
                AppLogger.sync.error("Failed to push operation: \(error)")
                remaining.append(op)
            }
        }

        pendingQueue = remaining
        savePendingQueue()
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    private func buildLocatorJSON(from cfi: String?, existingLocator: String?) -> String? {
        guard let cfi, !cfi.isEmpty else { return existingLocator }

        if let existing = existingLocator,
            let data = existing.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var locations = json["locations"] as? [String: Any] ?? [:]
            locations["cfi"] = cfi
            if let fragments = locations["fragments"] as? [String] {
                let htmlFragments = fragments.filter {
                    EpubLocationBridge.normalizedEPUBCFI($0) == nil
                }
                if htmlFragments.isEmpty {
                    locations.removeValue(forKey: "fragments")
                } else {
                    locations["fragments"] = htmlFragments
                }
            }
            locations[EpubLocationBridge.sourceEngineLocationKey] = ReaderEngineKind.foliate.rawValue
            json["locations"] = locations
            if let newData = try? JSONSerialization.data(withJSONObject: json),
                let newStr = String(data: newData, encoding: .utf8)
            {
                return newStr
            }
        }

        let locator: [String: Any] = [
            "href": "",
            "type": "application/xhtml+xml",
            "locations": [
                "cfi": cfi,
                EpubLocationBridge.sourceEngineLocationKey: ReaderEngineKind.foliate.rawValue,
            ],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: locator),
            let str = String(data: data, encoding: .utf8)
        {
            return str
        }

        return existingLocator
    }

    private func extractCFIFromLocator(_ locator: String?) -> String? {
        guard let locator, !locator.isEmpty else { return nil }
        if locator.hasPrefix("epubcfi(") { return locator }

        guard let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = json["locations"] as? [String: Any]
        else {
            return nil
        }

        if let fragments = locations["fragments"] as? [String],
            let cfi = fragments.first(where: { $0.hasPrefix("epubcfi(") })
        {
            return cfi
        }
        if let cfi = locations["cfi"] as? String, cfi.hasPrefix("epubcfi(") {
            return cfi
        }
        return nil
    }
}
