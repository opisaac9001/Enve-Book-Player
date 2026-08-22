import SwiftUI

struct DetailBookOrbitShelves: View {
    let book: Book
    var includesSeries: Bool

    @Environment(\.hearth) private var hearth

    @State private var state: BookOrbitLoadState = .loading
    @State private var series: [BookOrbitRelatedEntry] = []
    @State private var byAuthor: [BookOrbitRelatedEntry] = []
    @State private var recommended: [BookOrbitRelatedEntry] = []
    @State private var headers: [String: String] = [:]

    var body: some View {
        Group {
            switch state {
            case .loading:
                note("Asking BookOrbit for related books…", color: hearth.textTertiary)
            case .unavailable:
                EmptyView()
            case .failed(let message):
                note(message, color: hearth.statusError)
            case .ready:
                if isEmpty {
                    note("BookOrbit has nothing to suggest for this book yet.", color: hearth.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 26) {
                        if includesSeries, !series.isEmpty {
                            shelf("In this series", entries: series)
                        }
                        if !byAuthor.isEmpty {
                            shelf("More by this author", entries: byAuthor)
                        }
                        if !recommended.isEmpty {
                            shelf("You might like", entries: recommended)
                        }
                    }
                }
            }
        }
        .task(id: book.stableId) { await load() }
    }

    private var isEmpty: Bool {
        (!includesSeries || series.isEmpty) && byAuthor.isEmpty && recommended.isEmpty
    }

    private func note(_ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: "BookOrbit")
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
    }

    private func shelf(_ title: String, entries: [BookOrbitRelatedEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 16) {
                    ForEach(entries) { entry in
                        BookOrbitRelatedCell(entry: entry, headers: headers, width: 104)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func load() async {
        guard let provider = BookOrbitAccess.provider(for: book) else {
            state = .unavailable
            return
        }
        headers = provider.getStreamingHeaders()

        async let seriesTask = provider.fetchSeriesBooks(bookId: book.id)
        async let authorTask = provider.fetchAuthorBooks(bookId: book.id)

        let recommendedResult: [BookOrbitProvider.RelatedBook]
        do {
            recommendedResult = try await provider.fetchRecommendations(bookId: book.id)
        } catch BookOrbitProvider.FeatureError.unavailable {
            state = .unavailable
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(BookOrbitAccess.message(for: error))
            return
        }

        let seriesResult = (try? await seriesTask) ?? []
        let authorResult = (try? await authorTask) ?? []
        let remote = seriesResult + authorResult + recommendedResult
        let local = await BookOrbitAccess.localBooks(connectionId: provider.connection.id, remoteIds: remote.map(\.id))
        guard !Task.isCancelled else { return }

        series = entries(seriesResult, local: local, provider: provider)
        byAuthor = entries(authorResult, local: local, provider: provider)
        recommended = entries(recommendedResult, local: local, provider: provider)
        state = .ready
    }

    private func entries(
        _ remote: [BookOrbitProvider.RelatedBook],
        local: [Int: Book],
        provider: BookOrbitProvider
    ) -> [BookOrbitRelatedEntry] {
        let currentId = Int(book.id)
        return remote
            .filter { $0.id != currentId }
            .map {
                BookOrbitRelatedEntry(
                    remote: $0,
                    local: local[$0.id],
                    coverURL: $0.hasCover ? provider.coverURL(bookId: $0.id) : nil
                )
            }
    }
}

private struct BookOrbitRelatedEntry: Identifiable {
    let remote: BookOrbitProvider.RelatedBook
    let local: Book?
    let coverURL: URL?

    var id: Int { remote.id }

    var title: String { remote.title ?? "Untitled" }

    var coverRatio: CGFloat { remote.isAudiobook == true ? 1.0 : 1.5 }
}

private struct BookOrbitRelatedCell: View {
    let entry: BookOrbitRelatedEntry
    let headers: [String: String]
    let width: CGFloat

    @Environment(\.hearth) private var hearth

    var body: some View {
        if let book = entry.local {
            NavigationLink {
                BookDetailScreen(book: book)
            } label: {
                ShelfCoverCell(book: book, width: width)
            }
            .buttonStyle(PressableStyle())
        } else {
            VStack(alignment: .center, spacing: 7) {
                CachedAsyncCoverImage(url: entry.coverURL, fallbackColor: "Blue", headers: headers)
                    .aspectRatio(1 / entry.coverRatio, contentMode: .fill)
                    .frame(width: width, height: width * entry.coverRatio)
                    .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
                Text(entry.title)
                    .font(.hearthUI(12, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: width, alignment: .center)
            .accessibilityLabel("\(entry.title), not in your library")
        }
    }
}
