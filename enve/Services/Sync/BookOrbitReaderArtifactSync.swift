import Foundation
import Logging

@MainActor
final class BookOrbitReaderArtifactSync {
    static let shared = BookOrbitReaderArtifactSync()

    struct Result {
        let pulled: Int
        let pushed: Int
    }

    private enum Operation: Codable, Equatable {
        case upsertBookmark(connectionId: UUID, bookId: String, localId: String)
        case deleteBookmark(connectionId: UUID, bookId: String, remoteId: Int)
        case upsertAnnotation(connectionId: UUID, bookId: String, localId: String)
        case deleteAnnotation(connectionId: UUID, bookId: String, remoteId: Int)

        var connectionId: UUID {
            switch self {
            case .upsertBookmark(let value, _, _), .deleteBookmark(let value, _, _),
                .upsertAnnotation(let value, _, _), .deleteAnnotation(let value, _, _):
                value
            }
        }

        var bookId: String {
            switch self {
            case .upsertBookmark(_, let value, _), .deleteBookmark(_, let value, _),
                .upsertAnnotation(_, let value, _), .deleteAnnotation(_, let value, _):
                value
            }
        }
    }

    private static let storageKey = "enve.bookorbit.readerArtifacts.pending.v1"
    private var pending: [Operation]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([Operation].self, from: data)
        else {
            pending = []
            return
        }
        pending = decoded
    }

    func enqueueBookmarkUpsert(book: Book, localId: String) {
        enqueue(.upsertBookmark(connectionId: book.providerId, bookId: book.stableId, localId: localId))
    }

    func enqueueBookmarkDelete(book: Book, remoteId: Int) {
        enqueue(.deleteBookmark(connectionId: book.providerId, bookId: book.stableId, remoteId: remoteId))
    }

    func enqueueAnnotationUpsert(book: Book, localId: String) {
        enqueue(.upsertAnnotation(connectionId: book.providerId, bookId: book.stableId, localId: localId))
    }

    func enqueueAnnotationDelete(book: Book, remoteId: Int) {
        enqueue(.deleteAnnotation(connectionId: book.providerId, bookId: book.stableId, remoteId: remoteId))
    }

    func pendingBookIds(providerId: UUID) -> Set<String> {
        Set(pending.filter { $0.connectionId == providerId }.map(\.bookId))
    }

    func sync(book: Book, provider: BookOrbitProvider) async -> Result {
        let pushed = await flush(book: book, provider: provider)
        guard !pending.contains(where: { $0.connectionId == provider.connection.id && $0.bookId == book.stableId }) else {
            return Result(pulled: 0, pushed: pushed)
        }

        do {
            async let remoteBookmarksTask = provider.fetchReaderBookmarks(for: book)
            async let remoteAnnotationsTask = provider.fetchReaderAnnotations(for: book)
            let (remoteBookmarks, remoteAnnotations) = try await (remoteBookmarksTask, remoteAnnotationsTask)
            let pulled = await merge(
                book: book,
                remoteBookmarks: remoteBookmarks,
                remoteAnnotations: remoteAnnotations
            )
            return Result(pulled: pulled, pushed: pushed)
        } catch is CancellationError {
            return Result(pulled: 0, pushed: pushed)
        } catch {
            AppLogger.sync.error(
                "[BookOrbit] Reader-artifact pull failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
            )
            return Result(pulled: 0, pushed: pushed)
        }
    }

    private func enqueue(_ operation: Operation) {
        pending.removeAll { $0 == operation }
        pending.append(operation)
        persist()
    }

    private func flush(book: Book, provider: BookOrbitProvider) async -> Int {
        var remaining: [Operation] = []
        var pushed = 0

        for operation in pending {
            guard operation.connectionId == provider.connection.id, operation.bookId == book.stableId else {
                remaining.append(operation)
                continue
            }
            do {
                switch operation {
                case .upsertBookmark(_, _, let localId):
                    var bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
                    guard let index = bookmarks.firstIndex(where: { $0.id == localId }) else { continue }
                    let bookmark = bookmarks[index]
                    let record: BookOrbitProvider.ReaderBookmarkRecord
                    if let remoteId = bookmark.remoteID {
                        record = try await provider.replaceReaderBookmark(for: book, bookmark: bookmark, remoteId: remoteId)
                    } else {
                        record = try await provider.createReaderBookmark(for: book, bookmark: bookmark)
                    }
                    bookmarks[index] = bookmarkWithRemoteId(bookmark, remoteId: record.id)
                    await persist(bookmarks: bookmarks, book: book)

                case .deleteBookmark(_, _, let remoteId):
                    try await provider.deleteReaderBookmark(for: book, remoteId: remoteId)

                case .upsertAnnotation(_, _, let localId):
                    var annotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
                    guard let index = annotations.firstIndex(where: { $0.id == localId }) else { continue }
                    var annotation = annotations[index]
                    let record: BookOrbitProvider.ReaderAnnotationRecord
                    if let remoteId = annotation.remoteID {
                        record = try await provider.updateReaderAnnotation(for: book, annotation: annotation, remoteId: remoteId)
                    } else {
                        record = try await provider.createReaderAnnotation(for: book, annotation: annotation)
                    }
                    annotation.remoteID = record.id
                    annotation.isRemotePlaceholder = false
                    annotations[index] = annotation
                    await persist(annotations: annotations, book: book)

                case .deleteAnnotation(_, _, let remoteId):
                    try await provider.deleteReaderAnnotation(for: book, remoteId: remoteId)
                }
                pushed += 1
            } catch ProviderError.noCFI {
                continue
            } catch is CancellationError {
                remaining.append(operation)
            } catch {
                AppLogger.sync.error(
                    "[BookOrbit] Reader-artifact push failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
                remaining.append(operation)
            }
        }
        pending = remaining
        persist()
        return pushed
    }

    private func merge(
        book: Book,
        remoteBookmarks: [BookOrbitProvider.ReaderBookmarkRecord],
        remoteAnnotations: [BookOrbitProvider.ReaderAnnotationRecord]
    ) async -> Int {
        var bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
        var annotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
        let previousBookmarkIds = Set(bookmarks.compactMap(\.remoteID))
        let previousAnnotationIds = Set(annotations.compactMap(\.remoteID))
        let remoteBookmarkIds = Set(remoteBookmarks.map(\.id))
        let remoteAnnotationIds = Set(remoteAnnotations.map(\.id))

        bookmarks.removeAll { $0.remoteID.map { !remoteBookmarkIds.contains($0) } ?? false }
        annotations.removeAll { $0.remoteID.map { !remoteAnnotationIds.contains($0) } ?? false }

        for record in remoteBookmarks {
            let recordCFI = record.cfi
            let index = bookmarks.firstIndex(where: { $0.remoteID == record.id })
                ?? bookmarks.firstIndex(where: { bookmark in
                    guard bookmark.remoteID == nil else { return false }
                    if let recordCFI { return Self.extractCFI(from: bookmark.locator) == recordCFI }
                    guard let seconds = record.positionSeconds else { return false }
                    return bookmark.mediaType == .audiobook && abs(bookmark.position - seconds) < 0.5
                })
            let locator = Self.locator(from: record.cfi, existing: index.map { bookmarks[$0].locator } ?? nil)
            if let index {
                let existing = bookmarks[index]
                bookmarks[index] = Bookmark(
                    id: existing.id,
                    bookId: book.stableId,
                    position: record.positionSeconds ?? existing.position,
                    title: record.title,
                    note: existing.note,
                    timestamp: record.createdAt,
                    locator: locator,
                    mediaType: record.positionSeconds == nil ? .ebook : .audiobook,
                    chapterTitle: existing.chapterTitle,
                    remoteID: record.id,
                    isRemotePlaceholder: locator == nil && record.positionSeconds == nil
                )
            } else {
                bookmarks.append(
                    Bookmark(
                        bookId: book.stableId,
                        position: record.positionSeconds ?? 0,
                        title: record.title,
                        timestamp: record.createdAt,
                        locator: locator,
                        mediaType: record.positionSeconds == nil ? .ebook : .audiobook,
                        remoteID: record.id,
                        isRemotePlaceholder: locator == nil && record.positionSeconds == nil
                    )
                )
            }
        }

        for record in remoteAnnotations {
            let index = annotations.firstIndex(where: { $0.remoteID == record.id })
                ?? annotations.firstIndex(where: {
                    $0.remoteID == nil && Self.extractCFI(from: $0.locator) == record.cfi
                })
            let locator = Self.locator(from: record.cfi, existing: index.map { annotations[$0].locator } ?? nil)
            if let index {
                let existing = annotations[index]
                annotations[index] = ReaderAnnotation(
                    id: existing.id,
                    bookId: book.stableId,
                    locator: locator,
                    position: existing.position,
                    text: record.text,
                    note: record.note,
                    colorHex: record.color,
                    style: ReaderAnnotationStyle(rawValue: record.style) ?? .highlight,
                    chapterTitle: record.chapterTitle,
                    createdAt: record.createdAt,
                    updatedAt: max(existing.updatedAt, record.createdAt),
                    remoteID: record.id,
                    isRemotePlaceholder: locator == nil
                )
            } else {
                annotations.append(
                    ReaderAnnotation(
                        bookId: book.stableId,
                        locator: locator,
                        text: record.text,
                        note: record.note,
                        colorHex: record.color,
                        style: ReaderAnnotationStyle(rawValue: record.style) ?? .highlight,
                        chapterTitle: record.chapterTitle,
                        createdAt: record.createdAt,
                        updatedAt: record.createdAt,
                        remoteID: record.id,
                        isRemotePlaceholder: locator == nil
                    )
                )
            }
        }

        await persist(bookmarks: bookmarks, book: book)
        await persist(annotations: annotations, book: book)
        return previousBookmarkIds.symmetricDifference(remoteBookmarkIds).count
            + previousAnnotationIds.symmetricDifference(remoteAnnotationIds).count
    }

    private func persist(bookmarks: [Bookmark], book: Book) async {
        ReaderArtifactsStore.shared.saveBookmarks(bookId: book.stableId, bookmarks: bookmarks)
        await AppState.shared.bookStore.replaceBookmarks(forBookStableId: book.stableId, bookmarks: bookmarks)
    }

    private func persist(annotations: [ReaderAnnotation], book: Book) async {
        ReaderArtifactsStore.shared.saveAnnotations(bookId: book.stableId, annotations: annotations)
        await AppState.shared.bookStore.replaceAnnotations(forBookStableId: book.stableId, annotations: annotations)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func bookmarkWithRemoteId(_ bookmark: Bookmark, remoteId: Int) -> Bookmark {
        Bookmark(
            id: bookmark.id,
            bookId: bookmark.bookId,
            position: bookmark.position,
            title: bookmark.title,
            note: bookmark.note,
            timestamp: bookmark.timestamp,
            locator: bookmark.locator,
            mediaType: bookmark.mediaType,
            chapterTitle: bookmark.chapterTitle,
            remoteID: remoteId,
            isRemotePlaceholder: false
        )
    }

    private static func extractCFI(from locator: String?) -> String? {
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

    private static func locator(from cfi: String?, existing: String?) -> String? {
        guard let cfi, !cfi.isEmpty else { return existing }
        if let existing,
            let data = existing.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var locations = json["locations"] as? [String: Any] ?? [:]
            locations["cfi"] = cfi
            locations[EpubLocationBridge.sourceEngineLocationKey] = ReaderEngineKind.foliate.rawValue
            json["locations"] = locations
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                return String(data: data, encoding: .utf8)
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
        guard let data = try? JSONSerialization.data(withJSONObject: locator) else { return existing }
        return String(data: data, encoding: .utf8)
    }
}
