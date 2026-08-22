import SwiftUI

struct HardcoverTrendingScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var books: [HardcoverTrendingBook] = []
    @State private var period: HardcoverTrendingPeriod = .month
    @State private var addedBookIds: Set<Int> = []
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Trending")

                HStack(spacing: 10) {
                    HearthChip(title: "This month", isSelected: period == .month) { hardcoverSetPeriod(.month) }
                    HearthChip(title: "This year", isSelected: period == .year) { hardcoverSetPeriod(.year) }
                    HearthChip(title: "All time", isSelected: period == .allTime) { hardcoverSetPeriod(.allTime) }
                }
                .padding(.horizontal, 24)

                if !loaded {
                    HardcoverLoading(line: "Asking what everyone is reading.")
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if books.isEmpty {
                    HardcoverEmpty(glyph: "chart.line.uptrend.xyaxis", title: "Nothing trending just now.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                            hardcoverTrendingRow(book, rank: index + 1)
                            if index < books.count - 1 {
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
        .task { await hardcoverLoadTrending() }
        .refreshable { await hardcoverLoadTrending() }
    }

    private func hardcoverTrendingRow(_ book: HardcoverTrendingBook, rank: Int) -> some View {
        HStack(spacing: 14) {
            NavigationLink {
                HardcoverBookDetailScreen(bookId: book.id, bookTitle: book.title)
            } label: {
                HStack(spacing: 14) {
                    Text("\(rank)")
                        .font(.hearthDisplay(18))
                        .foregroundStyle(hearth.textTertiary)
                        .frame(width: 26, alignment: .center)

                    HardcoverCoverThumb(urlString: book.coverImageUrl)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                            .font(.hearthDisplay(16, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let author = book.author {
                            Text(author)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(1)
                        }
                        Text("\(book.usersCount) reading")
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            GlyphButton(
                systemImage: addedBookIds.contains(book.id) ? "checkmark" : "plus",
                size: 36,
                glyphSize: 14,
                label: addedBookIds.contains(book.id) ? "On your shelf" : "Add to your shelf"
            ) {
                guard !addedBookIds.contains(book.id) else { return }
                Task { await hardcoverAdd(book) }
            }
            .opacity(addedBookIds.contains(book.id) ? 0.5 : 1)
        }
        .padding(.vertical, 12)
    }

    private func hardcoverSetPeriod(_ newPeriod: HardcoverTrendingPeriod) {
        guard period != newPeriod else { return }
        period = newPeriod
        loaded = false
        Task { await hardcoverLoadTrending() }
    }

    private func hardcoverLoadTrending() async {
        loadError = nil
        do {
            books = try await HardcoverService.shared.getTrendingBooks(limit: 30, period: period)
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func hardcoverAdd(_ book: HardcoverTrendingBook) async {
        do {
            _ = try await HardcoverService.shared.addBookToLibrary(bookId: book.id)
            addedBookIds.insert(book.id)
            PlatformHaptics.notification(.success)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
