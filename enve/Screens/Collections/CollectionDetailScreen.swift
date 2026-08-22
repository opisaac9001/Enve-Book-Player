import SwiftUI

struct CollectionDetailScreen: View {
    let collection: Collection

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var books: [Book] = []
    @State private var query = ""
    @State private var loaded = false
    @State private var editorShown = false
    @State private var page = 0
    @State private var total = 0
    @State private var loadingMore = false
    @State private var pendingRemoval: Book?
    @State private var errorMessage: String?

    private var current: Collection {
        engine.library.currentCollection(for: collection)
    }

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
                    header

                    CollectionsSearchField(text: $query)
                        .padding(.horizontal, 24)

                    if !loaded {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(hearth.ember)
                            Text("Fetching the shelf.")
                                .font(.hearthBody)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        .padding(.horizontal, 24)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? "Nothing on this shelf yet." : "Nothing here answers to \u{201C}\(query)\u{201D}.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                    } else {
                        collectionsBookGrid(
                            filtered,
                            width: geo.size.width - 48,
                            onRemove: current.isServerEditable ? { pendingRemoval = $0 } : nil
                        )
                        if current.remoteId != nil, books.count < total {
                            QuietButton(title: loadingMore ? "Loading…" : "Load more", systemImage: "arrow.down") {
                                loadMore()
                            }
                            .disabled(loadingMore)
                            .frame(maxWidth: .infinity)
                        }
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
        .task(id: "\(current.id)|\(query)") {
            if current.remoteId != nil, !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await load(reset: true)
        }
        .sheet(isPresented: $editorShown) {
            if current.remoteId != nil {
                BookOrbitCollectionEditor(
                    collection: current,
                    connections: engine.library.sourceConnection(for: current).map { [$0] } ?? [],
                    onSaved: {}
                )
                .enveEnvironment()
            } else {
                CollectionsEditorSheet(collection: current)
                    .enveEnvironment()
            }
        }
        .alert(
            "Remove from collection?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let book = pendingRemoval { remove(book) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Remove \"\(pendingRemoval?.title ?? "this book")\" from \"\(current.name)\" on BookOrbit?")
        }
        .alert(
            "BookOrbit collection",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        let shown = current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline(shown.isUserGenerated ? "Your shelf" : "From the server")
                    Text(shown.name)
                        .font(.hearthScreenTitle)
                        .foregroundStyle(hearth.text)
                }
                Spacer()
                if shown.isUserGenerated || shown.isServerEditable {
                    GlyphButton(systemImage: "pencil", size: 40, label: "Edit collection") {
                        editorShown = true
                    }
                }
            }
            if let description = shown.description, !description.isEmpty {
                Text(description)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Overline(books.count == 1 ? "1 book" : "\(books.count) books", color: hearth.textTertiary)
        }
        .padding(.horizontal, 24)
    }

    private func load(reset: Bool) async {
        let shown = current
        if shown.remoteId != nil {
            if reset {
                loaded = false
                page = 0
            }
            do {
                let result = try await engine.library.bookOrbitCollectionPage(
                    shown,
                    page: page,
                    query: query.isEmpty ? nil : query
                )
                books = result.books
                total = result.total
            } catch {
                errorMessage = error.localizedDescription
            }
            loaded = true
            return
        }
        guard !shown.books.isEmpty else {
            books = []
            loaded = true
            return
        }
        books = await engine.library.books(in: shown)
        loaded = true
    }

    private func loadMore() {
        guard !loadingMore else { return }
        loadingMore = true
        Task {
            do {
                let nextPage = page + 1
                let result = try await engine.library.bookOrbitCollectionPage(
                    current,
                    page: nextPage,
                    query: query.isEmpty ? nil : query
                )
                books.append(contentsOf: result.books)
                page = nextPage
                total = result.total
            } catch {
                errorMessage = error.localizedDescription
            }
            loadingMore = false
        }
    }

    private func remove(_ book: Book) {
        Task {
            do {
                try await engine.library.removeBookOrbitBook(book, from: current)
                books.removeAll { $0.id == book.id }
                total = max(0, total - 1)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct CollectionsSmartDetailScreen: View {
    let collection: SmartCollection

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var matched: [Book] = []
    @State private var query = ""
    @State private var loaded = false
    @State private var editorShown = false

    private var current: SmartCollection {
        engine.library.currentSmartCollection(for: collection)
    }

    private var filtered: [Book] {
        guard !query.isEmpty else { return matched }
        return matched.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.author?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.narrator?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    CollectionsSearchField(text: $query)
                        .padding(.horizontal, 24)

                    if !loaded {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(hearth.ember)
                            Text("Reading the rules.")
                                .font(.hearthBody)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        .padding(.horizontal, 24)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? "Nothing matches these rules yet." : "Nothing here answers to \u{201C}\(query)\u{201D}.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                    } else {
                        collectionsBookGrid(filtered, width: geo.size.width - 48)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: BookQuery.matching(collectionId: current.id, payload: current)) {
            for await books in engine.library.observedBooks(matching: current) {
                if Task.isCancelled { break }
                matched = books
                loaded = true
            }
        }
        .sheet(isPresented: $editorShown) {
            CollectionsEditorSheet(smartCollection: current)
                .enveEnvironment()
        }
    }

    private var header: some View {
        let shown = current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline(shown.isSystem ? "Smart shelf" : "Smart shelf · yours")
                    Text(shown.name)
                        .font(.hearthScreenTitle)
                        .foregroundStyle(hearth.text)
                }
                Spacer()
                GlyphButton(systemImage: "pencil", size: 40, label: "Edit smart collection") {
                    editorShown = true
                }
            }
            if let description = shown.description, !description.isEmpty {
                Text(description)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Overline(rulesLine, color: hearth.textTertiary)
        }
        .padding(.horizontal, 24)
    }

    private var rulesLine: String {
        let shown = current
        let count = matched.count
        let books = count == 1 ? "1 book" : "\(count) books"
        let joiner = shown.rules.logicOperator == .and ? "every rule" : "any rule"
        return shown.rules.rules.isEmpty ? books : "\(books) · matching \(joiner)"
    }
}

@ViewBuilder
func collectionsBookGrid(_ books: [Book], width: CGFloat, onRemove: ((Book) -> Void)? = nil) -> some View {
    let cellWidth = max(1, (width - 32) / 3)
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16) {
        ForEach(books, id: \.stableId) { book in
            NavigationLink {
                BookDetailScreen(book: book)
            } label: {
                ShelfCoverCell(book: book, width: cellWidth)
            }
            .buttonStyle(PressableStyle())
            .contextMenu {
                if let onRemove {
                    Button(role: .destructive) {
                        onRemove(book)
                    } label: {
                        Label("Remove from collection", systemImage: "minus.circle")
                    }
                }
            }
        }
    }
    .padding(.horizontal, 24)
}

struct CollectionsSearchField: View {
    @Binding var text: String
    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Find a story\u{2026}", text: $text)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }
}
