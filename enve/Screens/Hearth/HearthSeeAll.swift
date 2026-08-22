import SwiftUI

struct HearthSeeAll: Identifiable, Hashable {
    enum Kind { case reading, listening, fresh }
    let title: String
    let kind: Kind
    var id: String { title }
}

struct HearthSeeAllScreen: View {
    let destination: HearthSeeAll

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @State private var books: [Book] = []

    var body: some View {
        GeometryReader { geo in
            let contentWidth = HearthAdaptive.contentWidth(for: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("\(books.count) book\(books.count == 1 ? "" : "s")")
                        Text(destination.title)
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                    }
                    .padding(.horizontal, 24)

                    LazyVGrid(
                        columns: HearthAdaptive.gridColumns(width: contentWidth, minimum: 128, maximum: 7, compactFallback: 3),
                        spacing: 14
                    ) {
                        ForEach(books, id: \.stableId) { book in
                            NavigationLink {
                                BookDetailScreen(book: book)
                            } label: {
                                GeometryReader { geo in
                                    ShelfCoverCell(book: book, width: geo.size.width, showsProgress: destination.kind != .fresh)
                                }
                                .aspectRatio(1 / 1.5, contentMode: .fit)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        switch destination.kind {
        case .reading:
            books = await engine.library.continueReadingBooks(limit: 60)
        case .listening:
            books = await engine.library.continueListeningBooks(limit: 60)
        case .fresh:
            books = await engine.library.recentHearthBooks(limit: 60)
        }
    }
}

struct HearthDoorway<Destination: View>: View {
    let glyph: String
    let title: String
    let line: String
    @ViewBuilder var destination: () -> Destination

    @Environment(\.hearth) private var hearth

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: glyph)
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text(line)
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
