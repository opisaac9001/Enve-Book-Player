import SwiftUI

struct WorkSuggestionsScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var suggestions: [WorkMergeSuggestion] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Review")
                    Text("Possible duplicates")
                        .font(.hearthDisplay(26))
                        .foregroundStyle(hearth.text)
                    Text("Copies that share an ISBN or ASIN but live in separate entries. Merge the ones that are the same book.")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textSecondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                if loading {
                    ProgressView().tint(hearth.ember)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if suggestions.isEmpty {
                    emptyState
                } else {
                    ForEach(suggestions) { card($0) }
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.hearthUI(34))
                .foregroundStyle(hearth.ember)
            Text("Nothing to review")
                .font(.hearthDisplay(18))
                .foregroundStyle(hearth.text)
            Text("Everything that shares an identifier is already consolidated.")
                .font(.hearthUI(13))
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 60)
    }

    private func card(_ suggestion: WorkMergeSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncCoverImage(
                    url: suggestion.representative.coverURL,
                    fallbackColor: "Blue",
                    headers: CachedAsyncCoverImage.authHeaders(for: suggestion.representative),
                    book: suggestion.representative
                )
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = suggestion.author, !author.isEmpty {
                        Text(author)
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "barcode").font(.hearthUI(9))
                        Text(suggestion.reason).font(.hearthUI(11, weight: .medium))
                    }
                    .foregroundStyle(hearth.ember)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(hearth.emberSoft))
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                ForEach(suggestion.books, id: \.uniqueId) { book in
                    HStack(spacing: 8) {
                        Image(systemName: book.mediaType == .ebook ? "book.closed.fill" : "headphones")
                            .font(.hearthUI(10))
                            .foregroundStyle(hearth.textTertiary)
                        Text(book.title)
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(book.backendName ?? book.source.rawValue.capitalized)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
            }

            HStack(spacing: 12) {
                EmberButton(title: "Merge \(suggestion.books.count)", systemImage: "square.stack.3d.up.fill") {
                    confirm(suggestion)
                }
                QuietButton(title: "Not the same") {
                    dismiss(suggestion)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private func load() async {
        suggestions = await engine.library.workMergeSuggestions(limit: 6000)
        loading = false
    }

    private func confirm(_ suggestion: WorkMergeSuggestion) {
        PlatformHaptics.impact(.medium)
        engine.library.confirmWorkMergeSuggestion(suggestion)
        withAnimation(.snappy) { suggestions.removeAll { $0.id == suggestion.id } }
    }

    private func dismiss(_ suggestion: WorkMergeSuggestion) {
        PlatformHaptics.selection()
        engine.library.dismissWorkMergeSuggestion(suggestion)
        withAnimation(.snappy) { suggestions.removeAll { $0.id == suggestion.id } }
    }
}
