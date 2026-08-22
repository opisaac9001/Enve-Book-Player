import SwiftUI

struct DiscoverScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var trending: [DiscoverBook] = []
    @State private var bestsellers: [DiscoverBook] = []
    @State private var newReleases: [DiscoverBook] = []
    @State private var libraryKeys: Set<String> = []
    @State private var loadError: String?
    @State private var loaded = false

    private var hasAnything: Bool {
        !trending.isEmpty || !bestsellers.isEmpty || !newReleases.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                DiscoverScreenHeader(
                    overline: "The wider world",
                    title: "Discover",
                    line: "What other readers are listening to."
                )

                if !loaded {
                    DiscoverPlaceholderShelf(title: "Trending")
                    DiscoverPlaceholderShelf(title: "Bestsellers")
                    DiscoverPlaceholderShelf(title: "Fresh releases")
                } else if hasAnything {
                    if !trending.isEmpty {
                        discoverShelf(title: "Trending", books: trending, sectionId: "trending")
                    }
                    if !bestsellers.isEmpty {
                        discoverShelf(title: "Bestsellers", books: bestsellers, sectionId: "bestsellers")
                    }
                    if !newReleases.isEmpty {
                        discoverShelf(title: "Fresh releases", books: newReleases, sectionId: "newReleases")
                    }
                } else {
                    discoverUnreachable
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbar(.hidden, for: .navigationBar)
        .task { await discoverLoad() }
        .refreshable {
            DiscoverService.shared.clearCache()
            await discoverLoad()
        }
    }

    private func discoverShelf(title: String, books: [DiscoverBook], sectionId: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Overline(title)
                Spacer()
                NavigationLink {
                    DiscoverSeeAllScreen(
                        section: DiscoverSection(id: sectionId, title: title, icon: "sparkles", books: books)
                    )
                } label: {
                    Text("See all")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(books) { book in
                        NavigationLink {
                            DiscoverDetailScreen(discoverBook: book)
                        } label: {
                            DiscoverCard(book: book, isInLibrary: DiscoverLibraryLookup.contains(book, in: libraryKeys))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var discoverUnreachable: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.hearthUI(30))
                .foregroundStyle(hearth.textTertiary)
            Text("The charts are out of reach.")
                .font(.hearthDisplay(18, weight: .semibold))
                .foregroundStyle(hearth.text)
            if let loadError {
                Text(loadError)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .multilineTextAlignment(.center)
            }
            QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                loaded = false
                Task {
                    DiscoverService.shared.clearCache()
                    await discoverLoad()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }

    private func discoverLoad() async {
        loadError = nil

        async let trendingReq = try? DiscoverService.shared.fetchTrending()
        async let bestsellersReq = try? DiscoverService.shared.fetchBestsellers()
        async let newReleasesReq = try? DiscoverService.shared.fetchNewReleases()
        async let keysReq = engine.library.titleAuthorPairs()

        let (t, b, n, pairs) = await (trendingReq, bestsellersReq, newReleasesReq, keysReq)
        trending = t ?? []
        bestsellers = b ?? []
        newReleases = n ?? []
        libraryKeys = DiscoverLibraryLookup.keys(from: pairs)

        if !hasAnything {
            loadError = "Nothing arrived. Pull down to try again."
        }
        loaded = true
    }
}
