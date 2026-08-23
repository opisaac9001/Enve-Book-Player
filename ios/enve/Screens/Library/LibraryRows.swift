import SwiftUI

struct LibraryBookContextMenu: View {
    let book: Book
    var onHide: ((Book) -> Void)?
    var onDelete: ((Book) -> Void)?

    @Environment(EnveEngine.self) private var engine

    var body: some View {
        Button {
            PlatformHaptics.impact(.light)
            engine.playback.play(book)
        } label: {
            Label(
                book.mediaType == .ebook ? "Read" : "Play",
                systemImage: book.mediaType == .ebook ? "book" : "play.fill"
            )
        }
        if book.mediaType != .ebook {
            Button {
                PlatformHaptics.impact(.light)
                engine.playback.addNext(book)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button {
                PlatformHaptics.impact(.light)
                engine.playback.addLast(book)
            } label: {
                Label("Add to Up Next", systemImage: "text.append")
            }
        }
        if LibraryBookActions.isDownloaded(book) {
            if book.source != .local {
                Button(role: .destructive) {
                    LibraryBookActions.removeDownload(book)
                } label: {
                    Label("Remove download", systemImage: "arrow.down.circle.dotted")
                }
            }
        } else if book.source != .local {
            Button {
                Task { await engine.downloads.download(book) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        Button {
            _ = engine.library.toggleFinished(book)
        } label: {
            Label(
                book.isFinished ? "Mark unfinished" : "Mark finished",
                systemImage: book.isFinished ? "circle" : "checkmark.circle"
            )
        }
        if onHide != nil || (book.source == .local && onDelete != nil) {
            Divider()
        }
        if let onHide {
            Button(role: .destructive) {
                onHide(book)
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
        if book.source == .local, let onDelete {
            Button(role: .destructive) {
                onDelete(book)
            } label: {
                Label("Delete from library", systemImage: "trash")
            }
        }
    }
}

struct LibraryPlayAllButton: View {
    let playableCount: Int
    let action: () -> Void

    var body: some View {
        QuietButton(title: "Play All", systemImage: "play.fill") {
            PlatformHaptics.impact(.light)
            action()
        }
        .disabled(playableCount == 0)
        .opacity(playableCount == 0 ? 0.45 : 1)
        .accessibilityHint(
            playableCount == 1
                ? "Plays the available audiobook"
                : "Plays \(playableCount) available audiobooks in order"
        )
    }
}

struct LibrarySelectionCircle: View {
    let isSelected: Bool
    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? hearth.ember : Color.black.opacity(0.32))
                .frame(width: 26, height: 26)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.hearthUI(12, weight: .bold))
                    .foregroundStyle(hearth.readableOnEmber)
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            }
        }
    }
}

struct LibraryWorkRef: Equatable {
    let key: String
    let count: Int
}

struct LibraryClusterBadge: View {
    let count: Int
    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.hearthUI(8))
            Text("\(count)")
                .font(.hearthUI(10, weight: .semibold))
        }
        .foregroundStyle(hearth.readableOnEmber)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(hearth.ember))
    }
}

struct LibraryBookRow: View {
    let book: Book
    var workRef: LibraryWorkRef? = nil
    var isDownloaded = false
    var isSelecting = false
    var isSelected = false
    var onToggleSelect: ((Book) -> Void)? = nil
    var onHide: ((Book) -> Void)? = nil

    @Environment(\.hearth) private var hearth
    @Environment(EnveEngine.self) private var engine
    @State private var confirmDelete = false

    var body: some View {
        if isSelecting {
            Button {
                PlatformHaptics.selection()
                onToggleSelect?(book)
            } label: {
                rowContent
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityHint("Double tap to change selection")
        } else {
            NavigationLink {
                if let workRef {
                    WorkHubScreen(workKey: workRef.key, seed: book)
                } else {
                    BookDetailScreen(book: book)
                }
            } label: {
                rowContent
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Double tap to view details")
            .contextMenu {
                LibraryBookContextMenu(
                    book: book,
                    onHide: onHide,
                    onDelete: { _ in confirmDelete = true }
                )
            }
            .alert("Delete local book?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    engine.library.permanentlyDelete(book)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes \"\(book.title)\" from Enve and deletes its imported files from this device.")
            }
        }
    }

    private var accessibilityLabel: String {
        var details = [book.title]
        if let author = book.author, !author.isEmpty {
            details.append(author)
        }
        let progress = LibraryBookActions.progressFraction(book)
        if book.isFinished {
            details.append("Finished")
        } else if progress > 0.001 {
            details.append("\(Int((progress * 100).rounded())) percent complete")
        }
        if isDownloaded {
            details.append("Downloaded")
        }
        if let workRef, workRef.count > 1 {
            details.append("\(workRef.count) matching copies")
        }
        return details.joined(separator: ", ")
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            if isSelecting {
                LibrarySelectionCircle(isSelected: isSelected)
            }
            ShelfCoverCell(book: book, width: 46, showsProgress: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.hearthDisplay(16, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
                let fraction = LibraryBookActions.progressFraction(book)
                if fraction > 0.001, !book.isFinished {
                    Ribbon(progress: fraction, tint: hearth.ember)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if let workRef {
                LibraryClusterBadge(count: workRef.count)
            }
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textTertiary)
                    .accessibilityLabel("Downloaded")
            }
            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .opacity(isSelecting && isSelected ? 0.85 : 1)
    }
}

struct LibraryNarratorRow: View {
    let aggregate: BrowseNarratorAggregate
    let mediaScope: [String]

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var cover: Book?

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Narrator", title: aggregate.name, fetch: fetchBooks)
        } label: {
            HStack(spacing: 16) {
                thumb
                VStack(alignment: .leading, spacing: 3) {
                    Text(aggregate.name)
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(LibraryBrowseFormat.count(aggregate.bookCount))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .buttonStyle(PressableStyle())
        .task(id: aggregate.name) {
            guard cover == nil else { return }
            cover = await engine.library.coverBook(forNarrator: aggregate, mediaScope: mediaScope)
        }
    }

    @ViewBuilder
    private var thumb: some View {
        if let cover {
            CoverTile(book: cover, width: 44, showsProgress: false, corner: 8)
                .frame(width: 44, height: 66, alignment: .bottom)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
                .overlay {
                    Image(systemName: "person.wave.2")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textTertiary)
                }
                .frame(width: 44, height: 60)
        }
    }

    private func fetchBooks() async -> [Book] {
        await engine.library.books(forNarrator: aggregate, mediaScope: mediaScope)
    }
}

struct LibraryShowRow: View {
    let show: AudiobookshelfProvider.PodcastShow
    @Environment(\.hearth) private var hearth

    var body: some View {
        let showBook = PodcastsModel.shared.showBook(for: show)
        NavigationLink {
            PodcastShowScreen(show: showBook)
        } label: {
            HStack(spacing: 16) {
                CoverTile(book: showBook, width: 46, showsProgress: false, corner: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.title)
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(show.episodes.count == 1 ? "1 episode" : "\(show.episodes.count) episodes")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct LibrarySelectionBar: View {
    let model: LibraryModel
    let onAddToCollection: ([Book]) -> Void
    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.selectedIds.count) chosen")
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Button {
                    PlatformHaptics.selection()
                    model.toggleSelectionScope()
                } label: {
                    Text(model.selectionScopeTitle)
                        .font(.hearthUI(12, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(minHeight: 24)
                }
            }
            Spacer(minLength: 8)
            librarySelectionGlyph(
                "play.fill",
                label: "Play selected",
                isEnabled: model.hasPlayableSelection
            ) {
                model.playSelected()
            }
            librarySelectionGlyph("arrow.down.circle", label: "Download") {
                model.downloadSelected()
            }
            librarySelectionGlyph("folder.badge.plus", label: "Add selected to a shelf") {
                onAddToCollection(model.selectedBooks)
            }
            selectionMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background {
            HearthChromeBackground(
                shape: .rounded(22),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                shadow: true
            )
        }
        .padding(.horizontal, 20)
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                model.queueSelected()
            } label: {
                Label("Add to Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(!model.hasPlayableSelection)

            Button {
                model.removeSelectedDownloads()
            } label: {
                Label("Remove downloads", systemImage: "arrow.down.circle.dotted")
            }

            Button {
                model.markSelectedFinished()
            } label: {
                Label("Mark finished", systemImage: "checkmark.circle")
            }

            Button(role: .destructive) {
                model.hideSelected()
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.hearthUI(17, weight: .medium))
                .foregroundStyle(model.selectedIds.isEmpty ? hearth.textTertiary : hearth.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(model.selectedIds.isEmpty)
        .accessibilityLabel("More actions for selected books")
    }

    private func librarySelectionGlyph(
        _ systemImage: String,
        label: String,
        isEnabled: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let enabled = isEnabled ?? !model.selectedIds.isEmpty
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(17, weight: .medium))
                .foregroundStyle(enabled ? hearth.text : hearth.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
