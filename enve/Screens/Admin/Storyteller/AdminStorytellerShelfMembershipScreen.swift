import SwiftUI

struct AdminStorytellerShelfMembershipScreen: View {
    let connection: ServerConnection
    let parent: AdminStorytellerModel
    let shelf: StorytellerShelf

    @Environment(\.hearth) private var hearth
    @State private var model: AdminStorytellerShelfMembershipModel
    @State private var search = ""

    private let maximumVisibleBooks = 50

    init(
        connection: ServerConnection,
        parent: AdminStorytellerModel,
        shelf: StorytellerShelf
    ) {
        self.connection = connection
        self.parent = parent
        self.shelf = shelf
        _model = State(initialValue: AdminStorytellerShelfMembershipModel(shelf: shelf))
    }

    private var selectedIds: Set<String> {
        Set(model.orderedBookIds)
    }

    private var matchingBooks: [StorytellerManagementBook] {
        let available = model.books.filter { !selectedIds.contains($0.id) }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return available }
        return available.filter { $0.searchText.localizedCaseInsensitiveContains(needle) }
    }

    private var visibleBooks: [StorytellerManagementBook] {
        Array(matchingBooks.prefix(maximumVisibleBooks))
    }

    var body: some View {
        AdminSubScreen(overline: "Storyteller shelf", title: shelf.name) {
            saveHeader

            if shelf.hasFilter {
                SourcesCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(hearth.ember)
                        Text("This smart shelf keeps matching books automatically. Books added here stay pinned alongside those matches.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            }

            if model.isLoading && !model.hasLoaded {
                AdminLoadingRow("Loading Storyteller books…")
            } else if model.hasLoaded {
                selectedSection
                availableSection
            }
        }
        .task {
            await model.load(connection: connection)
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private var saveHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.orderedBookIds.count) \(model.orderedBookIds.count == 1 ? "book" : "books")")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(model.hasChanges ? "Unsaved changes" : "Up to date")
                    .font(.hearthCaption)
                    .foregroundStyle(model.hasChanges ? hearth.ember : hearth.textSecondary)
            }
            Spacer()
            EmberButton(
                title: model.isSaving ? "Saving" : "Save",
                systemImage: model.isSaving ? nil : "checkmark"
            ) {
                Task { await model.save(connection: connection, parent: parent) }
            }
            .disabled(!model.hasChanges || model.isSaving)
            .opacity(!model.hasChanges || model.isSaving ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        Overline("On this shelf")
        if model.orderedBookIds.isEmpty {
            SourcesCard {
                AdminEmptyText("No pinned books. Add books below to build this shelf.")
            }
        } else {
            LazyVStack(spacing: 12) {
                ForEach(Array(model.orderedBookIds.enumerated()), id: \.element) { index, bookId in
                    selectedBookCard(bookId: bookId, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        Overline("Add books")
        searchField
        if matchingBooks.isEmpty {
            SourcesCard {
                AdminEmptyText(
                    search.isEmpty
                        ? "Every available Storyteller book is already pinned."
                        : "No available books match this search."
                )
            }
        } else {
            if matchingBooks.count > visibleBooks.count {
                Text("Showing \(visibleBooks.count) of \(matchingBooks.count). Refine the search to see more.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            LazyVStack(spacing: 12) {
                ForEach(visibleBooks) { book in
                    availableBookCard(book)
                }
            }
        }
    }

    private func selectedBookCard(bookId: String, index: Int) -> some View {
        let book = model.book(for: bookId)
        return SourcesCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book?.title ?? bookId)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = book?.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                moveButton(
                    systemImage: "arrow.up",
                    label: "Move up",
                    disabled: index == model.orderedBookIds.startIndex
                ) {
                    model.move(bookId: bookId, offset: -1)
                }
                moveButton(
                    systemImage: "arrow.down",
                    label: "Move down",
                    disabled: index == model.orderedBookIds.index(before: model.orderedBookIds.endIndex)
                ) {
                    model.move(bookId: bookId, offset: 1)
                }
                Button {
                    model.remove(bookId: bookId)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.hearthUI(19))
                        .foregroundStyle(hearth.statusError)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Remove \(book?.title ?? "book")")
            }
        }
    }

    private func availableBookCard(_ book: StorytellerManagementBook) -> some View {
        SourcesCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    model.add(book)
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.ember)
                        .frame(minHeight: 40)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func moveButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(disabled ? hearth.textTertiary : hearth.textSecondary)
                .frame(width: 32, height: 36)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Search Storyteller books", text: $search)
                .font(.hearthUI(15))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }
}
