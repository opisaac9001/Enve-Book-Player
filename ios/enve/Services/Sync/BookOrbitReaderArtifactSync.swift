import Foundation
import Logging

struct BookOrbitArtifactQueue: Equatable {
    enum Operation: Codable, Equatable {
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

    struct Entry: Codable, Equatable {
        let operation: Operation
        var attempts: Int
        var earliestAttempt: Date

        init(operation: Operation, attempts: Int = 0, earliestAttempt: Date = .distantPast) {
            self.operation = operation
            self.attempts = attempts
            self.earliestAttempt = earliestAttempt
        }
    }

    struct PendingWork: Equatable {
        var bookmarkIds: Set<String> = []
        var annotationIds: Set<String> = []
        var deletedBookmarkRemoteIds: Set<Int> = []
        var deletedAnnotationRemoteIds: Set<Int> = []
    }

    static let maxAttempts = 5
    static let storageKey = "enve.bookorbit.readerArtifacts.pending.v2"
    static let legacyStorageKey = "enve.bookorbit.readerArtifacts.pending.v1"
    private static let firstBackoff: TimeInterval = 300
    private static let backoffCeiling: TimeInterval = 3600

    private(set) var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    static func loaded(from defaults: UserDefaults) -> BookOrbitArtifactQueue {
        if let data = defaults.data(forKey: storageKey),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        {
            return BookOrbitArtifactQueue(entries: entries)
        }
        guard let legacy = defaults.data(forKey: legacyStorageKey),
            let operations = try? JSONDecoder().decode([Operation].self, from: legacy)
        else {
            return BookOrbitArtifactQueue()
        }
        return BookOrbitArtifactQueue(entries: operations.map { Entry(operation: $0) })
    }

    func persist(to defaults: UserDefaults) {
        defaults.removeObject(forKey: Self.legacyStorageKey)
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func backoff(attempts: Int) -> TimeInterval {
        min(firstBackoff * pow(2, Double(max(attempts, 1) - 1)), backoffCeiling)
    }

    mutating func enqueue(_ operation: Operation) {
        entries.removeAll { $0.operation == operation }
        entries.append(Entry(operation: operation))
    }

    mutating func remove(_ operation: Operation) {
        entries.removeAll { $0.operation == operation }
    }

    @discardableResult
    mutating func recordFailure(_ operation: Operation, now: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.operation == operation }) else { return false }
        let attempts = entries[index].attempts + 1
        guard attempts < Self.maxAttempts else {
            entries.remove(at: index)
            return false
        }
        entries[index].attempts = attempts
        entries[index].earliestAttempt = now.addingTimeInterval(Self.backoff(attempts: attempts))
        return true
    }

    func bookIds(connectionId: UUID) -> Set<String> {
        Set(entries.lazy.filter { $0.operation.connectionId == connectionId }.map(\.operation.bookId))
    }

    func dueOperations(connectionId: UUID, bookId: String, now: Date) -> [Operation] {
        entries
            .filter {
                $0.operation.connectionId == connectionId
                    && $0.operation.bookId == bookId
                    && $0.earliestAttempt <= now
            }
            .map(\.operation)
    }

    func pendingWork(connectionId: UUID, bookId: String) -> PendingWork {
        var work = PendingWork()
        for entry in entries
        where entry.operation.connectionId == connectionId && entry.operation.bookId == bookId {
            switch entry.operation {
            case .upsertBookmark(_, _, let localId):
                work.bookmarkIds.insert(localId)
            case .upsertAnnotation(_, _, let localId):
                work.annotationIds.insert(localId)
            case .deleteBookmark(_, _, let remoteId):
                work.deletedBookmarkRemoteIds.insert(remoteId)
            case .deleteAnnotation(_, _, let remoteId):
                work.deletedAnnotationRemoteIds.insert(remoteId)
            }
        }
        return work
    }
}

enum BookOrbitArtifactMerge {
    struct Snapshot: Equatable {
        var bookmarks: [Bookmark]
        var annotations: [ReaderAnnotation]
    }

    static func applying(
        bookmarks remoteBookmarks: [BookOrbitProvider.ReaderBookmarkRecord],
        annotations remoteAnnotations: [BookOrbitProvider.ReaderAnnotationRecord],
        to snapshot: Snapshot,
        bookStableId: String,
        pendingWork: BookOrbitArtifactQueue.PendingWork,
        spineHrefs: [String: String] = [:]
    ) -> Snapshot {
        var bookmarks = snapshot.bookmarks
        var annotations = snapshot.annotations
        let hrefs = hrefsBySpineStep(in: snapshot).merging(spineHrefs) { current, _ in current }
        let remoteBookmarkIds = Set(remoteBookmarks.map(\.id))
        let remoteAnnotationIds = Set(remoteAnnotations.map(\.id))

        // Empty payloads are not sufficient proof of server-side deletion.
        if !remoteBookmarkIds.isEmpty {
            bookmarks.removeAll { bookmark in
                guard let remoteID = bookmark.remoteID, !pendingWork.bookmarkIds.contains(bookmark.id) else {
                    return false
                }
                return !remoteBookmarkIds.contains(remoteID)
            }
        }
        if !remoteAnnotationIds.isEmpty {
            annotations.removeAll { annotation in
                guard let remoteID = annotation.remoteID, !pendingWork.annotationIds.contains(annotation.id) else {
                    return false
                }
                return !remoteAnnotationIds.contains(remoteID)
            }
        }

        for record in remoteBookmarks where !pendingWork.deletedBookmarkRemoteIds.contains(record.id) {
            let recordCFI = EpubLocationBridge.canonicalFullEPUBCFI(record.cfi)
            let index =
                bookmarks.firstIndex(where: { $0.remoteID == record.id })
                ?? bookmarks.firstIndex(where: { bookmark in
                    guard bookmark.remoteID == nil else { return false }
                    if let recordCFI { return canonicalCFI(in: bookmark.locator) == recordCFI }
                    guard let seconds = record.positionSeconds else { return false }
                    return bookmark.mediaType == .audiobook && abs(bookmark.position - seconds) < 0.5
                })
            if let index, pendingWork.bookmarkIds.contains(bookmarks[index].id) { continue }
            let locator = Self.locator(
                fromCFI: record.cfi,
                existing: index.map { bookmarks[$0].locator } ?? nil,
                hrefsBySpineStep: hrefs
            )
            if let index {
                let existing = bookmarks[index]
                bookmarks[index] = Bookmark(
                    id: existing.id,
                    bookId: bookStableId,
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
                        bookId: bookStableId,
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

        for record in remoteAnnotations where !pendingWork.deletedAnnotationRemoteIds.contains(record.id) {
            let recordCFI = EpubLocationBridge.canonicalFullEPUBCFI(record.cfi)
            let index =
                annotations.firstIndex(where: { $0.remoteID == record.id })
                ?? recordCFI.flatMap { cfi in
                    annotations.firstIndex(where: { $0.remoteID == nil && canonicalCFI(in: $0.locator) == cfi })
                }
            if let index, pendingWork.annotationIds.contains(annotations[index].id) { continue }
            let locator = Self.locator(
                fromCFI: record.cfi,
                existing: index.map { annotations[$0].locator } ?? nil,
                hrefsBySpineStep: hrefs,
                highlightedText: record.text
            )
            if let index {
                let existing = annotations[index]
                annotations[index] = ReaderAnnotation(
                    id: existing.id,
                    bookId: bookStableId,
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
                        bookId: bookStableId,
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

        return Snapshot(bookmarks: bookmarks, annotations: annotations)
    }

    static func canonicalCFI(in locator: String?) -> String? {
        EpubLocationBridge.canonicalFullEPUBCFI(EpubLocationBridge.epubCFI(from: locator))
    }

    static func hrefsBySpineStep(in snapshot: Snapshot) -> [String: String] {
        var hrefs: [String: String] = [:]
        for locator in snapshot.bookmarks.map(\.locator) + snapshot.annotations.map(\.locator) {
            guard let step = EpubLocationBridge.spineStep(ofCanonicalCFI: canonicalCFI(in: locator)),
                hrefs[step] == nil,
                let href = EpubLocationBridge.href(from: locator)
            else { continue }
            hrefs[step] = href
        }
        return hrefs
    }

    static func locator(
        fromCFI cfi: String?,
        existing: String?,
        hrefsBySpineStep: [String: String],
        highlightedText: String? = nil
    ) -> String? {
        guard let canonical = EpubLocationBridge.canonicalFullEPUBCFI(cfi) else { return existing }
        let spineStep = EpubLocationBridge.spineStep(ofCanonicalCFI: canonical)
        let resolvedHref = spineStep.flatMap { hrefsBySpineStep[$0] }
        let existingStep = EpubLocationBridge.spineStep(ofCanonicalCFI: canonicalCFI(in: existing))

        // Locator metadata cannot cross spine documents safely.
        if let existing, existingStep == nil || existingStep == spineStep,
            let data = existing.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var locations = json["locations"] as? [String: Any] ?? [:]
            locations["cfi"] = canonical
            locations[EpubLocationBridge.sourceEngineLocationKey] = ReaderEngineKind.foliate.rawValue
            json["locations"] = locations
            if EpubLocationBridge.href(from: existing) == nil, let resolvedHref {
                json["href"] = resolvedHref
            }
            if let highlightedText, !highlightedText.isEmpty,
                EpubLocationBridge.href(from: existing) != nil || resolvedHref != nil
            {
                var text = json["text"] as? [String: Any] ?? [:]
                text["highlight"] = highlightedText
                json["text"] = text
            }
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                return String(data: data, encoding: .utf8)
            }
        }
        var locator: [String: Any] = [
            "href": resolvedHref ?? "",
            "type": "application/xhtml+xml",
            "locations": [
                "cfi": canonical,
                EpubLocationBridge.sourceEngineLocationKey: ReaderEngineKind.foliate.rawValue,
            ],
        ]
        if let highlightedText, !highlightedText.isEmpty, resolvedHref != nil {
            locator["text"] = ["highlight": highlightedText]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: locator) else { return existing }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class BookOrbitReaderArtifactSync {
    static let shared = BookOrbitReaderArtifactSync()

    struct Result {
        let pulled: Int
        let pushed: Int
    }

    private var queue: BookOrbitArtifactQueue

    private init() {
        queue = .loaded(from: .standard)
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
        queue.bookIds(connectionId: providerId)
    }

    func sync(
        book: Book,
        provider: BookOrbitProvider,
        spineHrefs: [String: String] = [:]
    ) async -> Result {
        let now = Date()
        let pushed = await flush(book: book, provider: provider, now: now)

        do {
            async let remoteBookmarksTask = provider.fetchReaderBookmarks(for: book)
            async let remoteAnnotationsTask = provider.fetchReaderAnnotations(for: book)
            let (remoteBookmarks, remoteAnnotations) = try await (remoteBookmarksTask, remoteAnnotationsTask)
            let pulled = await merge(
                book: book,
                connectionId: provider.connection.id,
                remoteBookmarks: remoteBookmarks,
                remoteAnnotations: remoteAnnotations,
                spineHrefs: spineHrefs
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

    private func enqueue(_ operation: BookOrbitArtifactQueue.Operation) {
        queue.enqueue(operation)
        queue.persist(to: .standard)
    }

    private func flush(book: Book, provider: BookOrbitProvider, now: Date) async -> Int {
        let before = queue
        var pushed = 0

        for operation in queue.dueOperations(
            connectionId: provider.connection.id,
            bookId: book.stableId,
            now: now
        ) {
            do {
                switch operation {
                case .upsertBookmark(_, _, let localId):
                    var bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
                    guard let index = bookmarks.firstIndex(where: { $0.id == localId }) else {
                        queue.remove(operation)
                        continue
                    }
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
                    guard let index = annotations.firstIndex(where: { $0.id == localId }) else {
                        queue.remove(operation)
                        continue
                    }
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
                queue.remove(operation)
                pushed += 1
            } catch is CancellationError {
                break
            } catch ProviderError.noCFI {
                recordFailure(operation, book: book, reason: "no canonical CFI to upload", now: now)
            } catch {
                recordFailure(operation, book: book, reason: error.localizedDescription, now: now)
            }
        }

        if queue != before {
            queue.persist(to: .standard)
        }
        return pushed
    }

    private func recordFailure(
        _ operation: BookOrbitArtifactQueue.Operation,
        book: Book,
        reason: String,
        now: Date
    ) {
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        if queue.recordFailure(operation, now: now) {
            AppLogger.sync.error(
                "[BookOrbit] Reader-artifact push deferred bookDiagnosticID=\(diagnosticID): \(reason)"
            )
        } else {
            AppLogger.sync.error(
                "[BookOrbit] Reader-artifact push abandoned after \(BookOrbitArtifactQueue.maxAttempts) attempts bookDiagnosticID=\(diagnosticID): \(reason)"
            )
        }
    }

    private func merge(
        book: Book,
        connectionId: UUID,
        remoteBookmarks: [BookOrbitProvider.ReaderBookmarkRecord],
        remoteAnnotations: [BookOrbitProvider.ReaderAnnotationRecord],
        spineHrefs: [String: String]
    ) async -> Int {
        let snapshot = BookOrbitArtifactMerge.Snapshot(
            bookmarks: ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId),
            annotations: ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
        )
        let merged = BookOrbitArtifactMerge.applying(
            bookmarks: remoteBookmarks,
            annotations: remoteAnnotations,
            to: snapshot,
            bookStableId: book.stableId,
            pendingWork: queue.pendingWork(connectionId: connectionId, bookId: book.stableId),
            spineHrefs: spineHrefs
        )

        if merged.bookmarks != snapshot.bookmarks {
            await persist(bookmarks: merged.bookmarks, book: book)
        }
        if merged.annotations != snapshot.annotations {
            await persist(annotations: merged.annotations, book: book)
        }
        return changeCount(snapshot.bookmarks, merged.bookmarks)
            + changeCount(snapshot.annotations, merged.annotations)
    }

    private func changeCount<T: Identifiable & Equatable>(_ before: [T], _ after: [T]) -> Int {
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let current = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let removed = previous.keys.filter { current[$0] == nil }.count
        return removed + current.filter { previous[$0.key] != $0.value }.count
    }

    private func persist(bookmarks: [Bookmark], book: Book) async {
        ReaderArtifactsStore.shared.saveBookmarks(bookId: book.stableId, bookmarks: bookmarks)
        await AppState.shared.bookStore.replaceBookmarks(forBookStableId: book.stableId, bookmarks: bookmarks)
    }

    private func persist(annotations: [ReaderAnnotation], book: Book) async {
        ReaderArtifactsStore.shared.saveAnnotations(bookId: book.stableId, annotations: annotations)
        await AppState.shared.bookStore.replaceAnnotations(forBookStableId: book.stableId, annotations: annotations)
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
}
