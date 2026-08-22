import SwiftUI

struct HardcoverReverseMatchScreen: View {
    let hardcoverBook: HardcoverUserBookLegacy

    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var ebooksOnly: Bool?
    @State private var candidates: [Book] = []
    @State private var selected: Book?
    @State private var isWorking = false
    @State private var loaded = false
    @State private var searchTask: Task<Void, Never>?

    private var filtered: [Book] {
        guard let ebooksOnly else { return candidates }
        return candidates.filter { ($0.mediaType == .ebook) == ebooksOnly }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hardcoverMatchSheetHeader(
                        hearth: hearth,
                        title: "Match to your library",
                        line: "Pick the copy of this book that lives here."
                    ) { dismiss() }

                    HardcoverCard {
                        HStack(spacing: 14) {
                            HardcoverCoverThumb(urlString: hardcoverBook.book.image?.url, width: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Overline("On Hardcover")
                                Text(hardcoverBook.book.title)
                                    .font(.hearthDisplay(16, weight: .semibold))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                Text(hardcoverBook.book.authorDisplay)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        HardcoverSearchField(text: $query, placeholder: "Search your library…")
                        HStack(spacing: 10) {
                            HearthChip(title: "All", isSelected: ebooksOnly == nil) { ebooksOnly = nil }
                            HearthChip(title: "Audio", isSelected: ebooksOnly == false) { ebooksOnly = false }
                            HearthChip(title: "Ebooks", isSelected: ebooksOnly == true) { ebooksOnly = true }
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 24)

                    if !loaded {
                        HardcoverLoading()
                    } else if filtered.isEmpty {
                        HardcoverEmpty(
                            glyph: "magnifyingglass",
                            title: "No likely copies.",
                            line: "Search by title or author to look further."
                        )
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered, id: \.stableId) { book in
                                HardcoverLocalBookPickRow(
                                    book: book,
                                    isSelected: selected?.stableId == book.stableId,
                                    isAlreadyMatched: SettingsManager.shared.getHardcoverMatch(forLocalBookId: book.id) != nil
                                ) {
                                    selected = book
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            hardcoverMatchSheetFooter(hearth: hearth) {
                EmberButton(title: isWorking ? "Matching…" : "Keep this match", systemImage: "link") {
                    guard !isWorking, selected != nil else { return }
                    Task { await hardcoverCreateMatch() }
                }
                .disabled(selected == nil || isWorking)
                .opacity(selected == nil ? 0.5 : 1)
            }
        }
        .hearthPresentationBackground()
        .task { await hardcoverLoadDefaults() }
        .onChange(of: query) { _, newValue in
            hardcoverDebouncedSearch(newValue)
        }
    }

    private func hardcoverLoadDefaults() async {

        candidates = await appState.bookStore.recentBooks(limit: 60)
        loaded = true
    }

    private func hardcoverDebouncedSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if trimmed.isEmpty {
                candidates = await appState.bookStore.recentBooks(limit: 60)
            } else {
                candidates = await appState.bookStore.searchBooks(query: trimmed, limit: 100)
            }
        }
    }

    private func hardcoverCreateMatch() async {
        guard let localBook = selected else { return }
        isWorking = true

        var pageCount: Int?
        if let editionId = hardcoverBook.editionId {
            pageCount = (try? await HardcoverService.shared.getEditionDetails(editionId: editionId))?.pages
        }

        let match = HardcoverBookMatch(
            localBookId: localBook.id,
            hardcoverBookId: hardcoverBook.book.id,
            hardcoverUserBookId: hardcoverBook.id,
            hardcoverEditionId: hardcoverBook.editionId,
            editionPageCount: pageCount,
            matchType: .manual,
            localBookTitle: localBook.title,
            hardcoverBookTitle: hardcoverBook.book.title
        )
        SettingsManager.shared.addHardcoverMatch(match)
        PlatformHaptics.notification(.success)
        dismiss()
    }
}

struct HardcoverBookMatchScreen: View {
    let book: Book

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var shelfBooks: [HardcoverUserBookLegacy] = []
    @State private var selected: HardcoverUserBookLegacy?
    @State private var loadError: String?
    @State private var isWorking = false
    @State private var loaded = false

    private var filtered: [HardcoverUserBookLegacy] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return shelfBooks }
        return shelfBooks.filter {
            $0.book.title.lowercased().contains(trimmed) || $0.book.authorDisplay.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hardcoverMatchSheetHeader(
                        hearth: hearth,
                        title: "Match to Hardcover",
                        line: "Pick this book's place on your shelf there."
                    ) { dismiss() }

                    HardcoverCard {
                        HStack(spacing: 14) {
                            CoverTile(book: book, width: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Overline(book.mediaType == .ebook ? "Your ebook" : "Your audiobook")
                                Text(book.title)
                                    .font(.hearthDisplay(16, weight: .semibold))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                if let author = book.author {
                                    Text(author)
                                        .font(.hearthCaption)
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    HardcoverSearchField(text: $query, placeholder: "Search your Hardcover shelf…")
                        .padding(.horizontal, 24)

                    if !loaded {
                        HardcoverLoading(line: "Fetching your shelf.")
                    } else if let loadError {
                        HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                    } else if filtered.isEmpty {
                        HardcoverEmpty(
                            glyph: "books.vertical",
                            title: "Nothing on the shelf matches.",
                            line: "Add the book on hardcover.app first, or search differently."
                        )
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { userBook in
                                HardcoverShelfPickRow(
                                    userBook: userBook,
                                    isSelected: selected?.id == userBook.id,
                                    isAlreadyMatched: SettingsManager.shared.getHardcoverMatch(forHardcoverBookId: userBook.book.id) != nil
                                ) {
                                    selected = userBook
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            hardcoverMatchSheetFooter(hearth: hearth) {
                EmberButton(title: isWorking ? "Matching…" : "Keep this match", systemImage: "link") {
                    guard !isWorking, selected != nil else { return }
                    Task { await hardcoverCreateMatch() }
                }
                .disabled(selected == nil || isWorking)
                .opacity(selected == nil ? 0.5 : 1)
            }
        }
        .hearthPresentationBackground()
        .task { await hardcoverLoadShelf() }
    }

    private func hardcoverLoadShelf() async {
        loadError = nil
        do {
            shelfBooks = try await HardcoverService.shared.getUserBooks(limit: 200)
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func hardcoverCreateMatch() async {
        guard let hardcoverBook = selected else { return }
        isWorking = true

        var pageCount: Int?
        if let editionId = hardcoverBook.editionId {
            pageCount = (try? await HardcoverService.shared.getEditionDetails(editionId: editionId))?.pages
        }

        let match = HardcoverBookMatch(
            localBookId: book.id,
            hardcoverBookId: hardcoverBook.book.id,
            hardcoverUserBookId: hardcoverBook.id,
            hardcoverEditionId: hardcoverBook.editionId,
            editionPageCount: pageCount,
            matchType: .manual,
            localBookTitle: book.title,
            hardcoverBookTitle: hardcoverBook.book.title
        )
        SettingsManager.shared.addHardcoverMatch(match)
        PlatformHaptics.notification(.success)
        dismiss()
    }
}

private struct HardcoverLocalBookPickRow: View {
    let book: Book
    let isSelected: Bool
    let isAlreadyMatched: Bool
    let onTap: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CoverTile(book: book, width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    if isAlreadyMatched {
                        Text("Already linked")
                            .font(.hearthUI(11, weight: .medium))
                            .foregroundStyle(hearth.statusWarn)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.hearthUI(20))
                    .foregroundStyle(isSelected ? hearth.ember : hearth.textTertiary)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? hearth.emberSoft : hearth.bg)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? hearth.ember : hearth.hairline, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(isAlreadyMatched)
        .opacity(isAlreadyMatched ? 0.5 : 1)
    }
}

private struct HardcoverShelfPickRow: View {
    let userBook: HardcoverUserBookLegacy
    let isSelected: Bool
    let isAlreadyMatched: Bool
    let onTap: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                HardcoverCoverThumb(urlString: userBook.book.image?.url, width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(userBook.book.title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(userBook.book.authorDisplay)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                    if isAlreadyMatched {
                        Text("Already linked")
                            .font(.hearthUI(11, weight: .medium))
                            .foregroundStyle(hearth.statusWarn)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.hearthUI(20))
                    .foregroundStyle(isSelected ? hearth.ember : hearth.textTertiary)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? hearth.emberSoft : hearth.bg)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? hearth.ember : hearth.hairline, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(isAlreadyMatched)
        .opacity(isAlreadyMatched ? 0.5 : 1)
    }
}

@ViewBuilder
private func hardcoverMatchSheetHeader(
    hearth: HearthPalette,
    title: String,
    line: String,
    onClose: @escaping () -> Void
) -> some View {
    HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
            Overline("Hardcover")
            Text(title)
                .font(.hearthDisplay(24, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text(line)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        Spacer()
        GlyphButton(systemImage: "xmark", size: 36, glyphSize: 13, label: "Close", action: onClose)
    }
    .padding(.horizontal, 24)
}

@ViewBuilder
private func hardcoverMatchSheetFooter<Content: View>(
    hearth: HearthPalette,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(spacing: 0) {
        Rectangle().fill(hearth.hairline).frame(height: 1)
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
    }
}
