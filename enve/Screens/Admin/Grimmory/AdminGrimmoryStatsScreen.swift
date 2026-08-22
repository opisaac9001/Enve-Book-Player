import SwiftUI

struct AdminGrimmoryStatsScreen: View {
    let connection: ServerConnection
    @State private var model: AdminGrimmoryStatsModel

    @Environment(\.hearth) private var hearth

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminGrimmoryStatsModel(connection: connection))
    }

    var body: some View {
        AdminSubScreen(overline: connection.name, title: "Your reading") {
            if model.isLoading && !model.hasLoaded {
                AdminLoadingRow("Tallying the hours…")
            } else if let error = model.error {
                SourcesCard {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(hearth.statusWarn)
                        Text(error)
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                    }
                }
            } else if model.hasLoaded {
                adminSummaryCard
                adminTimeCard
                adminTrendCard
                adminBreakdownCard
                if !model.favoriteAuthors.isEmpty { adminAuthorsCard }
                if !model.topBooks.isEmpty { adminTopBooksCard }
                if !model.recentSessions.isEmpty { adminSessionsCard }
            }
        }
        .refreshable { await model.loadStats() }
        .task {
            if !model.hasLoaded { await model.loadStats() }
        }
    }

    private var adminSummaryCard: some View {
        SourcesCard {
            Overline("The shelf so far")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.totalBooks)", label: "Books")
                AdminStat(value: "\(model.booksFinished)", label: "Finished")
                AdminStat(value: "\(model.booksInProgress)", label: "Underway")
                AdminStat(value: "\(model.sessionsCount)", label: "Sessions")
            }
        }
    }

    private var adminTimeCard: some View {
        SourcesCard {
            Overline("Time in the pages")
            AdminInfoRow(label: "All time", value: AdminFormat.hours(Double(model.totalReadingSeconds)))
            AdminInfoRow(label: "This month", value: AdminFormat.hours(Double(model.monthlyReadingSeconds)))
            AdminInfoRow(label: "This week", value: AdminFormat.hours(Double(model.weeklyReadingSeconds)))
            AdminInfoRow(label: "A typical session", value: AdminFormat.hours(Double(model.averageSessionSeconds)))
            if model.currentStreak > 0 {
                AdminInfoRow(
                    label: "Current streak",
                    value: "\(model.currentStreak) day\(model.currentStreak == 1 ? "" : "s")",
                    valueColor: hearth.ember
                )
            }
        }
    }

    private var adminTrendCard: some View {
        SourcesCard {
            Overline("The last thirty days")
            if model.readingTrend.allSatisfy({ $0.minutes == 0 }) {
                AdminEmptyText("No reading in the last thirty days. The books are patient.")
            } else {
                AdminBars(values: model.readingTrend.map { Double($0.minutes) })
                HStack {
                    Text(adminDayLabel(model.readingTrend.first?.date))
                    Spacer()
                    Text("\(model.readingTrend.filter { $0.minutes > 0 }.count) active days")
                    Spacer()
                    Text(adminDayLabel(model.readingTrend.last?.date))
                }
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private var adminBreakdownCard: some View {
        let segments: [(label: String, value: Int, color: Color)] = [
            ("Finished", model.booksFinished, hearth.statusOK),
            ("Underway", model.booksInProgress, hearth.ember),
            ("Untouched", model.booksNotStarted, hearth.textTertiary),
            ("Set aside", model.booksAbandoned, hearth.statusError),
        ].filter { $0.value > 0 }

        return SourcesCard {
            Overline("How the library stands")
            if segments.isEmpty {
                AdminEmptyText("No books tracked yet.")
            } else {
                GeometryReader { geo in
                    let total = max(segments.reduce(0) { $0 + $1.value }, 1)
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.label) { segment in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(segment.color)
                                .frame(width: max(geo.size.width * CGFloat(segment.value) / CGFloat(total), 4))
                        }
                    }
                }
                .frame(height: 10)
                ForEach(segments, id: \.label) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                        Text(segment.label)
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.text)
                        Spacer()
                        Text("\(segment.value)")
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.textSecondary)
                    }
                    .frame(minHeight: 28)
                }
            }
        }
    }

    private var adminAuthorsCard: some View {
        SourcesCard {
            Overline("Favorite authors")
            ForEach(model.favoriteAuthors, id: \.author) { entry in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(hearth.emberSoft)
                            .frame(width: 32, height: 32)
                        Text(String(entry.author.prefix(1)).uppercased())
                            .font(.hearthDisplay(14))
                            .foregroundStyle(hearth.ember)
                    }
                    Text(entry.author)
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Spacer()
                    Text("\(entry.count) book\(entry.count == 1 ? "" : "s")")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                .frame(minHeight: 36)
            }
        }
    }

    private var adminTopBooksCard: some View {
        SourcesCard {
            Overline("Most read")
            ForEach(model.topBooks.prefix(5)) { book in
                HStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.hearthUI(14, weight: .medium))
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
                    if let progress = book.readProgress {
                        AdminTag(
                            text: "\(Int(progress))%",
                            color: progress >= 99 ? hearth.statusOK : hearth.ember
                        )
                    }
                }
                .frame(minHeight: 40)
            }
        }
    }

    private var adminSessionsCard: some View {
        SourcesCard {
            Overline("Recent sessions")
            ForEach(model.recentSessions.prefix(8)) { session in
                HStack(spacing: 12) {
                    Image(systemName: session.bookType?.uppercased() == "AUDIOBOOK" ? "headphones" : "book")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.bookTitle ?? "Book #\(session.bookId)")
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        if let duration = session.durationFormatted {
                            Text(duration)
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let delta = session.progressDelta, delta > 0 {
                            Text("+\(String(format: "%.1f", delta))%")
                                .font(.hearthUI(11, weight: .medium))
                                .foregroundStyle(hearth.statusOK)
                        }
                        if let endProgress = session.endProgress {
                            Text("\(Int(endProgress))%")
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                }
                .frame(minHeight: 40)
            }
        }
    }

    private func adminDayLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
