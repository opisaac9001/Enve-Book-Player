import SwiftUI

struct HardcoverLinkScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var matches: [HardcoverBookMatch] = []
    @State private var query = ""
    @State private var candidates: [Book] = []
    @State private var matchingBook: Book?
    @State private var loaded = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HardcoverScreenHeader(
                    overline: "Hardcover",
                    title: "Linked books",
                    line: "Matched pairs carry progress between the two libraries."
                )

                if !loaded {
                    HardcoverLoading()
                } else {
                    existingMatches
                    linkAnother
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await hardcoverLoadLink() }
        .onChange(of: query) { _, newValue in
            hardcoverDebouncedSearch(newValue)
        }
        .sheet(item: $matchingBook) { book in
            HardcoverBookMatchScreen(book: book)
                .enveEnvironment()
                .onDisappear { matches = SettingsManager.shared.getAllHardcoverMatches() }
        }
    }

    @ViewBuilder
    private var existingMatches: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Already linked")
            if matches.isEmpty {
                Text("No pairs yet. Link a book below and its progress travels.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(matches) { match in
                        hardcoverMatchRow(match)
                        if match.id != matches.last?.id {
                            Rectangle().fill(hearth.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func hardcoverMatchRow(_ match: HardcoverBookMatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.ember)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.localBookTitle ?? match.localBookId)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text("↳ \(match.hardcoverBookTitle ?? "Hardcover #\(match.hardcoverBookId)")")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            GlyphButton(systemImage: "scissors", size: 36, glyphSize: 13, label: "Unlink") {
                SettingsManager.shared.removeHardcoverMatch(forLocalBookId: match.localBookId)
                matches = SettingsManager.shared.getAllHardcoverMatches()
            }
        }
        .padding(.vertical, 10)
    }

    private var linkAnother: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Link another")
            HardcoverSearchField(text: $query, placeholder: "Search your library…")
                .padding(.horizontal, 24)

            if candidates.isEmpty {
                Text("Nothing by that name here.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.stableId) { book in
                        hardcoverCandidateRow(book)
                        if book.stableId != candidates.last?.stableId {
                            Rectangle().fill(hearth.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func hardcoverCandidateRow(_ book: Book) -> some View {
        let isLinked = SettingsManager.shared.getHardcoverMatch(forLocalBookId: book.id) != nil
        return Button {
            matchingBook = book
        } label: {
            HStack(spacing: 12) {
                CoverTile(book: book, width: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isLinked {
                    Image(systemName: "link")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.statusOK)
                        .accessibilityLabel("Linked")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(11, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func hardcoverLoadLink() async {
        matches = SettingsManager.shared.getAllHardcoverMatches()
        candidates = await appState.bookStore.recentBooks(limit: 30)
        loaded = true
    }

    private func hardcoverDebouncedSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if trimmed.isEmpty {
                candidates = await appState.bookStore.recentBooks(limit: 30)
            } else {
                candidates = await appState.bookStore.searchBooks(query: trimmed, limit: 100)
            }
        }
    }
}
