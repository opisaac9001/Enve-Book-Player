import SwiftUI

struct GrimmoryStatsDashboard: View {
    let stats: GrimmoryStatsSnapshot

    @Environment(\.hearth) private var hearth

    var body: some View {
        overview
        readingRhythm
        readingTaste
        pageTurners
        momentum
        bookJourneys
        listeningStory
        listeningTaste
        sessionShape
    }

    private var overview: some View {
        JournalCard("Your Grimmory year") {
            JournalAllTimeFigure(seconds: totalSeconds)
            Text(overviewLine)
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(stats.streak?.currentStreak ?? 0)", label: "Current streak")
                JournalStatTile(value: "\(stats.streak?.longestStreak ?? 0)", label: "Longest streak")
                JournalStatTile(value: "\(stats.streak?.totalReadingDays ?? activeDays)", label: "Reading days")
                JournalStatTile(value: "\(finishedBooks)", label: "Finished this year")
            }
        }
    }

    private var readingRhythm: some View {
        JournalCard("Your reading rhythm") {
            HStack(spacing: 16) {
                GrimmoryMoment(
                    glyph: "moon.stars.fill",
                    value: peakReadingHour.map(hourLabel) ?? "—",
                    label: "Favorite hour"
                )
                GrimmoryMoment(
                    glyph: "calendar",
                    value: favoriteReadingDay?.dayName ?? "—",
                    label: "Favorite day"
                )
            }
            if !heatmap.isEmpty {
                GeometryReader { proxy in
                    JournalHeatmap(daily: heatmap, width: proxy.size.width)
                }
                .frame(height: 48)
                Text("Each ember is a day Grimmory remembers.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            if !stats.readingPeakHours.isEmpty {
                JournalColumns(
                    columns: (0..<24).map { hour in
                        let seconds = stats.readingPeakHours.first(where: { $0.hourOfDay == hour })?.totalDurationSeconds ?? 0
                        return (hour % 6 == 0 ? shortHourLabel(hour) : "", Double(seconds) / 60)
                    },
                    height: 76
                )
            }
        }
    }

    @ViewBuilder
    private var readingTaste: some View {
        let genres = stats.readingGenres.sorted { $0.totalDurationSeconds > $1.totalDurationSeconds }
        if !genres.isEmpty {
            JournalCard("What keeps you turning pages") {
                Text(tasteLine(genres))
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                VStack(spacing: 14) {
                    ForEach(Array(genres.prefix(6).enumerated()), id: \.element.id) { index, genre in
                        JournalMeterRow(
                            rank: index + 1,
                            label: cleanGenre(genre.genre),
                            detail: duration(genre.totalDurationSeconds),
                            fraction: Double(genre.totalDurationSeconds) / Double(max(genres.first?.totalDurationSeconds ?? 1, 1))
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pageTurners: some View {
        let books = stats.pageTurners.sorted { $0.gripScore > $1.gripScore }
        if !books.isEmpty {
            JournalCard("The books that had you") {
                Text("Grimmory scores the pull of a book from your pace, gaps, and finishing burst.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                VStack(spacing: 16) {
                    ForEach(Array(books.prefix(5).enumerated()), id: \.element.id) { index, book in
                        JournalMeterRow(
                            rank: index + 1,
                            label: book.bookTitle,
                            detail: "\(book.gripScore) grip",
                            fraction: Double(book.gripScore) / 100
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var momentum: some View {
        if !completionColumns.isEmpty || stats.distributions != nil || stats.listeningFunnel != nil {
            JournalCard("Momentum") {
                if !completionColumns.isEmpty {
                    JournalColumns(columns: completionColumns, height: 82)
                    Text("Books finished month by month")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
                if let funnel = stats.listeningFunnel, funnel.totalStarted > 0 {
                    GrimmoryFunnel(funnel: funnel)
                }
                if let buckets = stats.distributions?.progressDistribution, !buckets.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(buckets) { bucket in
                            JournalMeterRow(
                                label: bucket.range,
                                detail: "\(bucket.count)",
                                fraction: Double(bucket.count) / Double(max(buckets.map(\.count).max() ?? 1, 1))
                            )
                        }
                    }
                }
                if let statuses = stats.distributions?.statusDistribution, !statuses.isEmpty {
                    Text(statuses.map { "\(friendlyStatus($0.status)) \($0.count)" }.joined(separator: " · "))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var bookJourneys: some View {
        let books = stats.bookTimeline.sorted { $0.totalDurationSeconds > $1.totalDurationSeconds }
        if !books.isEmpty {
            JournalCard("Reading lives") {
                VStack(spacing: 16) {
                    ForEach(books.prefix(6)) { book in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(book.title)
                                    .font(.hearthUI(14, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(duration(book.totalDurationSeconds))
                                    .font(.hearthUI(13, weight: .semibold))
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            Ribbon(progress: normalizedProgress(book.maxProgress), tint: hearth.ember, height: 4)
                            Text("\(book.totalSessions) sessions · \(dateSpan(book.firstSessionDate, book.lastSessionDate))")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var listeningStory: some View {
        let completion = stats.listeningCompletion
        if completion != nil || !stats.listeningTrend.isEmpty || !stats.longestAudiobooks.isEmpty {
            JournalCard("The listening shelf") {
                if let completion {
                    HStack(spacing: 16) {
                        GrimmoryMoment(glyph: "headphones", value: "\(completion.totalAudiobooks)", label: "Audiobooks")
                        GrimmoryMoment(glyph: "checkmark.circle", value: "\(completion.completed)", label: "Completed")
                        GrimmoryMoment(glyph: "bookmark", value: "\(completion.inProgressCount)", label: "Underway")
                    }
                    ForEach(completion.inProgress.prefix(4)) { book in
                        JournalMeterRow(
                            label: book.title,
                            detail: "\(Int(book.progressPercent.rounded()))%",
                            fraction: book.progressPercent / 100
                        )
                    }
                }
                if stats.listeningTrend.count > 1 {
                    JournalSparkColumns(values: stats.listeningTrend.map { Double($0.totalDurationSeconds) / 60 }, height: 62)
                    Text("Your last \(stats.listeningTrend.count) weeks of listening")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                } else if let week = stats.listeningTrend.first, week.totalDurationSeconds > 0 {
                    GrimmoryMoment(
                        glyph: "calendar",
                        value: duration(week.totalDurationSeconds),
                        label: "This week's listening"
                    )
                }
                if !stats.listeningPace.isEmpty {
                    Text("\(stats.listeningPace.reduce(0) { $0 + $1.booksCompleted }) audiobooks finished over the last 12 months")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var listeningTaste: some View {
        let authors = stats.listeningAuthors.sorted { $0.totalDurationSeconds > $1.totalDurationSeconds }
        let books = stats.longestAudiobooks.sorted { $0.listenedDurationSeconds > $1.listenedDurationSeconds }
        if !authors.isEmpty || !books.isEmpty || !stats.listeningGenres.isEmpty {
            JournalCard("Voices you return to") {
                if !authors.isEmpty {
                    VStack(spacing: 14) {
                        ForEach(Array(authors.prefix(5).enumerated()), id: \.element.id) { index, author in
                            JournalMeterRow(
                                rank: index + 1,
                                label: author.author,
                                detail: duration(author.totalDurationSeconds),
                                fraction: Double(author.totalDurationSeconds) / Double(max(authors.first?.totalDurationSeconds ?? 1, 1))
                            )
                        }
                    }
                }
                ForEach(books.prefix(4)) { book in
                    JournalMeterRow(
                        label: book.title,
                        detail: duration(book.listenedDurationSeconds),
                        fraction: book.progressPercent / 100
                    )
                }
                if !stats.listeningGenres.isEmpty {
                    Text("Listening taste · \(stats.listeningGenres.prefix(4).map { cleanGenre($0.genre) }.joined(separator: " · "))")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionShape: some View {
        if !stats.readingSessions.isEmpty || !stats.listeningSessions.isEmpty || !stats.readingSpeed.isEmpty || !stats.completionRace.isEmpty {
            JournalCard("The shape of a session") {
                let all = stats.readingSessions + stats.listeningSessions
                if !all.isEmpty {
                    HStack(spacing: 16) {
                        GrimmoryMoment(glyph: "timer", value: duration(Int(all.map(\.durationMinutes).reduce(0, +) / Double(all.count) * 60)), label: "Typical session")
                        GrimmoryMoment(glyph: "sparkles", value: duration(Int((all.map(\.durationMinutes).max() ?? 0) * 60)), label: "Longest session")
                    }
                    JournalSparkColumns(values: all.sorted { $0.hourOfDay < $1.hourOfDay }.map(\.durationMinutes), height: 58)
                }
                if let latestSpeed = stats.readingSpeed.last {
                    Text("Latest pace · \(latestSpeed.avgProgressPerMinute.formatted(.number.precision(.fractionLength(2))))% progress per minute")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if !stats.completionRace.isEmpty {
                    let racers = Dictionary(grouping: stats.completionRace, by: \.bookId)
                    Text("\(racers.count) finishing \(racers.count == 1 ? "story" : "stories") mapped session by session")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    private var totalSeconds: TimeInterval {
        TimeInterval(stats.bookTimeline.reduce(0) { $0 + $1.totalDurationSeconds })
    }

    private var activeDays: Int {
        stats.readingHeatmap.filter { $0.count > 0 }.count
    }

    private var finishedBooks: Int {
        stats.completionTimeline.reduce(0) { $0 + $1.finishedBooks }
    }

    private var overviewLine: String {
        let sessions = stats.bookTimeline.reduce(0) { $0 + $1.totalSessions }
        let books = stats.bookTimeline.count
        return "\(sessions) sessions across \(books) \(books == 1 ? "book" : "books"), kept by Grimmory in \(stats.year)."
    }

    private var heatmap: [String: TimeInterval] {
        if let streak = stats.streak {
            return Dictionary(uniqueKeysWithValues: streak.last52Weeks.map { ($0.date, $0.active ? 60 : 0) })
        }
        return Dictionary(uniqueKeysWithValues: stats.readingHeatmap.map { ($0.date, TimeInterval($0.count * 60)) })
    }

    private var peakReadingHour: Int? {
        stats.readingPeakHours.max { $0.totalDurationSeconds < $1.totalDurationSeconds }?.hourOfDay
    }

    private var favoriteReadingDay: GrimmoryFavoriteDay? {
        stats.readingFavoriteDays.max { $0.totalDurationSeconds < $1.totalDurationSeconds }
    }

    private var completionColumns: [(label: String, value: Double)] {
        let calendar = Calendar.current
        return (1...12).map { month in
            let value = stats.completionTimeline.first(where: { $0.month == month })?.finishedBooks ?? 0
            let label = calendar.shortMonthSymbols[month - 1].prefix(1)
            return (String(label), Double(value))
        }
    }

    private func tasteLine(_ genres: [GrimmoryGenreStat]) -> String {
        guard let first = genres.first else { return "" }
        return "\(cleanGenre(first.genre)) leads your year, with \(duration(first.totalDurationSeconds)) across \(first.totalSessions) sessions."
    }

    private func cleanGenre(_ value: String) -> String {
        value == "BLOB" ? "Audiobooks" : value
    }

    private func normalizedProgress(_ value: Double) -> Double {
        value > 1 ? value / 100 : value
    }

    private func duration(_ seconds: Int) -> String {
        HearthFormat.duration(TimeInterval(seconds))
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }

    private func shortHourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12a"
        case 6: "6a"
        case 12: "12p"
        case 18: "6p"
        default: ""
        }
    }

    private func friendlyStatus(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func dateSpan(_ first: String, _ last: String) -> String {
        first == last ? first : "\(first) – \(last)"
    }
}

private struct GrimmoryMoment: View {
    let glyph: String
    let value: String
    let label: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: glyph)
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(hearth.ember)
            Text(value)
                .font(.hearthDisplay(19, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GrimmoryFunnel: View {
    let funnel: GrimmoryListeningFunnel

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("How far your audiobooks travel", color: hearth.textTertiary)
            ForEach(stages, id: \.label) { stage in
                JournalMeterRow(
                    label: stage.label,
                    detail: "\(stage.value)",
                    fraction: Double(stage.value) / Double(max(funnel.totalStarted, 1))
                )
            }
        }
    }

    private var stages: [(label: String, value: Int)] {
        [
            ("Started", funnel.totalStarted),
            ("Quarter mark", funnel.reached25),
            ("Halfway", funnel.reached50),
            ("Final stretch", funnel.reached75),
            ("Finished", funnel.completed),
        ]
    }
}
