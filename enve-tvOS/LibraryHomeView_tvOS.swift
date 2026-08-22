import SwiftUI

struct LibraryHomeView_tvOS: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryCatalogCoordinator.self) private var catalog
    @Environment(PlayerViewModel.self) private var playerVM
    @State private var recentlyPlayed: [Book] = []
    @State private var recentlyAdded: [Book] = []
    @State private var selectedBook: BookRoute_tvOS?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 56) {
                    if appState.providerConnections.connections.isEmpty {
                        OnboardingPlaceholder_tvOS()
                            .padding(.top, 80)
                    } else {
                        if !recentlyPlayed.isEmpty {
                            CarouselRow_tvOS(
                                title: "Continue Listening",
                                books: recentlyPlayed,
                                onSelect: { resumePlayback($0) }
                            )
                        }
                        if !recentlyAdded.isEmpty {
                            CarouselRow_tvOS(
                                title: "Recently Added",
                                books: recentlyAdded,
                                onSelect: { selectedBook = BookRoute_tvOS(book: $0) }
                            )
                        }
                        if recentlyPlayed.isEmpty && recentlyAdded.isEmpty {
                            EmptyLibraryPlaceholder_tvOS()
                                .padding(.top, 80)
                        }
                    }
                }
                .padding(60)
            }
            .navigationTitle("enve")
            .navigationDestination(item: $selectedBook) { route in
                BookDetailView_tvOS(book: route.book)
            }
            .task {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookProgressDidChange)) { _ in
                Task { await refresh() }
            }

            .onChange(of: catalog.isRefreshing) { _, refreshing in
                if !refreshing {
                    Task { await refresh() }
                }
            }
        }
    }

    private func resumePlayback(_ book: Book) {
        playerVM.play(book: book)
    }

    private func refresh() async {
        let progressStore = BookProgressStore.shared
        recentlyPlayed = progressStore.loadRecentlyPlayed()

        recentlyAdded = await appState.bookStore.pagedBooks(offset: 0, limit: 20, mediaType: nil)
    }
}

struct CarouselRow_tvOS: View {
    let title: String
    let books: [Book]
    let onSelect: (Book) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(books, id: \.stableId) { book in
                        BookCard_tvOS(book: book) { onSelect(book) }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

struct OnboardingPlaceholder_tvOS: View {
    @State private var isShowingAddServer = false

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 96))
                .foregroundStyle(.tint)

            Text("Connect a library")
                .font(.system(size: 48, weight: .bold))

            Text(
                "Add a media server here, or open enve on your iPhone or iPad with \"Sync to Apple TV\" turned on and your servers appear automatically."
            )
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 760)

            Button {
                isShowingAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus.circle.fill")
                    .frame(minWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .fullScreenCover(isPresented: $isShowingAddServer) {
            AddServerView_tvOS()
        }
    }
}

struct EmptyLibraryPlaceholder_tvOS: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Library is empty")
                .font(.title2.weight(.semibold))
            Text("Connect a server in enve on iPhone to add books.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
