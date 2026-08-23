import SwiftUI

struct HardcoverListsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var lists: [HardcoverUserList] = []
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Your lists")

                if !loaded {
                    HardcoverLoading()
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if lists.isEmpty {
                    HardcoverEmpty(
                        glyph: "list.bullet.rectangle",
                        title: "No lists yet.",
                        line: "Lists are made on hardcover.app and read here."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(lists) { list in
                            NavigationLink {
                                HardcoverListBooksScreen(list: list)
                            } label: {
                                HardcoverListRow(list: list)
                            }
                            .buttonStyle(PressableStyle())
                            if list.id != lists.last?.id {
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
        .task { await hardcoverLoadLists() }
        .refreshable { await hardcoverLoadLists() }
    }

    private func hardcoverLoadLists() async {
        loadError = nil
        do {
            lists = try await HardcoverService.shared.getUserLists()
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}

struct HardcoverListBooksScreen: View {
    let list: HardcoverUserList

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var books: [HardcoverListBook] = []
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(
                    overline: list.isPublic ? "Public list" : "Private list",
                    title: list.name,
                    line: list.description
                )

                if !loaded {
                    HardcoverLoading()
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if books.isEmpty {
                    HardcoverEmpty(glyph: "books.vertical", title: "An empty shelf.", line: "Add books to this list on hardcover.app.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(books) { book in
                            hardcoverListBookRow(book)
                            if book.id != books.last?.id {
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
        .task { await hardcoverLoadBooks() }
        .refreshable { await hardcoverLoadBooks() }
    }

    private func hardcoverListBookRow(_ book: HardcoverListBook) -> some View {
        NavigationLink {
            HardcoverBookDetailScreen(bookId: book.bookId, bookTitle: book.title)
        } label: {
            HStack(spacing: 14) {
                HardcoverCoverThumb(urlString: book.coverUrl)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthDisplay(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
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

    private func hardcoverLoadBooks() async {
        loadError = nil
        do {
            books = try await HardcoverService.shared.getListBooks(listId: list.id)
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}
