import Foundation
import ReadiumNavigator
import ReadiumShared
import Testing

@testable import enve

@MainActor
struct ReaderAnnotationControllerTests {
    @Test func addingBookmarkPersistsReaderLocationAndPushesToProvider() async {
        let harness = Harness()
        harness.location = ReaderArtifactLocation(position: 0.4, locator: #"{"href":"c1.xhtml"}"#, chapterTitle: "Chapter 1")

        harness.controller.addBookmark(title: "Mark", note: "Note")

        #expect(harness.store.bookmarks.count == 1)
        #expect(harness.store.bookmarks[0].position == 0.4)
        #expect(harness.store.bookmarks[0].chapterTitle == "Chapter 1")
        await harness.waitUntil { harness.sync.calls.count == 1 }
        #expect(harness.sync.calls == [.bookmarkAdded(harness.store.bookmarks[0].id)])
    }

    @Test func addingBookmarkWithoutAReaderLocationIsIgnored() async {
        let harness = Harness()
        harness.location = nil

        harness.controller.addBookmark()

        #expect(harness.store.bookmarks.isEmpty)
        #expect(harness.sync.calls.isEmpty)
    }

    @Test func remoteBookmarkIdentifierOutcomeIsWrittenBackToTheLocalStore() async {
        let harness = Harness()
        harness.location = ReaderArtifactLocation(position: 0.1, locator: nil, chapterTitle: nil)
        harness.sync.outcome = { call in
            guard case .bookmarkAdded(let localID) = call else { return .unchanged }
            return .bookmarkRemoteID(localID: localID, remoteID: 42)
        }

        harness.controller.addBookmark()

        await harness.waitUntil { harness.store.bookmarks.first?.remoteID == 42 }
        #expect(harness.store.bookmarks.first?.remoteID == 42)
    }

    @Test func removingAnnotationRefreshesDecorationsAndPushesTheDelete() async {
        let harness = Harness()
        harness.location = ReaderArtifactLocation(position: 0.2, locator: nil, chapterTitle: nil)
        harness.controller.addAnnotation(text: "Hello", note: nil, style: .highlight, colorHex: "#FFF59D")
        let annotation = harness.store.annotations[0]
        harness.decorationRefreshes = 0

        harness.controller.removeAnnotation(annotation)

        #expect(harness.store.annotations.isEmpty)
        #expect(harness.decorationRefreshes == 1)
        await harness.waitUntil { harness.sync.calls.contains(.annotationRemoved(annotation.id)) }
    }

    @Test func pullReplacesLocalArtifactsAndRefreshesDecorations() async {
        let harness = Harness()
        let bookmark = Bookmark(bookId: "stable-1", position: 0.5, title: "Synced", mediaType: .ebook, remoteID: 3)
        let annotation = ReaderAnnotation(bookId: "book-1", text: "Synced", remoteID: 4)
        harness.sync.outcome = { _ in .replace(bookmarks: [bookmark], annotations: [annotation]) }

        await harness.controller.syncNotebookEntriesIfNeeded()

        #expect(harness.sync.calls == [.pull])
        #expect(harness.store.bookmarks == [bookmark])
        #expect(harness.store.annotations == [annotation])
        #expect(harness.decorationRefreshes == 1)
    }

    @Test func reloadOutcomeRereadsArtifactsFromTheStore() async {
        let harness = Harness()
        harness.store.persistedBookmarks = [Bookmark(bookId: "stable-1", position: 0.9, title: "From store", mediaType: .ebook)]
        harness.sync.outcome = { _ in .reload }

        await harness.controller.syncNotebookEntriesIfNeeded()

        #expect(harness.store.bookmarks.map(\.title) == ["From store"])
        #expect(harness.decorationRefreshes == 1)
    }

    @Test func annotationFromSelectionMarksTheSourceEngineAndClearsTheSelection() async throws {
        let harness = Harness()
        harness.context = ReaderAnnotationController.Context(
            selection: try makeSelection(highlight: "Selected words"),
            engineKind: .foliate,
            progress: 0.3,
            chapterTitle: "Chapter 2"
        )

        harness.controller.addAnnotationFromSelection(style: .underline, colorHex: "#ABCDEF")

        let annotation = try #require(harness.store.annotations.first)
        #expect(annotation.text == "Selected words")
        #expect(annotation.style == .underline)
        #expect(annotation.chapterTitle == "Chapter 2")
        #expect(annotation.position == 0.6)
        #expect(annotation.locator?.contains(ReaderEngineKind.foliate.rawValue) == true)
        #expect(harness.selectionCleared)
    }

    @Test func emptySelectionYieldsNeitherAnnotationNorVocabularyEntry() throws {
        let harness = Harness()
        harness.context = ReaderAnnotationController.Context(
            selection: try makeSelection(highlight: ""),
            engineKind: .readium,
            progress: nil,
            chapterTitle: nil
        )

        harness.controller.addAnnotationFromSelection(style: .highlight, colorHex: "#FFF59D")

        #expect(harness.store.annotations.isEmpty)
        #expect(harness.controller.vocabEntryFromSelection() == nil)
    }

    @Test func whitespaceOnlySelectionYieldsNoVocabularyEntry() throws {
        let harness = Harness()
        harness.context = ReaderAnnotationController.Context(
            selection: try makeSelection(highlight: "   "),
            engineKind: .readium,
            progress: nil,
            chapterTitle: nil
        )

        #expect(harness.controller.vocabEntryFromSelection() == nil)
    }

    @Test func vocabularyEntryCapturesTheEnclosingSentenceAroundTheSelection() throws {
        let harness = Harness()
        harness.context = ReaderAnnotationController.Context(
            selection: try makeSelection(highlight: "loquacious", before: "He was ", after: " today. And then"),
            engineKind: .readium,
            progress: 0.1,
            chapterTitle: "Chapter 3"
        )

        let entry = try #require(harness.controller.vocabEntryFromSelection())
        #expect(entry.word == "loquacious")
        #expect(entry.bookStableId == harness.book.stableId)
        #expect(entry.sentence.contains("loquacious"))
        #expect(entry.chapterTitle == "Chapter 3")
        #expect(entry.position == 0.6)
    }

    @Test func savedVocabularyIsHydratedWithALookedUpDefinition() async {
        let harness = Harness()
        let entry = VocabEntry(bookStableId: "stable-1", word: "loquacious", sentence: "He was loquacious today.")

        harness.controller.saveVocab(entry)

        await harness.waitUntil { harness.persistedVocab.count == 2 }
        #expect(harness.persistedVocab.map(\.definitionSnapshot) == [nil, "talkative"])
    }

    @Test func decorationPayloadSkipsAnnotationsWithoutALocatorAndFlagsNotes() async throws {
        let harness = Harness()
        harness.location = ReaderArtifactLocation(position: 0.2, locator: locatorJSON, chapterTitle: nil)
        harness.controller.addAnnotation(text: "With note", note: "A note", style: .highlight, colorHex: "#FFF59D")
        harness.location = ReaderArtifactLocation(position: 0.3, locator: nil, chapterTitle: nil)
        harness.controller.addAnnotation(text: "No locator", note: nil, style: .highlight, colorHex: "#FFF59D")

        let payload = harness.controller.readiumDecorations
        #expect(payload.annotations.count == 1)
        #expect(payload.noteIndicators.count == 1)
        #expect(payload.noteIndicators[0].id == "note-\(payload.annotations[0].id)")
    }

    @Test func activatingADecorationSelectsTheMatchingAnnotationForEditing() {
        let harness = Harness()
        harness.location = ReaderArtifactLocation(position: 0.2, locator: nil, chapterTitle: nil)
        harness.controller.addAnnotation(text: "Editable", note: nil, style: .highlight, colorHex: "#FFF59D")
        let annotation = harness.store.annotations[0]

        harness.controller.activateAnnotation(id: "missing")
        #expect(harness.controller.editingAnnotation == nil)

        harness.controller.activateAnnotation(id: annotation.id)
        #expect(harness.controller.editingAnnotation == annotation)
    }

    @Test func pullMergesLocalArtifactsThatArriveWhileTheRemoteFetchIsInFlight() async {
        let store = InMemoryReaderArtifactsStore()
        let sync = GatedReaderNotebookSync(book: makeReaderTestBook())
        let controller = ReaderAnnotationController(
            book: makeReaderTestBook(),
            store: store,
            sync: sync,
            persistVocab: { _ in }
        )
        controller.locationProvider = { ReaderArtifactLocation(position: 0.4, locator: nil, chapterTitle: nil) }
        store.persistedBookmarks = [Bookmark(bookId: "stable-1", position: 0.1, title: "Persisted", mediaType: .ebook)]
        store.persistedAnnotations = [ReaderAnnotation(bookId: "book-1", text: "Persisted")]

        // ReaderScreen starts the pull before `open()` has loaded anything from disk.
        #expect(store.bookmarks.isEmpty)
        #expect(store.annotations.isEmpty)
        let pull = Task { await controller.syncNotebookEntriesIfNeeded() }
        await sync.waitUntilFetchStarted()

        controller.loadBookmarks()
        controller.loadAnnotations()
        controller.addBookmark(title: "Mid-fetch", note: nil)
        controller.addAnnotation(text: "Mid-fetch", note: nil, style: .highlight, colorHex: "#FFF59D")

        sync.resumeFetch()
        await pull.value

        #expect(store.bookmarks.map(\.title) == ["Persisted", "Mid-fetch", "Remote"])
        #expect(store.annotations.map(\.text) == ["Persisted", "Mid-fetch", "Remote"])
    }

    private var locatorJSON: String {
        #"{"href":"c1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.2}}"#
    }

    private func makeSelection(highlight: String, before: String = "", after: String = "") throws -> ReaderSelectionSnapshot {
        let payload: [String: Any] = [
            "href": "c1.xhtml",
            "type": "application/xhtml+xml",
            "locations": ["progression": 0.5, "totalProgression": 0.6],
            "text": ["before": before, "highlight": highlight, "after": after],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return ReaderSelectionSnapshot(locator: try Locator(jsonString: json), locatorJSON: json, frame: nil)
    }
}

private func makeReaderTestBook() -> Book {
    Book(
        id: "book-1",
        title: "Reader",
        source: .booklore,
        backendId: "unit",
        providerId: UUID(uuidString: "037F7AEC-8674-481B-AE53-8F93B92B9401")!,
        libraryId: "library-1"
    )
}

@MainActor
private final class Harness {
    let store = InMemoryReaderArtifactsStore()
    let sync = RecordingReaderNotebookSync()
    var controller: ReaderAnnotationController!

    var location: ReaderArtifactLocation?
    var context: ReaderAnnotationController.Context?
    var decorationRefreshes = 0
    var selectionCleared = false
    var persistedVocab: [VocabEntry] = []

    let book = makeReaderTestBook()

    init() {
        controller = ReaderAnnotationController(
            book: book,
            store: store,
            sync: sync,
            persistVocab: { [weak self] in self?.persistedVocab.append($0) },
            defineWord: { word, _ in word == "loquacious" ? "talkative" : nil }
        )
        controller.locationProvider = { [weak self] in self?.location }
        controller.contextProvider = { [weak self] in self?.context }
        controller.clearSelection = { [weak self] in self?.selectionCleared = true }
        controller.onDecorationRefresh = { [weak self] in self?.decorationRefreshes += 1 }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class RecordingReaderNotebookSync: ReaderNotebookSyncing {
    enum Call: Equatable {
        case pull
        case bookmarkAdded(String)
        case bookmarkUpdated(String)
        case bookmarkRemoved(String)
        case annotationUpserted(String)
        case annotationRemoved(String)
    }

    private(set) var calls: [Call] = []
    var outcome: (Call) -> ReaderNotebookSyncOutcome = { _ in .unchanged }

    func pull(localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        record(.pull)
    }

    func bookmarkAdded(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome {
        record(.bookmarkAdded(bookmark.id))
    }

    func bookmarkUpdated(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome {
        record(.bookmarkUpdated(bookmark.id))
    }

    func bookmarkRemoved(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome {
        record(.bookmarkRemoved(bookmark.id))
    }

    func annotationUpserted(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome {
        record(.annotationUpserted(annotation.id))
    }

    func annotationRemoved(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome {
        record(.annotationRemoved(annotation.id))
    }

    private func record(_ call: Call) -> ReaderNotebookSyncOutcome {
        calls.append(call)
        return outcome(call)
    }
}

@MainActor
private final class GatedReaderNotebookSync: ReaderNotebookSyncing {
    private let book: Book
    private var isFetching = false
    private var isResumed = false
    private var fetchGate: CheckedContinuation<Void, Never>?
    private var fetchStarted: CheckedContinuation<Void, Never>?

    init(book: Book) {
        self.book = book
    }

    func waitUntilFetchStarted() async {
        guard !isFetching else { return }
        await withCheckedContinuation { fetchStarted = $0 }
    }

    func resumeFetch() {
        isResumed = true
        fetchGate?.resume()
        fetchGate = nil
    }

    func pull(localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        isFetching = true
        fetchStarted?.resume()
        fetchStarted = nil
        if !isResumed {
            await withCheckedContinuation { fetchGate = $0 }
        }
        let merged = ReaderNotebookMerge.applyingBookloreRecords(
            annotations: [
                BookloreProvider.RemoteAnnotationRecord(
                    id: 10,
                    bookId: 1,
                    cfi: "epubcfi(/6/4!/4/2)",
                    text: "Remote",
                    color: "#FFF59D",
                    style: "highlight",
                    note: nil,
                    chapterTitle: nil,
                    createdAt: "2025-01-01T00:00:00Z",
                    updatedAt: "2025-01-02T00:00:00Z"
                )
            ],
            bookmarks: [
                BookloreProvider.RemoteBookmarkRecord(
                    id: 9,
                    bookId: 1,
                    cfi: "epubcfi(/6/4!/4/2)",
                    positionMs: nil,
                    trackIndex: nil,
                    title: "Remote",
                    notes: nil,
                    color: nil,
                    priority: nil,
                    createdAt: "2025-01-01T00:00:00Z",
                    updatedAt: "2025-01-02T00:00:00Z"
                )
            ],
            to: localArtifacts(),
            bookID: book.id,
            bookStableID: book.stableId
        )
        return .replace(bookmarks: merged.bookmarks, annotations: merged.annotations)
    }

    func bookmarkAdded(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome { .unchanged }
    func bookmarkUpdated(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome { .unchanged }
    func bookmarkRemoved(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome { .unchanged }
    func annotationUpserted(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome { .unchanged }
    func annotationRemoved(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome { .unchanged }
}

@MainActor
private final class InMemoryReaderArtifactsStore: ReaderArtifactsStoring {
    var onChange: (() -> Void)?
    private(set) var bookmarks: [Bookmark] = []
    private(set) var annotations: [ReaderAnnotation] = []

    var persistedBookmarks: [Bookmark] = []
    var persistedAnnotations: [ReaderAnnotation] = []

    func loadBookmarks() {
        onChange?()
        bookmarks = persistedBookmarks
    }

    func addBookmark(location: ReaderArtifactLocation, title: String?, note: String?) -> Bookmark {
        let bookmark = Bookmark(
            bookId: "stable-1",
            position: location.position,
            title: title ?? location.chapterTitle ?? "Bookmark",
            note: note,
            locator: location.locator,
            mediaType: .ebook,
            chapterTitle: location.chapterTitle
        )
        onChange?()
        bookmarks.append(bookmark)
        return bookmark
    }

    func removeBookmark(_ bookmark: Bookmark) {
        onChange?()
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    func updateBookmark(_ bookmark: Bookmark, title: String, note: String?) -> Bookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return nil }
        let updated = Bookmark(
            id: bookmark.id,
            bookId: bookmark.bookId,
            position: bookmark.position,
            title: title,
            note: note,
            timestamp: bookmark.timestamp,
            locator: bookmark.locator,
            mediaType: bookmark.mediaType,
            chapterTitle: bookmark.chapterTitle,
            remoteID: bookmark.remoteID,
            isRemotePlaceholder: bookmark.isRemotePlaceholder
        )
        onChange?()
        bookmarks[index] = updated
        return updated
    }

    func updateBookmarkRemoteID(bookmarkID: String, remoteID: Int) -> Bookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return nil }
        let existing = bookmarks[index]
        let updated = Bookmark(
            id: existing.id,
            bookId: existing.bookId,
            position: existing.position,
            title: existing.title,
            note: existing.note,
            timestamp: existing.timestamp,
            locator: existing.locator,
            mediaType: existing.mediaType,
            chapterTitle: existing.chapterTitle,
            remoteID: remoteID,
            isRemotePlaceholder: false
        )
        onChange?()
        bookmarks[index] = updated
        return updated
    }

    func loadAnnotations() {
        onChange?()
        annotations = persistedAnnotations
    }

    func addAnnotation(
        text: String,
        note: String?,
        style: ReaderAnnotationStyle,
        colorHex: String,
        location: ReaderArtifactLocation
    ) -> ReaderAnnotation {
        let annotation = ReaderAnnotation(
            bookId: "book-1",
            locator: location.locator,
            position: location.position,
            text: text,
            note: note,
            colorHex: colorHex,
            style: style,
            chapterTitle: location.chapterTitle
        )
        onChange?()
        annotations.append(annotation)
        return annotation
    }

    func updateAnnotation(
        _ annotation: ReaderAnnotation,
        style: ReaderAnnotationStyle?,
        colorHex: String?,
        note: String?,
        replaceNote: Bool,
        chapterTitle: String?
    ) -> ReaderAnnotation? {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return nil }
        var updated = annotations[index]
        if let style { updated.style = style }
        if let colorHex { updated.colorHex = colorHex }
        if replaceNote || note != nil { updated.note = note }
        if updated.chapterTitle == nil { updated.chapterTitle = chapterTitle }
        onChange?()
        annotations[index] = updated
        return updated
    }

    func removeAnnotation(_ annotation: ReaderAnnotation) {
        onChange?()
        annotations.removeAll { $0.id == annotation.id }
    }

    func updateAnnotationRemoteRecord(annotationID: String, remoteID: Int, updatedAt: Date?) -> ReaderAnnotation? {
        guard let index = annotations.firstIndex(where: { $0.id == annotationID }) else { return nil }
        var updated = annotations[index]
        updated.remoteID = remoteID
        updated.isRemotePlaceholder = false
        if let updatedAt { updated.updatedAt = updatedAt }
        onChange?()
        annotations[index] = updated
        return updated
    }

    func replace(bookmarks newBookmarks: [Bookmark], annotations newAnnotations: [ReaderAnnotation]) {
        onChange?()
        bookmarks = newBookmarks
        annotations = newAnnotations
    }
}
