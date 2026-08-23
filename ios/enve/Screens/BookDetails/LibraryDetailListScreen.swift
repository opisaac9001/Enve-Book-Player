import SwiftUI

struct LibraryDetailListScreen: View {
    enum Scope: Hashable {
        case author(String)
        case series(String)
    }

    let scope: Scope

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var books: [Book] = []
    @State private var loaded = false

    private var overline: String {
        switch scope {
        case .author: "Author"
        case .series: "Series"
        }
    }

    private var title: String {
        switch scope {
        case let .author(name), let .series(name): name
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if loaded && books.isEmpty {
                        Text("Nothing shelved here yet.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                    } else {
                        grid(width: geo.size.width)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await load()
            loaded = true
            for await _ in engine.library.libraryChanges() {
                await load()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
            VStack(alignment: .leading, spacing: 6) {
                Overline(overline)
                Text(title)
                    .font(.hearthDisplay(28))
                    .foregroundStyle(hearth.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !books.isEmpty {
                    Text(books.count == 1 ? "One book" : "\(books.count) books")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            Spacer(minLength: 0)
            LibraryPlayAllButton(playableCount: playableBooks.count) {
                engine.playback.playAll(books, groupKey: "\(overline.lowercased()):\(title)")
            }
        }
        .padding(.horizontal, 20)
    }

    private var playableBooks: [Book] {
        books.filter { $0.mediaType != .ebook }
    }

    private func grid(width: CGFloat) -> some View {
        let cellWidth = (width - 48 - 28) / 3
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3),
            spacing: 20
        ) {
            ForEach(books, id: \.stableId) { book in
                NavigationLink {
                    BookDetailScreen(book: book)
                } label: {
                    ShelfCoverCell(book: book, width: cellWidth)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 24)
    }

    private func load() async {
        switch scope {
        case let .author(name):
            books = await engine.library.detailBooks(author: name)
        case let .series(name):
            books = await engine.library.detailBooks(series: name)
        }
    }
}
