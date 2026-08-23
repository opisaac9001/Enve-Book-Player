import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

@MainActor
final class ReaderAnnotationController {
    struct Context {
        let selection: ReaderSelectionSnapshot?
        let engineKind: ReaderEngineKind
        let progress: Double?
        let chapterTitle: String?
    }

    static let annotationDecorationGroup = "reader-annotations"
    static let noteIndicatorDecorationGroup = "reader-note-indicators"

    var onChange: (() -> Void)?
    var onDecorationRefresh: (() -> Void)?
    var locationProvider: (() -> ReaderArtifactLocation?)?
    var contextProvider: (() -> Context?)?
    var clearSelection: (() -> Void)?

    var editingAnnotation: ReaderAnnotation? {
        willSet { onChange?() }
    }

    var bookmarks: [Bookmark] { store.bookmarks }
    var annotations: [ReaderAnnotation] { store.annotations }

    let decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = ReaderAnnotationController.makeDecorationTemplates()

    private let book: Book
    private let store: any ReaderArtifactsStoring
    private let sync: any ReaderNotebookSyncing
    private let persistVocab: (VocabEntry) async -> Void
    private let defineWord: (String, String?) async -> String?

    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }

    init(
        book: Book,
        store: any ReaderArtifactsStoring,
        sync: any ReaderNotebookSyncing,
        persistVocab: @escaping (VocabEntry) async -> Void,
        defineWord: @escaping (String, String?) async -> String? = {
            await DefinitionLookupService.shared.definition(for: $0, language: $1)
        }
    ) {
        self.book = book
        self.store = store
        self.sync = sync
        self.persistVocab = persistVocab
        self.defineWord = defineWord
        self.store.onChange = { [weak self] in self?.onChange?() }
    }

    func loadBookmarks() {
        store.loadBookmarks()
    }

    func addBookmark(title: String? = nil, note: String? = nil) {
        guard let location = locationProvider?() else { return }
        let bookmark = store.addBookmark(location: location, title: title, note: note)
        AppLogger.general.debug("Added ebook bookmark bookDiagnosticID=\(bookDiagnosticID)")
        dispatch { await $0.bookmarkAdded(bookmark) }
    }

    func updateBookmark(_ bookmark: Bookmark, title: String, note: String?) {
        guard let updated = store.updateBookmark(bookmark, title: title, note: note) else { return }
        dispatch { await $0.bookmarkUpdated(updated) }
    }

    func removeBookmark(_ bookmark: Bookmark) {
        store.removeBookmark(bookmark)
        dispatch { await $0.bookmarkRemoved(bookmark) }
    }

    func loadAnnotations() {
        store.loadAnnotations()
        onDecorationRefresh?()
    }

    func addAnnotation(text: String, note: String?, style: ReaderAnnotationStyle, colorHex: String) {
        guard let location = locationProvider?() else { return }
        let annotation = store.addAnnotation(text: text, note: note, style: style, colorHex: colorHex, location: location)
        onDecorationRefresh?()
        dispatch { await $0.annotationUpserted(annotation) }
    }

    func addAnnotationFromSelection(style: ReaderAnnotationStyle, colorHex: String, note: String? = nil) {
        guard let context = contextProvider?(), let selection = context.selection else { return }
        let text = selection.locator.text.highlight ?? ""
        guard !text.isEmpty else { return }

        let position =
            selection.locator.locations.totalProgression
            ?? selection.locator.locations.progression
            ?? context.progress ?? 0
        let locator =
            EpubLocationBridge.markingSourceEngine(
                context.engineKind,
                in: selection.locatorJSON
            ) ?? selection.locatorJSON

        let annotation = store.addAnnotation(
            text: text,
            note: note,
            style: style,
            colorHex: colorHex,
            location: ReaderArtifactLocation(
                position: position,
                locator: locator,
                chapterTitle: context.chapterTitle?.isEmpty == false ? context.chapterTitle : nil
            )
        )
        onDecorationRefresh?()
        clearSelection?()
        dispatch { await $0.annotationUpserted(annotation) }
    }

    func updateAnnotation(
        _ annotation: ReaderAnnotation,
        style: ReaderAnnotationStyle? = nil,
        colorHex: String? = nil,
        note: String? = nil,
        replaceNote: Bool = false
    ) {
        guard
            let updated = store.updateAnnotation(
                annotation,
                style: style,
                colorHex: colorHex,
                note: note,
                replaceNote: replaceNote,
                chapterTitle: contextProvider?()?.chapterTitle
            )
        else { return }
        onDecorationRefresh?()
        dispatch { await $0.annotationUpserted(updated) }
    }

    func removeAnnotation(_ annotation: ReaderAnnotation) {
        store.removeAnnotation(annotation)
        onDecorationRefresh?()
        dispatch { await $0.annotationRemoved(annotation) }
    }

    func vocabEntryFromSelection() -> VocabEntry? {
        guard let context = contextProvider?(), let selection = context.selection else { return nil }
        let word = selection.locator.text.highlight ?? ""
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let before = selection.locator.text.before ?? ""
        let after = selection.locator.text.after ?? ""
        let sentence = SentenceExtractor.enclosingSentence(before: before, word: trimmed, after: after)
        let position =
            selection.locator.locations.totalProgression
            ?? selection.locator.locations.progression
            ?? context.progress ?? 0

        return VocabEntry(
            bookStableId: book.stableId,
            word: trimmed,
            sentence: sentence,
            sentenceBefore: before,
            sentenceAfter: after,
            locator: selection.locatorJSON,
            position: position,
            chapterTitle: context.chapterTitle?.isEmpty == false ? context.chapterTitle : nil,
            sourceLanguage: book.language
        )
    }

    func saveVocab(_ entry: VocabEntry) {
        Task { @MainActor in
            await persistVocab(entry)
            guard entry.definitionSnapshot?.isEmpty ?? true else { return }
            if let definition = await defineWord(entry.word, entry.sourceLanguage) {
                var hydrated = entry
                hydrated.definitionSnapshot = definition
                await persistVocab(hydrated)
            }
        }
    }

    func syncNotebookEntriesIfNeeded() async {
        let outcome = await sync.pull(localArtifacts: {
            ReaderNotebookMerge.Snapshot(bookmarks: self.bookmarks, annotations: self.annotations)
        })
        apply(outcome)
    }

    var readiumDecorations: (annotations: [Decoration], noteIndicators: [Decoration]) {
        var decorations: [Decoration] = []
        var noteIndicators: [Decoration] = []
        for annotation in annotations {
            guard let locatorJSON = annotation.locator,
                let locator = try? Locator(jsonString: locatorJSON)
            else {
                continue
            }
            let tint = UIColor(hexString: annotation.colorHex) ?? UIColor.systemYellow
            let style: Decoration.Style
            switch annotation.style {
            case .highlight:
                style = .highlight(tint: tint, isActive: false)
            case .underline:
                style = .underline(tint: tint, isActive: false)
            case .strikethrough:
                style = Decoration.Style(
                    id: Decoration.Style.Id(rawValue: "strikethrough"),
                    config: Decoration.Style.HighlightConfig(tint: tint, isActive: false)
                )
            case .squiggly:
                style = Decoration.Style(
                    id: Decoration.Style.Id(rawValue: "squiggly"),
                    config: Decoration.Style.HighlightConfig(tint: tint, isActive: false)
                )
            }
            decorations.append(Decoration(id: annotation.id, locator: locator, style: style))

            if let note = annotation.note, !note.isEmpty {
                let noteStyle = Decoration.Style(
                    id: Decoration.Style.Id(rawValue: "note-indicator"),
                    config: Decoration.Style.HighlightConfig(tint: tint, isActive: false)
                )
                noteIndicators.append(Decoration(id: "note-\(annotation.id)", locator: locator, style: noteStyle))
            }
        }
        return (decorations, noteIndicators)
    }

    func observeDecorationInteractions(on navigator: EPUBNavigatorViewController) {
        navigator.observeDecorationInteractions(inGroup: Self.annotationDecorationGroup) { [weak self] event in
            self?.activateAnnotation(id: event.decoration.id)
        }
        navigator.observeDecorationInteractions(inGroup: Self.noteIndicatorDecorationGroup) { [weak self] event in
            let decorationId = event.decoration.id
            self?.activateAnnotation(id: decorationId.hasPrefix("note-") ? String(decorationId.dropFirst(5)) : decorationId)
        }
    }

    func activateAnnotation(id: String) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        editingAnnotation = annotation
    }

    private func dispatch(_ operation: @escaping (any ReaderNotebookSyncing) async -> ReaderNotebookSyncOutcome) {
        Task { @MainActor [sync] in
            apply(await operation(sync))
        }
    }

    private func apply(_ outcome: ReaderNotebookSyncOutcome) {
        switch outcome {
        case .unchanged:
            break
        case .bookmarkRemoteID(let localID, let remoteID):
            store.updateBookmarkRemoteID(bookmarkID: localID, remoteID: remoteID)
        case .annotationRemoteRecord(let localID, let remoteID, let updatedAt):
            store.updateAnnotationRemoteRecord(annotationID: localID, remoteID: remoteID, updatedAt: updatedAt)
        case .replace(let bookmarks, let annotations):
            store.replace(bookmarks: bookmarks, annotations: annotations)
            onDecorationRefresh?()
        case .reload:
            store.loadBookmarks()
            store.loadAnnotations()
            onDecorationRefresh?()
        }
    }

    private static func makeDecorationTemplates() -> [Decoration.Style.Id: HTMLDecorationTemplate] {
        var templates = HTMLDecorationTemplate.defaultTemplates()
        templates["strikethrough"] = HTMLDecorationTemplate(
            layout: .boxes,
            element: { decoration in
                let config = decoration.style.config as? Decoration.Style.HighlightConfig
                let tint = config?.tint ?? .systemYellow
                return "<div class=\"enve-strikethrough\" style=\"--strike-color: \(tint.cssValue());\" />"
            },
            stylesheet: """
                .enve-strikethrough {
                    background: linear-gradient(
                        to bottom,
                        transparent 45%,
                        var(--strike-color) 45%,
                        var(--strike-color) 55%,
                        transparent 55%
                    ) !important;
                    border-radius: 1px;
                }
                """
        )
        templates["squiggly"] = HTMLDecorationTemplate(
            layout: .boxes,
            element: { decoration in
                let config = decoration.style.config as? Decoration.Style.HighlightConfig
                let tint = config?.tint ?? .systemYellow
                return "<div class=\"enve-squiggly\" style=\"--squiggly-color: \(tint.cssValue());\" />"
            },
            stylesheet: """
                .enve-squiggly {
                    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='6' height='3'%3E%3Cpath d='M0 3 Q1.5 0 3 3 Q4.5 6 6 3' fill='none' stroke='currentColor' stroke-width='1'/%3E%3C/svg%3E");
                    background-repeat: repeat-x;
                    background-position: bottom;
                    background-size: 6px 3px;
                    padding-bottom: 3px;
                    color: var(--squiggly-color);
                }
                """
        )
        templates["note-indicator"] = HTMLDecorationTemplate(
            layout: .bounds,
            element: { decoration in
                let config = decoration.style.config as? Decoration.Style.HighlightConfig
                let tint = config?.tint ?? .systemYellow
                return """
                    <div class="enve-note-indicator" style="--note-color: \(tint.cssValue());">
                        <span class="enve-note-badge">✱</span>
                    </div>
                    """
            },
            stylesheet: """
                .enve-note-indicator {
                    position: relative;
                    pointer-events: auto;
                }
                .enve-note-badge {
                    position: absolute;
                    top: -4px;
                    right: -2px;
                    font-size: 14px;
                    font-weight: bold;
                    color: var(--note-color);
                    text-shadow: 0 0 2px rgba(0,0,0,0.3);
                    cursor: pointer;
                    z-index: 10;
                    line-height: 1;
                }
                """
        )
        return templates
    }
}
