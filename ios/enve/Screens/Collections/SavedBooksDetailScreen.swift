import SwiftUI

struct SavedBooksDetailScreen: View {
    let list: SavedBooksStore.List

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    private let savedBooks = SavedBooksStore.shared
    @State private var books: [Book] = []
    @State private var query = ""
    @State private var loaded = false
    @State private var syncError: String?

    private var filtered: [Book] {
        guard !query.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.author?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.narrator?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Overline("Saved books")
                        Text(list.title)
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                        Text(list == .favorites
                             ? "The stories you want to keep close."
                             : "Books and audiobooks to come back to.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                        Overline(books.count == 1 ? "1 book" : "\(books.count) books", color: hearth.textTertiary)
                    }
                    .padding(.horizontal, 24)

                    CollectionsSearchField(text: $query)
                        .padding(.horizontal, 24)

                    if let syncError {
                        Text(syncError)
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.statusError)
                            .padding(.horizontal, 24)
                    }

                    if !loaded {
                        ProgressView()
                            .tint(hearth.ember)
                            .padding(.horizontal, 24)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? "Nothing saved here yet. Find a book and add it from its page or menu." : "No matching books.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                    } else {
                        collectionsBookGrid(
                            filtered,
                            width: geo.size.width - 48,
                            onRemove: { book in
                                Task {
                                    await engine.library.toggleSaved(book, in: list)
                                    syncError = savedBooks.syncErrors[book.uniqueId]
                                }
                            },
                            removeLabel: "Remove from \(list.title)"
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .hearthBackBar()
        .refreshable {
            await refreshFromServers()
        }
        .task {
            await refreshFromServers()
        }
        .task(id: savedBooks.ids(in: list)) {
            let ids = savedBooks.ids(in: list)
            let loadedBooks = await engine.library.savedBooks(withUniqueIds: ids)
            guard !Task.isCancelled else { return }
            books = loadedBooks
            loaded = true
        }
    }

    private func refreshFromServers() async {
        let failed = await engine.library.refreshSavedBooks()
        guard !Task.isCancelled else { return }
        syncError = failed.isEmpty ? nil : "Couldn’t refresh saved books from \(failed.joined(separator: ", "))."
    }
}
