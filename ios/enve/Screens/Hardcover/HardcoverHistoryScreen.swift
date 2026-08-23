import SwiftUI

struct HardcoverHistoryScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var entries: [HardcoverFinishedBookEntry] = []
    @State private var hasMore = true
    @State private var loadingMore = false
    @State private var loadError: String?
    @State private var loaded = false

    private let hardcoverPageSize = 25

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "History")

                if !loaded {
                    HardcoverLoading(line: "Turning back the pages.")
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if entries.isEmpty {
                    HardcoverEmpty(glyph: "clock", title: "Nothing finished yet.", line: "Finished books gather here.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            hardcoverHistoryRow(entry)
                            if entry.id != entries.last?.id {
                                Rectangle().fill(hearth.hairline).frame(height: 1)
                            }
                        }
                        if hasMore {
                            QuietButton(title: loadingMore ? "A moment." : "Further back", systemImage: "arrow.down") {
                                guard !loadingMore else { return }
                                Task { await hardcoverLoadMore() }
                            }
                            .padding(.top, 16)
                            .frame(maxWidth: .infinity)
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
        .task { await hardcoverLoadHistory() }
        .refreshable { await hardcoverLoadHistory() }
    }

    private func hardcoverHistoryRow(_ entry: HardcoverFinishedBookEntry) -> some View {
        NavigationLink {
            HardcoverBookDetailScreen(bookId: entry.bookId, bookTitle: entry.title)
        } label: {
            HStack(spacing: 14) {
                HardcoverCoverThumb(urlString: entry.coverImageUrl)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.hearthDisplay(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(entry.author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let date = entry.finishedAt {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                        }
                        if let rating = entry.rating, rating > 0 {
                            HardcoverStars(rating: rating, size: 9)
                        }
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

    private func hardcoverLoadHistory() async {
        loadError = nil
        do {
            entries = try await HardcoverService.shared.getFinishedBooks(limit: hardcoverPageSize, offset: 0)
            hasMore = entries.count >= hardcoverPageSize
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func hardcoverLoadMore() async {
        loadingMore = true
        if let more = try? await HardcoverService.shared.getFinishedBooks(limit: hardcoverPageSize, offset: entries.count) {
            entries.append(contentsOf: more)
            hasMore = more.count >= hardcoverPageSize
        }
        loadingMore = false
    }
}
