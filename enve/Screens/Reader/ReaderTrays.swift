import Combine
@preconcurrency import ReadiumShared
import SwiftUI
import UIKit

struct ReaderContentsTray: View {
    @ObservedObject var model: ClassicReaderModel
    let ambient: Color

    @Environment(\.hearth) private var hearth
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var tab: ReaderContentsTab = .toc
    @State private var query = ""
    @State private var bookmarkFilter: ReaderBookmarkFilter = .all
    @State private var annotationFilter: ReaderAnnotationFilter = .all
    @State private var annotationColorFilter: String?
    @State private var bookmarkEditor: ReaderBookmarkEditorPresentation?
    @State private var annotationEditor: ReaderAnnotationEditorPresentation?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(ReaderContentsTab.allCases, id: \.self) { item in
                    HearthChip(title: item.title, isSelected: tab == item) {
                        PlatformHaptics.selection()
                        tab = item
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)

            if tab != .toc {
                artifactSearchField
            }

            switch tab {
            case .toc: tocList
            case .bookmarks: bookmarksList
            case .notes: notesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .sheet(item: $bookmarkEditor) { presentation in
            ReaderBookmarkEditorSheet(presentation: presentation) { title, note in
                if let bookmark = presentation.bookmark {
                    model.annotationController.updateBookmark(bookmark, title: title, note: note)
                } else {
                    model.annotationController.addBookmark(title: title.isEmpty ? nil : title, note: note)
                    PlatformHaptics.impact(.light)
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .hearthPresentationBackground()
            .enveEnvironment()
        }
        .sheet(item: $annotationEditor) { presentation in
            ReaderAnnotationEditorSheet(annotation: presentation.annotation) { style, color, note in
                model.annotationController.updateAnnotation(
                    presentation.annotation,
                    style: style,
                    colorHex: color,
                    note: note,
                    replaceNote: true
                )
                PlatformHaptics.impact(.light)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .hearthPresentationBackground()
            .enveEnvironment()
        }
    }

    @ViewBuilder
    private var tocList: some View {
        if model.tocEntries.isEmpty {
            emptyNote("This book keeps no table of contents.")
        } else {
            ScrollViewReader { proxy in
                List(model.tocEntries) { entry in
                    Button {
                        Task {
                            await model.navigateToTOCEntry(entry)
                            dismiss()
                        }
                    } label: {
                        Text(entry.displayTitle)
                            .font(.hearthDisplay(entry.depth == 0 ? 17 : 15, weight: .regular))
                            .foregroundStyle(isCurrent(entry) ? ambient : hearth.text)
                            .padding(.leading, CGFloat(entry.depth) * 16)
                            .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(hearth.hairline)
                    .id(entry.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let current = model.tocEntries.first(where: { isCurrent($0) }) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func isCurrent(_ entry: ClassicTOCEntry) -> Bool {
        if let currentId = model.currentTOCEntryId {
            return entry.id == currentId
        }
        guard let title = model.currentSectionTitle, !title.isEmpty else { return false }
        return entry.displayTitle == title
    }

    private var bookmarksList: some View {
        VStack(spacing: 0) {
            HStack {
                QuietButton(title: "Mark this page", systemImage: "bookmark") {
                    bookmarkEditor = ReaderBookmarkEditorPresentation(
                        bookmark: nil,
                        context: model.annotationSummaryText
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            bookmarkFilterBar

            if model.annotationController.bookmarks.isEmpty {
                emptyNote("Nothing marked yet.")
            } else if filteredBookmarks.isEmpty {
                emptyNote("No bookmarks match.")
            } else {
                List(filteredBookmarks) { bookmark in
                    Button {
                        Task {
                            await model.seekToBookmark(bookmark)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bookmark.title)
                                .font(.hearthDisplay(16, weight: .regular))
                                .foregroundStyle(hearth.text)
                                .lineLimit(2)
                            Text(bookmarkCaption(bookmark))
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                            if let note = bookmark.note, !note.isEmpty {
                                Text(note)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(hearth.hairline)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            openURL(EnveNotesCaptureLink.url(book: model.book, bookmark: bookmark))
                        } label: {
                            Label("Capture in Enve Notes", systemImage: "square.and.arrow.up")
                        }
                        .tint(hearth.ember)
                        Button {
                            bookmarkEditor = ReaderBookmarkEditorPresentation(bookmark: bookmark, context: bookmarkCaption(bookmark))
                        } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                        }
                        .tint(hearth.ember)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            model.annotationController.removeBookmark(bookmark)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var bookmarkFilterBar: some View {
        HStack(spacing: 8) {
            ForEach(ReaderBookmarkFilter.allCases) { filter in
                HearthChip(title: filter.title, isSelected: bookmarkFilter == filter) {
                    PlatformHaptics.selection()
                    bookmarkFilter = filter
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var filteredBookmarks: [Bookmark] {
        model.annotationController.bookmarks
            .filter { bookmark in
                switch bookmarkFilter {
                case .all: true
                case .notes: bookmark.note?.isEmpty == false
                }
            }
            .filter { bookmark in
                matchesQuery([
                    bookmark.title,
                    bookmark.note,
                    bookmark.chapterTitle,
                    bookmark.formattedTime,
                    bookmark.formattedDate,
                ])
            }
            .sorted { $0.position < $1.position }
    }

    private func bookmarkCaption(_ bookmark: Bookmark) -> String {
        var parts: [String] = ["\(Int((bookmark.position * 100).rounded()))%"]
        if let chapter = bookmark.chapterTitle, !chapter.isEmpty {
            parts.append(chapter)
        }
        parts.append(bookmark.formattedDate)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var notesList: some View {
        if model.annotationController.annotations.isEmpty {
            emptyNote("Nothing in the margins yet.")
        } else {
            VStack(spacing: 0) {
                annotationFilterBar

                if filteredAnnotations.isEmpty {
                    emptyNote("No notes match.")
                } else {
                    List(filteredAnnotations) { annotation in
                        annotationRow(annotation)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private func annotationRow(_ annotation: ReaderAnnotation) -> some View {
        Button {
            Task {
                await model.seekToAnnotation(annotation)
                dismiss()
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(legacyHexString: annotation.colorHex) ?? hearth.ember)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(annotation.text)
                        .font(.hearthDisplay(15, weight: .regular))
                        .foregroundStyle(hearth.text)
                        .lineLimit(3)
                    if let note = annotation.note, !note.isEmpty {
                        Text(note)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                    Text(annotationCaption(annotation))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 3)
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(hearth.hairline)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                openURL(EnveNotesCaptureLink.url(book: model.book, annotation: annotation))
            } label: {
                Label("Capture in Enve Notes", systemImage: "square.and.arrow.up")
            }
            .tint(hearth.ember)
            Button {
                annotationEditor = ReaderAnnotationEditorPresentation(annotation: annotation)
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }
            .tint(hearth.ember)
            Button {
                copy(annotation)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(hearth.statusOK)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.annotationController.removeAnnotation(annotation)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var annotationFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderAnnotationFilter.allCases) { filter in
                        HearthChip(title: filter.title, isSelected: annotationFilter == filter) {
                            PlatformHaptics.selection()
                            annotationFilter = filter
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            if annotationColorFilters.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button {
                            PlatformHaptics.selection()
                            annotationColorFilter = nil
                        } label: {
                            Text("All colors")
                                .font(.hearthUI(13, weight: annotationColorFilter == nil ? .semibold : .medium))
                                .foregroundStyle(annotationColorFilter == nil ? hearth.ember : hearth.textSecondary)
                        }
                        .buttonStyle(PressableStyle())

                        ForEach(annotationColorFilters, id: \.self) { hex in
                            Button {
                                PlatformHaptics.selection()
                                annotationColorFilter = annotationColorFilter == hex ? nil : hex
                            } label: {
                                Circle()
                                    .fill(Color(legacyHexString: hex) ?? hearth.ember)
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        Circle().strokeBorder(
                                            annotationColorFilter == hex ? hearth.text : hearth.hairline,
                                            lineWidth: annotationColorFilter == hex ? 2 : 1
                                        )
                                    }
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("Filter color")
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var filteredAnnotations: [ReaderAnnotation] {
        model.annotationController.annotations
            .filter { annotation in
                switch annotationFilter {
                case .all: true
                case .notes: annotation.note?.isEmpty == false
                case .highlights: annotation.style == .highlight
                case .underlines: annotation.style == .underline
                case .marks: annotation.style == .strikethrough || annotation.style == .squiggly
                }
            }
            .filter { annotation in
                annotationColorFilter == nil || annotation.colorHex == annotationColorFilter
            }
            .filter { annotation in
                matchesQuery([
                    annotation.text,
                    annotation.note,
                    annotation.chapterTitle,
                    annotation.style.label,
                    annotation.formattedTimestamp,
                ])
            }
            .sorted { $0.position < $1.position }
    }

    private var annotationColorFilters: [String] {
        Array(Set(model.annotationController.annotations.map(\.colorHex))).sorted()
    }

    private func annotationCaption(_ annotation: ReaderAnnotation) -> String {
        var parts = [annotation.style.label, "\(Int((annotation.position * 100).rounded()))%"]
        if let chapter = annotation.chapterTitle, !chapter.isEmpty {
            parts.append(chapter)
        }
        parts.append(annotation.formattedTimestamp)
        return parts.joined(separator: " · ")
    }

    private var artifactSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
            TextField(
                "",
                text: $query,
                prompt: Text(tab == .bookmarks ? "Search bookmarks…" : "Search notes…").font(.hearthDisplay(15, weight: .regular))
            )
            .font(.hearthUI(15))
            .foregroundStyle(hearth.text)
            .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func matchesQuery(_ values: [String?]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return values.compactMap(\.self).contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func copy(_ annotation: ReaderAnnotation) {
        var parts = [annotation.text]
        if let note = annotation.note, !note.isEmpty {
            parts.append(note)
        }
        UIPasteboard.general.string = parts.joined(separator: "\n\n")
        PlatformHaptics.impact(.light)
    }

    private func emptyNote(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.hearthDisplay(16, weight: .regular))
                .foregroundStyle(hearth.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private enum ReaderContentsTab: CaseIterable {
    case toc, bookmarks, notes

    var title: String {
        switch self {
        case .toc: "Contents"
        case .bookmarks: "Bookmarks"
        case .notes: "Notes"
        }
    }
}

private enum ReaderBookmarkFilter: CaseIterable, Identifiable {
    case all, notes

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .notes: "With notes"
        }
    }
}

private enum ReaderAnnotationFilter: CaseIterable, Identifiable {
    case all, notes, highlights, underlines, marks

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .notes: "With notes"
        case .highlights: "Highlights"
        case .underlines: "Underlines"
        case .marks: "Marks"
        }
    }
}

private struct ReaderBookmarkEditorPresentation: Identifiable {
    let id = UUID()
    let bookmark: Bookmark?
    let context: String
}

private struct ReaderAnnotationEditorPresentation: Identifiable {
    let id = UUID()
    let annotation: ReaderAnnotation
}

private struct ReaderBookmarkEditorSheet: View {
    let presentation: ReaderBookmarkEditorPresentation
    let onSave: (String, String?) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @FocusState private var titleFocused: Bool

    init(presentation: ReaderBookmarkEditorPresentation, onSave: @escaping (String, String?) -> Void) {
        self.presentation = presentation
        self.onSave = onSave
        _title = State(initialValue: presentation.bookmark?.title ?? "")
        _note = State(initialValue: presentation.bookmark?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Overline(presentation.bookmark == nil ? "New bookmark" : "Edit bookmark")

            if !presentation.context.isEmpty {
                Text(presentation.context)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(2)
            }

            VStack(spacing: 10) {
                TextField("", text: $title, prompt: Text("Title").font(.hearthDisplay(16, weight: .regular)))
                    .font(.hearthUI(16))
                    .foregroundStyle(hearth.text)
                    .focused($titleFocused)
                    .textInputAutocapitalization(.sentences)
                    .padding(14)
                    .background(editorFieldBackground)

                TextField("", text: $note, prompt: Text("Note").font(.hearthDisplay(16, weight: .regular)), axis: .vertical)
                    .font(.hearthUI(16))
                    .foregroundStyle(hearth.text)
                    .lineLimit(3...6)
                    .padding(14)
                    .background(editorFieldBackground)
            }

            HStack {
                Spacer()
                EmberButton(title: presentation.bookmark == nil ? "Save Bookmark" : "Update Bookmark") {
                    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        trimmedNote.isEmpty ? nil : trimmedNote
                    )
                    dismiss()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .onAppear { titleFocused = presentation.bookmark == nil }
    }

    private var editorFieldBackground: some View {
        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
            .fill(hearth.bgElevated)
            .overlay {
                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
    }
}

private struct ReaderAnnotationEditorSheet: View {
    let annotation: ReaderAnnotation
    let onSave: (ReaderAnnotationStyle, String, String?) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var style: ReaderAnnotationStyle
    @State private var colorHex: String
    @State private var note: String
    @FocusState private var noteFocused: Bool

    private static let inks = ["#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0"]

    init(annotation: ReaderAnnotation, onSave: @escaping (ReaderAnnotationStyle, String, String?) -> Void) {
        self.annotation = annotation
        self.onSave = onSave
        _style = State(initialValue: annotation.style)
        _colorHex = State(initialValue: annotation.colorHex)
        _note = State(initialValue: annotation.note ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Overline("Edit note")

                Text(annotation.text)
                    .font(.hearthDisplay(16, weight: .regular))
                    .foregroundStyle(hearth.text)
                    .lineLimit(4)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(legacyHexString: colorHex) ?? hearth.ember)
                            .frame(width: 2)
                    }

                VStack(alignment: .leading, spacing: 10) {
                    Overline("Style")
                    HStack(spacing: 8) {
                        ForEach(ReaderAnnotationStyle.allCases) { option in
                            HearthChip(title: option.label, isSelected: style == option) {
                                PlatformHaptics.selection()
                                style = option
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Overline("Color")
                    HStack(spacing: 10) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Button {
                                PlatformHaptics.selection()
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(legacyHexString: hex) ?? hearth.ember)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        Circle().strokeBorder(
                                            colorHex == hex ? hearth.text : hearth.hairline,
                                            lineWidth: colorHex == hex ? 2 : 1
                                        )
                                    }
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }

                TextField("", text: $note, prompt: Text("Note").font(.hearthDisplay(16, weight: .regular)), axis: .vertical)
                    .font(.hearthUI(16))
                    .foregroundStyle(hearth.text)
                    .focused($noteFocused)
                    .lineLimit(4...8)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                            .fill(hearth.bgElevated)
                            .overlay {
                                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            }
                    }

                HStack {
                    Spacer()
                    EmberButton(title: "Update Note") {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(style, colorHex, trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .background(hearth.bg)
        .onAppear { noteFocused = annotation.note?.isEmpty == false }
    }

    private var colorOptions: [String] {
        if Self.inks.contains(annotation.colorHex) {
            return Self.inks
        }
        return [annotation.colorHex] + Self.inks
    }
}

struct ReaderSearchTray: View {
    @ObservedObject var model: ClassicReaderModel

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedResult = false
    @FocusState private var fieldFocused: Bool

    private var service: EbookSearchService { model.searchService }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                TextField("", text: $query, prompt: Text("Find in this book…").font(.hearthDisplay(16, weight: .regular)))
                    .font(.hearthUI(16))
                    .foregroundStyle(hearth.text)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                        model.search(query: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.hearthUI(15))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 10)

            if service.isSearching && service.results.isEmpty {
                Spacer()
                ProgressView()
                    .tint(hearth.ember)
                Spacer()
            } else if service.results.isEmpty {
                Spacer()
                if !service.query.isEmpty {
                    Text("Nothing found for “\(service.query)”.")
                        .font(.hearthDisplay(16, weight: .regular))
                        .foregroundStyle(hearth.textSecondary)
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List(service.results) { result in
                    Button {
                        selectedResult = true
                        model.navigateTo(searchResult: result)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let chapter = result.chapterTitle, !chapter.isEmpty {
                                Overline(chapter)
                            }
                            (Text(result.contextBefore)
                                + Text(result.text).bold().foregroundStyle(hearth.ember)
                                + Text(result.contextAfter))
                                .font(.hearthDisplay(15, weight: .regular))
                                .foregroundStyle(hearth.text)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(hearth.hairline)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .onAppear {
            query = service.query
            fieldFocused = service.results.isEmpty
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            model.search(query: query)
        }
        .onDisappear {
            if !selectedResult {
                model.clearSearchDecoration()
            }
        }
    }
}
