import SwiftUI

struct LibraryGridView_tvOS: View {
    enum Filter {
        case all
        case audiobooks
        case ebooks
        case library(id: String, providerId: UUID)
    }

    let filter: Filter
    let title: String

    @Environment(AppState.self) private var appState
    @Environment(LibraryCatalogCoordinator.self) private var catalog
    @State private var books: [Book] = []
    @State private var isLoading = true
    @State private var selectedBook: BookRoute_tvOS?
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 280), spacing: 32)
    ]

    var body: some View {
        ScrollView(.vertical) {
            if isLoading || catalog.isRefreshing {
                loadingState
            } else if books.isEmpty {
                emptyState
            } else if filteredBooks.isEmpty {
                noResultsState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                    ForEach(filteredBooks, id: \.stableId) { book in
                        BookCard_tvOS(book: book) {
                            selectedBook = BookRoute_tvOS(book: book)
                        }
                    }
                }
                .padding(60)
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search by title, author, or narrator")
        .navigationDestination(item: $selectedBook) { route in
            BookDetailView_tvOS(book: route.book)
        }
        .task {
            await loadBooks()
        }

        .onChange(of: catalog.isRefreshing) { _, refreshing in
            if !refreshing {
                Task { await loadBooks() }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
            Text(catalog.isRefreshing ? "Loading your library…" : "Loading…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(appState.providerConnections.connections.isEmpty ? "No servers connected" : "No books found")
                .font(.title2.weight(.semibold))
            Text(emptyMessage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
            if !appState.providerConnections.connections.isEmpty {
                Button {
                    Task { await catalog.refreshLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var emptyMessage: String {
        if appState.providerConnections.connections.isEmpty {
            return "Add a server in Settings, or turn on \"Sync to Apple TV\" in enve on your iPhone."
        }
        switch filter {
        case .audiobooks:
            return "This library has no audiobooks, or it's still loading. Try Refresh."
        case .ebooks:
            return "This library has no ebooks."
        case .all, .library:
            return "Nothing here yet. Try Refresh."
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No results")
                .font(.title2.weight(.semibold))
            Text("Nothing matches \"\(searchText)\".")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var filteredBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }
        return books.filter { book in
            book.title.localizedCaseInsensitiveContains(query)
                || (book.author?.localizedCaseInsensitiveContains(query) ?? false)
                || (book.narrator?.localizedCaseInsensitiveContains(query) ?? false)
                || (book.series?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func loadBooks() async {
        isLoading = true
        let store = AppState.shared.bookStore
        let pageSize = 400
        var loaded: [Book] = []

        func publish() {
            books = loaded.sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            isLoading = false
        }

        switch filter {
        case .all, .audiobooks, .ebooks:
            let mediaTypes: [String?]
            switch filter {
            case .audiobooks: mediaTypes = ["audiobook", "podcast"]
            case .ebooks: mediaTypes = ["ebook"]
            default: mediaTypes = [nil]
            }
            for mediaType in mediaTypes {
                var cursor: Book?
                while true {
                    let page = await store.pagedBooks(after: cursor, limit: pageSize, mediaType: mediaType)
                    guard !page.isEmpty else { break }
                    loaded.append(contentsOf: page)
                    cursor = page.last
                    publish()
                    await Task.yield()
                    if page.count < pageSize { break }
                }
            }
        case .library(let id, let providerId):
            var cursor: Book?
            while true {
                let page = await store.pagedBooks(libraryId: id, providerId: providerId, after: cursor, limit: pageSize)
                guard !page.isEmpty else { break }
                loaded.append(contentsOf: page)
                cursor = page.last
                publish()
                await Task.yield()
                if page.count < pageSize { break }
            }
        }
        publish()
    }
}
