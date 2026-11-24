#if os(iOS)
import SwiftUI

struct BookOrbitSmartScopesScreen: View {
    let connectionId: UUID

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model: BookOrbitSmartScopesModel
    @State private var detailSplit = BookDetailSplitState()

    init(connectionId: UUID) {
        self.connectionId = connectionId
        _model = State(
            initialValue: BookOrbitSmartScopesModel(
                source: BookOrbitAccess.provider(connectionId),
                localBooks: { await BookOrbitAccess.localBooks(connectionId: connectionId, remoteIds: $0) }
            )
        )
    }

    var body: some View {
        BookDetailSplit(state: detailSplit) {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        JournalScreenHeader(overline: "Saved on your server", title: "Smart scopes")
                            .padding(.horizontal, 24)
                        content(width: geo.size.width)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, mantelInset + 16)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await model.loadScopes()
                    await model.reloadBooks()
                }
            }
        }
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .accessibilityIdentifier("bookorbit-scopes-screen")
        .task { await model.loadScopes() }
        .task(id: model.search) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.searchChanged()
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch model.scopesState {
        case .loading:
            JournalLoadingNote(text: "Asking BookOrbit for its scopes…")
                .padding(.horizontal, 24)
        case .unavailable:
            BookOrbitUnavailableCard(line: "This BookOrbit server doesn't publish smart scopes. Update the server to browse them here.")
                .padding(.horizontal, 24)
        case .failed(let message):
            BookOrbitErrorCard(message: message) {
                Task { await model.loadScopes() }
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("bookorbit-scopes-error")
        case .ready:
            if let message = model.scopesRefreshError {
                notice("Couldn't refresh the scopes. \(message)", identifier: "bookorbit-scopes-refresh-error") {
                    Task { await model.loadScopes() }
                }
            }
            if model.scopes.isEmpty {
                JournalQuietNote(text: "No smart scopes are saved on this BookOrbit account yet. Create one in BookOrbit and it appears here.")
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("bookorbit-scopes-empty")
            } else {
                scopeChips
                searchField
                    .padding(.horizontal, 24)
                bookshelf(width: width)
            }
        }
    }

    private var scopeChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.scopes) { scope in
                    HearthChip(title: chipTitle(scope), isSelected: scope.id == model.selectedScopeId) {
                        PlatformHaptics.selection()
                        model.select(scopeId: scope.id)
                    }
                    .accessibilityLabel(scope.name)
                    .accessibilityValue(scope.bookCount.map { LibraryBrowseFormat.count($0) } ?? "Count unavailable")
                    .accessibilityAddTraits(scope.id == model.selectedScopeId ? .isSelected : [])
                    .accessibilityIdentifier("bookorbit-scope-\(scope.id)")
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func chipTitle(_ scope: BookOrbitProvider.SmartScope) -> String {
        scope.bookCount.map { "\(scope.name) (\($0))" } ?? scope.name
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Search this scope", text: $model.search)
                .font(.hearthUI(15))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
                .accessibilityIdentifier("bookorbit-scope-search")
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textTertiary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func bookshelf(width: CGFloat) -> some View {
        switch model.booksState {
        case .idle:
            EmptyView()
        case .loading:
            JournalLoadingNote(text: "Walking the stacks…")
                .padding(.horizontal, 24)
        case .failed(let message):
            BookOrbitErrorCard(message: message) {
                Task { await model.reloadBooks() }
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("bookorbit-scope-books-error")
        case .ready:
            if let message = model.booksRefreshError {
                notice("Couldn't refresh this scope. \(message)", identifier: "bookorbit-scope-refresh-error") {
                    Task { await model.reloadBooks() }
                }
            }
            Text(summary)
                .font(.hearthCaption.monospacedDigit())
                .foregroundStyle(hearth.textTertiary)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("bookorbit-scope-summary")
            if model.books.isEmpty {
                JournalQuietNote(text: model.search.isEmpty ? "No books match this scope right now." : "Nothing in this scope answers to that name.")
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("bookorbit-scope-books-empty")
            } else {
                LibraryBookGrid(
                    books: model.books,
                    width: width,
                    onBookAppear: { book in
                        guard book.uniqueId == model.books.last?.uniqueId else { return }
                        Task { await model.loadMore() }
                    },
                    onOpen: detailSplit.openHandler
                )
                pageFooter
            }
        }
    }

    private var summary: String {
        model.books.count < model.total
            ? "\(model.books.count) of \(LibraryBrowseFormat.count(model.total)) loaded"
            : LibraryBrowseFormat.count(model.total)
    }

    @ViewBuilder
    private var pageFooter: some View {
        if model.isLoadingMore {
            JournalLoadingNote(text: "Turning the page…")
                .frame(maxWidth: .infinity)
        } else if let message = model.pageError {
            BookOrbitErrorCard(message: message) {
                Task { await model.loadMore(retry: true) }
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("bookorbit-scope-page-error")
        } else if model.hasMore {
            QuietButton(title: "Load more", systemImage: "arrow.down") {
                Task { await model.loadMore() }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("bookorbit-scope-load-more")
        }
    }

    private func notice(_ text: String, identifier: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text)
                .font(.hearthUI(13))
                .foregroundStyle(hearth.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .font(.hearthUI(13, weight: .medium))
                .tint(hearth.ember)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
#endif
