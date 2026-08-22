import Foundation

struct ReaderArtifactLocation {
    let position: Double
    let locator: String?
    let chapterTitle: String?
}

@MainActor
protocol ReaderArtifactsStoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    var bookmarks: [Bookmark] { get }
    var annotations: [ReaderAnnotation] { get }

    func loadBookmarks()
    func addBookmark(location: ReaderArtifactLocation, title: String?, note: String?) -> Bookmark
    func removeBookmark(_ bookmark: Bookmark)
    @discardableResult
    func updateBookmark(_ bookmark: Bookmark, title: String, note: String?) -> Bookmark?
    @discardableResult
    func updateBookmarkRemoteID(bookmarkID: String, remoteID: Int) -> Bookmark?

    func loadAnnotations()
    func addAnnotation(
        text: String,
        note: String?,
        style: ReaderAnnotationStyle,
        colorHex: String,
        location: ReaderArtifactLocation
    ) -> ReaderAnnotation
    @discardableResult
    func updateAnnotation(
        _ annotation: ReaderAnnotation,
        style: ReaderAnnotationStyle?,
        colorHex: String?,
        note: String?,
        replaceNote: Bool,
        chapterTitle: String?
    ) -> ReaderAnnotation?
    func removeAnnotation(_ annotation: ReaderAnnotation)
    @discardableResult
    func updateAnnotationRemoteRecord(annotationID: String, remoteID: Int, updatedAt: Date?) -> ReaderAnnotation?

    func replace(bookmarks: [Bookmark], annotations: [ReaderAnnotation])
}

@MainActor
final class ReaderArtifactsAdapter: ReaderArtifactsStoring {
    var onChange: (() -> Void)?
    private(set) var bookmarks: [Bookmark] = []
    private(set) var annotations: [ReaderAnnotation] = []

    private let book: Book
    private let store: ReaderArtifactsStore

    init(book: Book, store: ReaderArtifactsStore = .shared) {
        self.book = book
        self.store = store
    }

    func loadBookmarks() {
        var loaded = store.loadBookmarks(bookId: book.stableId)
        if book.stableId != book.id {
            let legacy = store.loadBookmarks(bookId: book.id)
            if !legacy.isEmpty {
                let existingIds = Set(loaded.map { $0.id })
                loaded.append(contentsOf: legacy.filter { !existingIds.contains($0.id) })
                store.saveBookmarks(bookId: book.stableId, bookmarks: loaded)
                StorageService.shared.remove(forKey: "bookmarks_\(book.id)")
            }
        }
        setBookmarks(loaded)
    }

    func addBookmark(location: ReaderArtifactLocation, title: String?, note: String?) -> Bookmark {
        let bookmark = Bookmark(
            bookId: book.stableId,
            position: location.position,
            title: bookmarkTitle(position: location.position, title: title, mediaType: .ebook, chapterTitle: location.chapterTitle),
            note: note,
            locator: location.locator,
            mediaType: .ebook,
            chapterTitle: location.chapterTitle
        )
        setBookmarks(bookmarks + [bookmark])
        persistBookmarks()
        upsertBookmark(bookmark)
        scheduleExport()
        return bookmark
    }

    func removeBookmark(_ bookmark: Bookmark) {
        setBookmarks(bookmarks.filter { $0.id != bookmark.id })
        persistBookmarks()
        let bookmarkID = bookmark.id
        Task { @MainActor in
            await AppState.shared.bookStore.deleteBookmark(id: bookmarkID)
        }
        scheduleExport()
    }

    @discardableResult
    func updateBookmark(_ bookmark: Bookmark, title: String, note: String?) -> Bookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = bookmarks[index]
        let updated = Bookmark(
            id: existing.id,
            bookId: existing.bookId,
            position: existing.position,
            title: trimmedTitle.isEmpty ? existing.title : trimmedTitle,
            note: trimmedNote?.isEmpty == false ? trimmedNote : nil,
            timestamp: existing.timestamp,
            locator: existing.locator,
            mediaType: existing.mediaType,
            chapterTitle: existing.chapterTitle,
            remoteID: existing.remoteID,
            isRemotePlaceholder: existing.isRemotePlaceholder
        )
        var snapshot = bookmarks
        snapshot[index] = updated
        setBookmarks(snapshot)
        persistBookmarks()
        upsertBookmark(updated)
        scheduleExport()
        return updated
    }

    func replaceBookmarks(_ newBookmarks: [Bookmark]) {
        setBookmarks(newBookmarks)
        persistBookmarks(replaceStoreRecords: true)
    }

    @discardableResult
    func updateBookmarkRemoteID(bookmarkID: String, remoteID: Int) -> Bookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return nil }
        var updated = bookmarks[index]
        updated = Bookmark(
            id: updated.id,
            bookId: updated.bookId,
            position: updated.position,
            title: updated.title,
            note: updated.note,
            timestamp: updated.timestamp,
            locator: updated.locator,
            mediaType: updated.mediaType,
            chapterTitle: updated.chapterTitle,
            remoteID: remoteID,
            isRemotePlaceholder: false
        )
        var snapshot = bookmarks
        snapshot[index] = updated
        setBookmarks(snapshot)
        persistBookmarks()
        upsertBookmark(updated)
        return updated
    }

    func loadAnnotations() {
        var loaded = store.loadAnnotations(bookId: book.stableId)
        if book.stableId != book.id {
            let legacy = store.loadAnnotations(bookId: book.id)
            if !legacy.isEmpty {
                let existingIds = Set(loaded.map { $0.id })
                loaded.append(contentsOf: legacy.filter { !existingIds.contains($0.id) })
                store.saveAnnotations(bookId: book.stableId, annotations: loaded)
                UserDefaults.standard.removeObject(forKey: "readerAnnotations_\(book.id)")
            }
        }
        setAnnotations(loaded)
    }

    func addAnnotation(
        text: String,
        note: String?,
        style: ReaderAnnotationStyle,
        colorHex: String,
        location: ReaderArtifactLocation
    ) -> ReaderAnnotation {
        let annotation = ReaderAnnotation(
            bookId: book.id,
            locator: location.locator,
            position: location.position,
            text: text,
            note: note,
            colorHex: colorHex,
            style: style,
            chapterTitle: location.chapterTitle
        )
        setAnnotations(annotations + [annotation])
        saveAnnotations()
        return annotation
    }

    @discardableResult
    func updateAnnotation(
        _ annotation: ReaderAnnotation,
        style: ReaderAnnotationStyle? = nil,
        colorHex: String? = nil,
        note: String? = nil,
        replaceNote: Bool = false,
        chapterTitle: String?
    ) -> ReaderAnnotation? {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return nil }
        var updated = annotations[index]
        if let style { updated.style = style }
        if let colorHex { updated.colorHex = colorHex }
        if replaceNote {
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.note = trimmed?.isEmpty == false ? trimmed : nil
        } else if let note {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.note = trimmed.isEmpty ? nil : trimmed
        }
        updated.updatedAt = Date()
        if updated.chapterTitle == nil, let chapterTitle, !chapterTitle.isEmpty {
            updated.chapterTitle = chapterTitle
        }
        var snapshot = annotations
        snapshot[index] = updated
        setAnnotations(snapshot)
        saveAnnotations()
        return updated
    }

    func saveAnnotations() {
        store.saveAnnotations(bookId: book.stableId, annotations: annotations)
        let stableID = book.stableId
        let snapshot = annotations
        Task { @MainActor in
            await AppState.shared.bookStore.replaceAnnotations(forBookStableId: stableID, annotations: snapshot)
        }
        scheduleExport()
    }

    func removeAnnotation(_ annotation: ReaderAnnotation) {
        setAnnotations(annotations.filter { $0.id != annotation.id })
        saveAnnotations()
        let annotationID = annotation.id
        Task { @MainActor in
            await AppState.shared.bookStore.deleteAnnotation(id: annotationID)
        }
    }

    func replaceAnnotations(_ newAnnotations: [ReaderAnnotation]) {
        setAnnotations(newAnnotations)
        saveAnnotations()
    }

    func replace(bookmarks newBookmarks: [Bookmark], annotations newAnnotations: [ReaderAnnotation]) {
        setBookmarks(newBookmarks)
        setAnnotations(newAnnotations)
        persistBookmarks(replaceStoreRecords: true)
        saveAnnotations()
    }

    @discardableResult
    func updateAnnotationRemoteRecord(annotationID: String, remoteID: Int, updatedAt: Date?) -> ReaderAnnotation? {
        guard let index = annotations.firstIndex(where: { $0.id == annotationID }) else { return nil }
        var updated = annotations[index]
        updated.remoteID = remoteID
        updated.isRemotePlaceholder = false
        if let updatedAt {
            updated.updatedAt = updatedAt
        }
        var snapshot = annotations
        snapshot[index] = updated
        setAnnotations(snapshot)
        saveAnnotations()
        return updated
    }

    private func setBookmarks(_ newBookmarks: [Bookmark]) {
        onChange?()
        bookmarks = newBookmarks
    }

    private func setAnnotations(_ newAnnotations: [ReaderAnnotation]) {
        onChange?()
        annotations = newAnnotations
    }

    private func persistBookmarks(replaceStoreRecords: Bool = false) {
        store.saveBookmarks(bookId: book.stableId, bookmarks: bookmarks)
        guard replaceStoreRecords else { return }
        let stableID = book.stableId
        let snapshot = bookmarks
        Task { @MainActor in
            await AppState.shared.bookStore.replaceBookmarks(forBookStableId: stableID, bookmarks: snapshot)
        }
    }

    private func upsertBookmark(_ bookmark: Bookmark) {
        let stableID = book.stableId
        Task { @MainActor in
            await AppState.shared.bookStore.upsertBookmark(bookmark, bookStableId: stableID)
        }
    }

    private func scheduleExport() {
        ObsidianNotesCoordinator.shared.scheduleAutoExport(book: book)
    }

    private func bookmarkTitle(position: TimeInterval, title: String?, mediaType: AppMediaType, chapterTitle: String?) -> String {
        if let title, !title.isEmpty {
            return title
        }
        if mediaType == .ebook {
            return chapterTitle ?? "Bookmark at \(Int(position * 100))%"
        }
        if let chapterTitle, !chapterTitle.isEmpty {
            return "Bookmark - \(chapterTitle)"
        }
        return "Bookmark at \(formatTime(position))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let remainingSeconds = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
