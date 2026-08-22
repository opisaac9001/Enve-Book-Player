import SwiftUI

struct DetailSourceRecommendations: View {
    let book: Book

    @Environment(\.hearth) private var hearth

    @State private var matched: [Book] = []
    @State private var unmatchedCount = 0
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, !matched.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "You might like")
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .bottom, spacing: 16) {
                            ForEach(matched, id: \.stableId) { suggestion in
                                NavigationLink {
                                    BookDetailScreen(book: suggestion)
                                } label: {
                                    ShelfCoverCell(book: suggestion, width: 104)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .scrollIndicators(.hidden)
                    if unmatchedCount > 0 {
                        Text("\(unmatchedCount) more suggestions aren't in your library yet.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textTertiary)
                            .padding(.horizontal, 24)
                    }
                }
            }
        }
        .task(id: book.stableId) { await load() }
    }

    private func load() async {
        loaded = false
        matched = []
        unmatchedCount = 0

        let remoteIds: [String]
        switch book.source {
        case .booklore:
            guard let provider = AppState.shared.getProvider(book.providerId) as? BookloreProvider,
                let recommendations = try? await provider.fetchRecommendations(bookId: book.id)
            else { return }
            remoteIds = recommendations.map { String($0.book.id) }
        case .silo:
            guard let provider = AppState.shared.getProvider(book.providerId) as? SiloProvider,
                let similar = try? await provider.fetchSimilarItems(bookId: book.id)
            else { return }
            remoteIds = similar.map(\.mediaItemID)
        default:
            return
        }

        let candidates = remoteIds.filter { $0 != book.id }
        guard !candidates.isEmpty else {
            loaded = true
            return
        }

        let lookup = await AppState.shared.bookStore.booksByAnyIds(
            Set(candidates.map { "\(book.providerId)_\($0)" })
        )
        guard !Task.isCancelled else { return }

        matched = candidates.compactMap { lookup["\(book.providerId)_\($0)"] }
        unmatchedCount = candidates.count - matched.count
        loaded = true
    }
}
