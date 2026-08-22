import Combine
import SwiftUI

struct LibraryBookGrid: View {
    let books: [Book]
    let width: CGFloat
    var columns: Int = 3
    var onBookAppear: ((Book) -> Void)? = nil
    var onHide: ((Book) -> Void)? = nil
    var workRefFor: ((Book) -> LibraryWorkRef?)? = nil
    var isDownloaded: ((Book) -> Bool)? = nil
    var isSelecting = false
    var isSelected: ((Book) -> Bool)? = nil
    var onToggleSelect: ((Book) -> Void)? = nil

    var body: some View {
        let count = HearthAdaptive.bookGridCount(width: width, preferred: columns)
        let spacing: CGFloat = HearthAdaptive.isWide(width) ? 14 : 10
        let padding = HearthAdaptive.horizontalPadding(for: width)
        let cellWidth = max((width - padding * 2 - CGFloat(count - 1) * spacing) / CGFloat(count), 44)
        let cardStyle = LibraryDisplayPreferencesStore.shared.loadBookCardStyle()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count), spacing: 10) {
            ForEach(books, id: \.uniqueId) { book in
                LibraryBookCell(
                    book: book,
                    width: cellWidth,
                    cardStyle: cardStyle,
                    workRef: workRefFor?(book),
                    isDownloaded: isDownloaded?(book) ?? false,
                    isSelecting: isSelecting,
                    isSelected: isSelected?(book) ?? false,
                    onToggleSelect: onToggleSelect,
                    onHide: onHide
                )
                .onAppear { onBookAppear?(book) }
            }
        }
        .padding(.horizontal, padding)
    }
}

struct LibraryBookCell: View {
    let book: Book
    let width: CGFloat
    var cardStyle: BookCardStyle = .standard
    var workRef: LibraryWorkRef? = nil
    var isDownloaded = false
    var isSelecting = false
    var isSelected = false
    var onToggleSelect: ((Book) -> Void)? = nil
    var onHide: ((Book) -> Void)?

    @Environment(\.hearth) private var hearth
    @Environment(EnveEngine.self) private var engine
    @State private var confirmDelete = false

    var body: some View {
        if isSelecting {
            Button {
                PlatformHaptics.selection()
                onToggleSelect?(book)
            } label: {
                cover.opacity(isSelected ? 0.85 : 1)
            }
            .buttonStyle(PressableStyle())
        } else {
            NavigationLink {
                if let workRef {
                    WorkHubScreen(workKey: workRef.key, seed: book)
                } else {
                    BookDetailScreen(book: book)
                }
            } label: {
                cover
            }
            .buttonStyle(PressableStyle())
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

    private var cover: some View {
        VStack(alignment: .center, spacing: 7) {
            coverFrame
            metadata
        }
        .frame(width: width, alignment: .top)
        .contentShape(Rectangle())
    }

    private var coverFrame: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            CoverTile(book: book, width: artworkWidth, showsProgress: true)
                .overlay(alignment: .topLeading) {
                    if isSelecting {
                        LibrarySelectionCircle(isSelected: isSelected)
                            .padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let workRef {
                        LibraryClusterBadge(count: workRef.count)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.hearthUI(15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(7)
                            .accessibilityLabel("Downloaded")
                    }
                }
        }
        .frame(width: width, height: width, alignment: .bottom)
    }

    private var artworkWidth: CGFloat {
        width / book.hearthCoverRatio
    }

    @ViewBuilder
    private var metadata: some View {
        switch cardStyle {
        case .coverOnly:
            EmptyView()
        case .compact:
            Text(LibraryDisplayFormatter.displayTitle(book.title))
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: artworkWidth, alignment: .center)
        case .standard:
            VStack(alignment: .center, spacing: 2) {
                Text(LibraryDisplayFormatter.displayTitle(book.title))
                    .font(.hearthDisplay(13, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.hearthUI(10, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: artworkWidth, alignment: .center)
        }
    }
}

struct LibrarySeriesFan: View {
    let books: [Book]
    var coverWidth: CGFloat = 38
    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack {
            if books.isEmpty {
                placeholder
            }
            ForEach(Array(books.prefix(3).enumerated()).reversed(), id: \.element.uniqueId) { index, book in
                CoverTile(book: book, width: coverWidth, showsProgress: false, corner: 6)
                    .rotationEffect(.degrees(Double(index - 1) * 7))
                    .offset(x: CGFloat(index - 1) * coverWidth * 0.34)
            }
        }
        .frame(width: coverWidth * 2, height: coverWidth * 1.74)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hearth.bgElevated)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
            .overlay {
                Image(systemName: "books.vertical")
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textTertiary)
            }
            .frame(width: coverWidth, height: coverWidth * 1.42)
    }
}

private struct LibraryBrowseGridCard<Artwork: View>: View {
    let title: String
    let count: Int
    let status: String?
    let statusIsComplete: Bool
    let width: CGFloat
    let artwork: Artwork

    @Environment(\.hearth) private var hearth

    init(
        title: String,
        count: Int,
        status: String? = nil,
        statusIsComplete: Bool = false,
        width: CGFloat,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.title = title
        self.count = count
        self.status = status
        self.statusIsComplete = statusIsComplete
        self.width = width
        self.artwork = artwork()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            artwork
                .frame(maxWidth: .infinity, minHeight: width * 1.05, alignment: .bottom)
            Text(title)
                .font(.hearthDisplay(14, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(status ?? LibraryBrowseFormat.count(count))
                .font(.hearthCaption)
                .foregroundStyle(statusIsComplete ? hearth.statusOK : hearth.textTertiary)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct LibraryBrowseCoverArtwork: View {
    let book: Book?
    let width: CGFloat
    let systemImage: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        if let book {
            CoverTile(book: book, width: width, showsProgress: false, corner: 10)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
                .overlay {
                    Image(systemName: systemImage)
                        .font(.hearthUI(20))
                        .foregroundStyle(hearth.textTertiary)
                }
                .frame(width: width, height: width * 1.42)
        }
    }
}

struct LibrarySeriesGridCell: View {
    let aggregate: BrowseSeriesAggregate
    let mediaScope: [String]
    let width: CGFloat

    @Environment(EnveEngine.self) private var engine
    @State private var fan: [Book] = []

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Series", title: aggregate.name, fetch: fetchBooks)
        } label: {
            LibraryBrowseGridCard(
                title: aggregate.name,
                count: aggregate.bookCount,
                status: aggregate.readingStatusText,
                statusIsComplete: aggregate.unreadBookCount == 0,
                width: width
            ) {
                LibrarySeriesFan(books: fan, coverWidth: min(width * 0.48, 78))
            }
        }
        .buttonStyle(PressableStyle())
        .task(id: aggregate.name) {
            guard fan.isEmpty else { return }
            fan = await engine.library.seriesFan(for: aggregate, mediaScope: mediaScope)
        }
    }

    private func fetchBooks() async -> [Book] {
        await engine.library.books(forSeries: aggregate, mediaScope: mediaScope)
    }
}

struct LibraryAuthorGridCell: View {
    let aggregate: BrowseAuthorAggregate
    let mediaScope: [String]
    let width: CGFloat

    @Environment(EnveEngine.self) private var engine
    @State private var cover: Book?

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Author", title: aggregate.name, fetch: fetchBooks)
        } label: {
            LibraryBrowseGridCard(title: aggregate.name, count: aggregate.bookCount, width: width) {
                LibraryBrowseCoverArtwork(book: cover, width: min(width * 0.68, 104), systemImage: "person")
            }
        }
        .buttonStyle(PressableStyle())
        .task(id: aggregate.name) {
            guard cover == nil else { return }
            cover = await engine.library.coverBook(forAuthor: aggregate, mediaScope: mediaScope)
        }
    }

    private func fetchBooks() async -> [Book] {
        await engine.library.books(forAuthor: aggregate, mediaScope: mediaScope)
    }
}

struct LibraryNarratorGridCell: View {
    let aggregate: BrowseNarratorAggregate
    let mediaScope: [String]
    let width: CGFloat

    @Environment(EnveEngine.self) private var engine
    @State private var cover: Book?

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Narrator", title: aggregate.name, fetch: fetchBooks)
        } label: {
            LibraryBrowseGridCard(title: aggregate.name, count: aggregate.bookCount, width: width) {
                LibraryBrowseCoverArtwork(book: cover, width: min(width * 0.68, 104), systemImage: "person.wave.2")
            }
        }
        .buttonStyle(PressableStyle())
        .task(id: aggregate.name) {
            guard cover == nil else { return }
            cover = await engine.library.coverBook(forNarrator: aggregate, mediaScope: mediaScope)
        }
    }

    private func fetchBooks() async -> [Book] {
        await engine.library.books(forNarrator: aggregate, mediaScope: mediaScope)
    }
}

struct LibraryGenreGridCell: View {
    let aggregate: BrowseGenreAggregate
    let width: CGFloat
    let fetch: @MainActor () async -> [Book]

    @Environment(\.hearth) private var hearth

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Genre", title: aggregate.name, fetch: fetch)
        } label: {
            LibraryBrowseGridCard(title: aggregate.name, count: aggregate.bookCount, width: width) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "tag")
                            .font(.hearthUI(24, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                    }
                    .frame(width: min(width * 0.68, 104), height: min(width * 0.68, 104) * 1.42)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct LibrarySeriesRow: View {
    let aggregate: BrowseSeriesAggregate
    let mediaScope: [String]

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var fan: [Book] = []

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Series", title: aggregate.name, fetch: fetchBooks)
        } label: {
            HStack(spacing: 16) {
                LibrarySeriesFan(books: fan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(aggregate.name)
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Label(
                        aggregate.readingStatusText,
                        systemImage: aggregate.unreadBookCount == 0 ? "checkmark.circle.fill" : "book.closed"
                    )
                        .font(.hearthCaption)
                        .foregroundStyle(aggregate.unreadBookCount == 0 ? hearth.statusOK : hearth.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .buttonStyle(PressableStyle())
        .task(id: aggregate.name) {
            guard fan.isEmpty else { return }
            fan = await engine.library.seriesFan(for: aggregate, mediaScope: mediaScope)
        }
    }

    private func fetchBooks() async -> [Book] {
        await engine.library.books(forSeries: aggregate, mediaScope: mediaScope)
    }
}

struct LibraryAuthorRow: View {
    let aggregate: BrowseAuthorAggregate
    let mediaScope: [String]

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var cover: Book?

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Author", title: aggregate.name, fetch: fetchBooks)
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
            cover = await engine.library.coverBook(forAuthor: aggregate, mediaScope: mediaScope)
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
                    Image(systemName: "person")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textTertiary)
                }
                .frame(width: 44, height: 60)
        }
    }

    private func fetchBooks() async -> [Book] {
        await engine.library.books(forAuthor: aggregate, mediaScope: mediaScope)
    }
}

struct LibraryGenreRow: View {
    let aggregate: BrowseGenreAggregate
    let fetch: @MainActor () async -> [Book]

    @Environment(\.hearth) private var hearth

    var body: some View {
        NavigationLink {
            LibraryFilteredGridScreen(overline: "Genre", title: aggregate.name, fetch: fetch)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "tag")
                    .font(.hearthUI(17, weight: .semibold))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 44, height: 60)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hearth.bgElevated)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            }
                    }
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
    }
}

struct LibraryFilteredGridScreen: View {
    let overline: String
    let title: String
    let fetch: @MainActor () async -> [Book]

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @State private var books: [Book] = []

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Overline(overline)
                            Text(title)
                                .font(.hearthDisplay(28))
                                .foregroundStyle(hearth.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        LibraryPlayAllButton(playableCount: playableBooks.count) {
                            engine.playback.playAll(books, groupKey: "\(overline.lowercased()):\(title)")
                        }
                    }
                    .padding(.horizontal, 24)
                    LibraryBookGrid(
                        books: books,
                        width: geo.size.width,
                        onHide: { book in
                            LibraryModel.markHidden(book)
                            books.removeAll { $0.uniqueId == book.uniqueId }
                        }
                    )
                }
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            books = await fetch()
            for await _ in engine.library.libraryChanges() {
                books = await fetch()
            }
        }
    }

    private var playableBooks: [Book] {
        books.filter { $0.mediaType != .ebook }
    }
}

enum LibraryBrowseFormat {
    static func count(_ n: Int) -> String {
        n == 1 ? "1 book" : "\(n) books"
    }
}
