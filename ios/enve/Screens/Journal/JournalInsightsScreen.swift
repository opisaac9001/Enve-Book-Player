import SwiftUI

struct JournalInsightsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = JournalInsightsModel()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "Patterns in the pages", title: "Insights")

                if !loaded {
                    JournalLoadingNote(text: "Reading between the lines…")
                } else {
                    weekCard
                    rhythmCard
                    if !model.snapshot.topBooks.isEmpty {
                        topBooksCard
                    }
                    if !model.snapshot.topAuthors.isEmpty || !model.snapshot.topNarrators.isEmpty {
                        creatorsCard
                    }
                    yearReviewCard
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            loaded = true
        }
    }

    private var weekCard: some View {
        JournalCard("Week over week") {
            HStack(spacing: 14) {
                JournalStatTile(
                    value: HearthFormat.duration(model.snapshot.thisWeekSeconds),
                    label: "This week"
                )
                JournalStatTile(
                    value: HearthFormat.duration(model.snapshot.lastWeekSeconds),
                    label: "Last week"
                )
            }
            Text(weekComparison)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private var rhythmCard: some View {
        JournalCard("Your rhythm") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(model.snapshot.currentStreak)", label: "Current streak")
                JournalStatTile(value: "\(model.snapshot.longestStreak)", label: "Longest streak")
                JournalStatTile(value: model.snapshot.favoriteWeekday ?? "-", label: "Favorite day")
                JournalStatTile(
                    value: "\(model.snapshot.yearReview.activeDays)",
                    label: "Active days in \(model.selectedYear)"
                )
            }
        }
    }

    private var topBooksCard: some View {
        JournalCard("Most kept company") {
            VStack(spacing: 14) {
                ForEach(model.snapshot.topBooks.prefix(6)) { entry in
                    NavigationLink {
                        BookDetailScreen(book: entry.book)
                    } label: {
                        HStack(spacing: 12) {
                            CoverTile(book: entry.book, width: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.book.title)
                                    .font(.hearthUI(15, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(1)
                                Text(entry.book.author?.nilIfBlank ?? "Unknown author")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(HearthFormat.duration(entry.seconds))
                                .font(.hearthUI(13, weight: .semibold))
                                .foregroundStyle(hearth.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var creatorsCard: some View {
        JournalCard("Voices you return to") {
            if let author = model.snapshot.topAuthors.first {
                insightLeader(label: "Author", entry: author)
            }
            if let narrator = model.snapshot.topNarrators.first {
                insightLeader(label: "Narrator", entry: narrator)
            }
        }
    }

    private var yearReviewCard: some View {
        let review = model.snapshot.yearReview
        return JournalCard("\(review.year) in review") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.snapshot.availableYears, id: \.self) { year in
                        HearthChip(
                            title: String(year),
                            isSelected: year == model.selectedYear
                        ) {
                            model.selectedYear = year
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            JournalAllTimeFigure(seconds: review.totalSeconds)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(review.activeDays)", label: "Active days")
                JournalStatTile(value: "\(review.sessions)", label: "Sessions")
                JournalStatTile(value: "\(review.booksFinished)", label: "Books finished")
                JournalStatTile(value: review.favoriteMonth ?? "-", label: "Favorite month")
                JournalStatTile(value: HearthFormat.duration(review.listeningSeconds), label: "Listening")
                JournalStatTile(value: HearthFormat.duration(review.readingSeconds), label: "Reading")
            }

            if review.pagesRead > 0 {
                insightDetail(label: "Pages turned", value: review.pagesRead.formatted())
            }
            if let book = review.topBook {
                insightDetail(label: "Top book", value: book.book.title)
            }
            if let author = review.topAuthor {
                insightDetail(label: "Top author", value: author.name)
            }
            if let narrator = review.topNarrator {
                insightDetail(label: "Top narrator", value: narrator.name)
            }

            if review.totalSeconds <= 0 && review.booksFinished == 0 {
                JournalQuietNote(text: "This year is waiting for its first chapter.")
            }
        }
    }

    private var weekComparison: String {
        let current = model.snapshot.thisWeekSeconds
        let previous = model.snapshot.lastWeekSeconds
        if previous <= 0 {
            return current > 0 ? "A new week is on the record." : "Your next session starts the comparison."
        }
        let change = Int(((current - previous) / previous * 100).rounded())
        if change == 0 { return "Right in step with last week." }
        return change > 0
            ? "\(change)% more time than last week."
            : "\(abs(change))% less time than last week."
    }

    private func insightLeader(label: String, entry: JournalInsightNamedEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Overline(label, color: hearth.textTertiary)
                Text(entry.name)
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
            }
            Spacer()
            Text(HearthFormat.duration(entry.seconds))
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private func insightDetail(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            Spacer()
            Text(value)
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
