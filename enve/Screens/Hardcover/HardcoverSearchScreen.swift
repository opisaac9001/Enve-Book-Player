import SwiftUI

struct HardcoverSearchScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var query = ""
    @State private var searchingUsers = false
    @State private var bookResults: [HardcoverBook] = []
    @State private var userResults: [HardcoverUserSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Search")

                VStack(spacing: 14) {
                    HardcoverSearchField(
                        text: $query,
                        placeholder: searchingUsers ? "Find a reader…" : "Find a story…"
                    )
                    HStack(spacing: 10) {
                        HearthChip(title: "Books", isSelected: !searchingUsers) { hardcoverSetMode(users: false) }
                        HearthChip(title: "Readers", isSelected: searchingUsers) { hardcoverSetMode(users: true) }
                        Spacer()
                    }
                }
                .padding(.horizontal, 24)

                if isSearching {
                    HardcoverLoading(line: "Searching the stacks.")
                } else if let searchError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "The search went astray.", line: searchError)
                } else if !hasSearched {
                    HardcoverEmpty(
                        glyph: "magnifyingglass",
                        title: "All of Hardcover, one query away.",
                        line: "Books by title or author, readers by name."
                    )
                } else if searchingUsers ? userResults.isEmpty : bookResults.isEmpty {
                    HardcoverEmpty(glyph: "questionmark", title: "Nothing by that name.", line: "Try fewer words, or different ones.")
                } else if searchingUsers {
                    LazyVStack(spacing: 0) {
                        ForEach(userResults) { user in
                            hardcoverUserRow(user)
                            if user.id != userResults.last?.id {
                                Rectangle().fill(hearth.hairline).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(bookResults) { book in
                            hardcoverBookRow(book)
                            if book.id != bookResults.last?.id {
                                Rectangle().fill(hearth.hairline).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: query) { _, newValue in
            hardcoverDebounce(newValue)
        }
    }

    private func hardcoverBookRow(_ book: HardcoverBook) -> some View {
        NavigationLink {
            HardcoverBookDetailScreen(bookId: book.id, bookTitle: book.title)
        } label: {
            HStack(spacing: 14) {
                HardcoverCoverThumb(urlString: book.image?.url)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthDisplay(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(book.authorDisplay)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                    if let year = book.releaseYear {
                        Text(String(year))
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func hardcoverUserRow(_ user: HardcoverUserSearchResult) -> some View {
        HStack(spacing: 12) {
            HardcoverAvatar(urlString: user.imageURL, name: user.username)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(user.username)")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                if let name = user.name, !name.isEmpty {
                    Text(name)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                } else if let flair = user.flair, !flair.isEmpty {
                    Text(flair)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.ember)
                }
            }
            Spacer()
        }
        .padding(.vertical, 11)
    }

    private func hardcoverSetMode(users: Bool) {
        guard searchingUsers != users else { return }
        searchingUsers = users
        if !query.isEmpty { hardcoverDebounce(query) }
    }

    private func hardcoverDebounce(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bookResults = []
            userResults = []
            searchError = nil
            isSearching = false
            hasSearched = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await hardcoverSearch(trimmed)
        }
    }

    private func hardcoverSearch(_ text: String) async {
        isSearching = true
        searchError = nil
        do {
            if searchingUsers {
                userResults = try await HardcoverService.shared.searchUsers(query: text)
                bookResults = []
            } else {
                bookResults = try await HardcoverService.shared.searchBooks(query: text, limit: 25)
                userResults = []
            }
        } catch is CancellationError {
            return
        } catch {
            searchError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        hasSearched = true
        isSearching = false
    }
}
