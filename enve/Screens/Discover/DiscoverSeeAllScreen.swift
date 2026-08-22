import SwiftUI

struct DiscoverSeeAllScreen: View {
    let section: DiscoverSection

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var libraryKeys: Set<String> = []

    var body: some View {
        GeometryReader { geo in
            let contentWidth = HearthAdaptive.contentWidth(for: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DiscoverScreenHeader(overline: "Discover", title: section.title)

                    if section.books.isEmpty {
                        Text("This shelf came back empty.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                    } else {
                        LazyVGrid(
                            columns: HearthAdaptive.gridColumns(width: contentWidth, minimum: 170, maximum: 5, compactFallback: 2),
                            spacing: 24
                        ) {
                            ForEach(section.books) { book in
                                NavigationLink {
                                    DiscoverDetailScreen(discoverBook: book)
                                } label: {
                                    DiscoverGridCell(book: book, isInLibrary: DiscoverLibraryLookup.contains(book, in: libraryKeys))
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .hearthBackBar()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            let pairs = await engine.library.titleAuthorPairs()
            libraryKeys = DiscoverLibraryLookup.keys(from: pairs)
        }
    }
}

private struct DiscoverGridCell: View {
    let book: DiscoverBook
    let isInLibrary: Bool

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            GeometryReader { geo in
                DiscoverArtTile(book: book, width: geo.size.width, isInLibrary: isInLibrary)
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .center, spacing: 2) {
                Text(LibraryDisplayFormatter.displayTitle(book.title))
                    .font(.hearthDisplay(14, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(book.author)
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
