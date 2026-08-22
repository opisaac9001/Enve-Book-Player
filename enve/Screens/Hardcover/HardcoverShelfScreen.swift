import SwiftUI

struct HardcoverShelfScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var books: [HardcoverUserBookLegacy] = []
    @State private var filter: HardcoverShelfFilter = .reading
    @State private var matching: HardcoverUserBookLegacy?
    @State private var loadError: String?
    @State private var loaded = false

    private enum HardcoverShelfFilter: String, CaseIterable {
        case all = "All"
        case reading = "Reading"
        case wantToRead = "Wanting"
        case finished = "Finished"
        case didNotFinish = "Set down"

        var statusId: Int? {
            switch self {
            case .all: nil
            case .wantToRead: HardcoverReadingStatus.wantToRead.rawValue
            case .reading: HardcoverReadingStatus.currentlyReading.rawValue
            case .finished: HardcoverReadingStatus.finished.rawValue
            case .didNotFinish: HardcoverReadingStatus.didNotFinish.rawValue
            }
        }
    }

    private var filtered: [HardcoverUserBookLegacy] {
        guard let statusId = filter.statusId else { return books }
        return books.filter { $0.statusId == statusId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Your shelf there")

                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(HardcoverShelfFilter.allCases, id: \.self) { option in
                            HearthChip(
                                title: "\(option.rawValue) \(hardcoverCount(for: option))",
                                isSelected: filter == option
                            ) {
                                filter = option
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)

                if !loaded {
                    HardcoverLoading(line: "Fetching your shelf.")
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if filtered.isEmpty {
                    HardcoverEmpty(
                        glyph: "books.vertical",
                        title: "This shelf is bare.",
                        line: "Books you keep on Hardcover appear here."
                    )
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(filtered) { userBook in
                            hardcoverShelfCard(userBook)
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
        .task { await hardcoverLoadShelf() }
        .refreshable { await hardcoverLoadShelf() }
        .sheet(item: $matching) { userBook in
            HardcoverReverseMatchScreen(hardcoverBook: userBook)
                .enveEnvironment()
        }
    }

    private func hardcoverShelfCard(_ userBook: HardcoverUserBookLegacy) -> some View {
        let isMatched = SettingsManager.shared.getHardcoverMatch(forHardcoverBookId: userBook.book.id) != nil
        return HardcoverCard {
            HStack(alignment: .top, spacing: 14) {
                NavigationLink {
                    HardcoverBookDetailScreen(bookId: userBook.book.id, bookTitle: userBook.book.title)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        HardcoverCoverThumb(urlString: userBook.book.image?.url, width: 56)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(userBook.book.title)
                                .font(.hearthDisplay(16, weight: .semibold))
                                .foregroundStyle(hearth.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(userBook.book.authorDisplay)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                HardcoverStatusChip(status: userBook.readingState)
                                if let rating = userBook.rating, rating > 0 {
                                    HardcoverStars(rating: Double(rating), size: 9)
                                }
                            }
                            if let progress = userBook.progressFraction, progress > 0, progress < 1,
                                userBook.readingState == .currentlyReading
                            {
                                HStack(spacing: 8) {
                                    Ribbon(progress: progress, tint: hearth.ember)
                                    Text("\(Int(progress * 100))%")
                                        .font(.hearthUI(11))
                                        .foregroundStyle(hearth.textTertiary)
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())

                Spacer(minLength: 0)

                GlyphButton(
                    systemImage: isMatched ? "link" : "link.badge.plus",
                    size: 36,
                    glyphSize: 14,
                    label: isMatched ? "Linked to your library" : "Match to your library"
                ) {
                    matching = userBook
                }
                .opacity(isMatched ? 0.5 : 1)
            }
        }
    }

    private func hardcoverCount(for option: HardcoverShelfFilter) -> Int {
        guard let statusId = option.statusId else { return books.count }
        return books.filter { $0.statusId == statusId }.count
    }

    private func hardcoverLoadShelf() async {
        loadError = nil
        do {
            var loadedBooks = try await HardcoverService.shared.getUserBooks(limit: 200)
            loadedBooks.sort { lhs, rhs in
                let lhsReading = lhs.statusId == HardcoverReadingStatus.currentlyReading.rawValue ? 0 : 1
                let rhsReading = rhs.statusId == HardcoverReadingStatus.currentlyReading.rawValue ? 0 : 1
                if lhsReading != rhsReading { return lhsReading < rhsReading }
                return lhs.book.title.localizedCaseInsensitiveCompare(rhs.book.title) == .orderedAscending
            }
            books = loadedBooks
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}
