import SwiftUI

struct DetailBookmarksSection: View {
    let book: Book
    let tint: Color

    @Environment(\.hearth) private var hearth
    @State private var bookmarks: [Bookmark] = []
    @State private var annotations: [ReaderAnnotation] = []
    @State private var filter: DetailMarkFilter = .all
    @State private var query = ""

    private var marks: [DetailMark] {
        let bookmarkMarks = bookmarks.map(DetailMark.bookmark)
        let annotationMarks = annotations.map(DetailMark.annotation)
        return (bookmarkMarks + annotationMarks)
            .filter { mark in
                switch filter {
                case .all:
                    return true
                case .bookmarks:
                    return mark.kind == .bookmark
                case .highlights:
                    return mark.kind == .highlight
                case .notes:
                    return mark.kind == .note
                }
            }
            .filter { mark in
                let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { return true }
                return mark.searchText.localizedCaseInsensitiveContains(needle)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var bookmarkCount: Int { bookmarks.count }
    private var highlightCount: Int { annotations.count }
    private var noteCount: Int { annotations.filter { $0.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count }
    private var totalCount: Int { bookmarks.count + annotations.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                ShelfHeader(title: "Bookmarks & notes")
                Spacer()
                Text("\(totalCount)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("\(bookmarkCount) bookmarks · \(highlightCount) highlights · \(noteCount) notes")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DetailMarkFilter.allCases) { item in
                            HearthChip(title: item.title, isSelected: filter == item) {
                                withAnimation(.smooth(duration: 0.2)) { filter = item }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                TextField("Search marks", text: $query)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.hearthUI(15))
                    .foregroundStyle(hearth.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .fill(hearth.bgElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            )
                    }

                if totalCount == 0 {
                    emptyText("Bookmarks, highlights, and notes from the reader or player will appear here.")
                } else if marks.isEmpty {
                    emptyText("No marks match this view.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(marks) { mark in
                            markRow(mark)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
        .task(id: book.stableId) { load() }
    }

    private func markRow(_ mark: DetailMark) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(mark.kind == .highlight ? tint.opacity(0.18) : hearth.bg)
                    .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                Text(mark.kind.initial)
                    .font(.hearthUI(13, weight: .bold))
                    .foregroundStyle(mark.kind == .highlight ? hearth.text : tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mark.kind.title)
                        .font(.hearthCaption.weight(.semibold))
                        .foregroundStyle(hearth.ember)
                    Spacer(minLength: 8)
                    Text(relativeDate(mark.updatedAt))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }

                if !mark.primaryText.isEmpty {
                    Text(mark.primaryText)
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let note = mark.note, !note.isEmpty {
                    Text(note)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(mark.locationLabel)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.hearthUI(15))
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func load() {
        var marks = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
        var notes = ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
        if book.stableId != book.id {
            let seenMarks = Set(marks.map(\.id))
            marks += ReaderArtifactsStore.shared.loadBookmarks(bookId: book.id).filter { !seenMarks.contains($0.id) }
            let seenNotes = Set(notes.map(\.id))
            notes += ReaderArtifactsStore.shared.loadAnnotations(bookId: book.id).filter { !seenNotes.contains($0.id) }
        }
        bookmarks = marks.sorted { $0.position < $1.position }
        annotations =
            notes
            .sorted { $0.position < $1.position }
    }
}

private enum DetailMarkFilter: CaseIterable, Identifiable {
    case all
    case bookmarks
    case highlights
    case notes

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .bookmarks: "Bookmarks"
        case .highlights: "Highlights"
        case .notes: "Notes"
        }
    }
}

private enum DetailMarkKind {
    case bookmark
    case highlight
    case note

    var title: String {
        switch self {
        case .bookmark: "Bookmark"
        case .highlight: "Highlight"
        case .note: "Note"
        }
    }

    var initial: String {
        switch self {
        case .bookmark: "B"
        case .highlight: "H"
        case .note: "N"
        }
    }
}

private struct DetailMark: Identifiable {
    let id: String
    let kind: DetailMarkKind
    let primaryText: String
    let note: String?
    let locationLabel: String
    let searchText: String
    let updatedAt: Date

    static func bookmark(_ bookmark: Bookmark) -> DetailMark {
        let location = bookmark.chapterTitle ?? bookmark.title
        let position =
            bookmark.mediaType == .ebook
            ? "\(Int((bookmark.position * 100).rounded()))%"
            : HearthFormat.duration(bookmark.position)
        let note = bookmark.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DetailMark(
            id: "bookmark-\(bookmark.id)",
            kind: .bookmark,
            primaryText: location,
            note: note?.isEmpty == false ? note : nil,
            locationLabel: position,
            searchText: [location, note, position].compactMap(\.self).joined(separator: " "),
            updatedAt: bookmark.timestamp
        )
    }

    static func annotation(_ annotation: ReaderAnnotation) -> DetailMark {
        let note = annotation.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: DetailMarkKind = note?.isEmpty == false ? .note : .highlight
        let location = annotation.chapterTitle ?? "\(Int((annotation.position * 100).rounded()))%"
        return DetailMark(
            id: "annotation-\(annotation.id)",
            kind: kind,
            primaryText: text,
            note: note?.isEmpty == false ? note : nil,
            locationLabel: location,
            searchText: [text, note, location, annotation.style.label].compactMap(\.self).joined(separator: " "),
            updatedAt: annotation.updatedAt
        )
    }
}
