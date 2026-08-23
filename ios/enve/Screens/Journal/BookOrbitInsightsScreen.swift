import SwiftUI

struct BookOrbitInsightsScreen: View {
    var connectionId: UUID?

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = BookOrbitInsightsModel()

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    JournalScreenHeader(overline: "Kept by your server", title: "BookOrbit")

                    if model.connections.count > 1 {
                        serverChips
                    }

                    switch model.state {
                    case .loading:
                        JournalLoadingNote(text: "Asking \(model.serverName)…")
                    case .unavailable:
                        BookOrbitUnavailableCard(line: unavailableLine)
                    case .failed(let message):
                        BookOrbitErrorCard(message: message) {
                            Task { await model.refresh() }
                        }
                    case .ready:
                        rangeChips
                        content(cardWidth: max(1, geo.size.width - 84))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task {
            model.bind(preferred: connectionId)
            await model.refresh()
        }
    }

    private var unavailableLine: String {
        model.connections.isEmpty
            ? "No BookOrbit server is connected. Add one in Settings to see what it keeps."
            : "This BookOrbit server doesn't publish reading statistics. Update the server to see them here."
    }

    private var serverChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.connections) { connection in
                    HearthChip(title: connection.name, isSelected: connection.id == model.connectionId) {
                        model.select(connection: connection.id)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var rangeChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(BookOrbitInsightsRange.allCases) { range in
                    HearthChip(title: range.rawValue, isSelected: range == model.range) {
                        model.select(range: range)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func content(cardWidth: CGFloat) -> some View {
        headlineSection
        rhythmSection(cardWidth: cardWidth)
        depthSection
        shelfSection
        doorways
    }

    @ViewBuilder
    private var headlineSection: some View {
        let snapshot = model.snapshot

        paceCard(snapshot)

        if let summary = snapshot.summary {
            shelfCard(summary)
        }

        if let streak = snapshot.streak {
            streakCard(streak)
        }

        if let goal = snapshot.goal, let target = goal.goalBooks, target > 0 {
            goalCard(goal, target: target)
        }

        if let challenge = snapshot.challenge {
            challengeCard(challenge)
        }
    }

    @ViewBuilder
    private func rhythmSection(cardWidth: CGFloat) -> some View {
        let snapshot = model.snapshot

        if !snapshot.daily.isEmpty {
            activityCard(snapshot)
        }

        if snapshot.hasHeatmap {
            heatmapCard(snapshot, width: cardWidth)
        }

        if !snapshot.peakHours.isEmpty {
            whenCard(snapshot)
        }

        if let sources = snapshot.sources, sources.totalSeconds > 0 {
            sourcesCard(sources)
        }

        if !snapshot.genres.isEmpty {
            genresCard(snapshot)
        }
    }

    @ViewBuilder
    private var depthSection: some View {
        let snapshot = model.snapshot

        if let funnel = snapshot.funnel, funnel.current.started > 0 {
            funnelCard(funnel)
        }

        if let latency = snapshot.latency, latency.totalCompletions > 0 {
            latencyCard(latency)
        }

        if let dna = snapshot.dna, dna.booksAnalyzed > 0 {
            dnaCard(dna)
        }

        if let diversity = snapshot.diversity, diversity.booksAnalyzed > 0 {
            diversityCard(diversity)
        }

        if let projection = snapshot.projection {
            projectionCard(projection)
        }
    }

    @ViewBuilder
    private var shelfSection: some View {
        let snapshot = model.snapshot

        if let highlight = snapshot.highlight {
            highlightCard(highlight)
        }

        if !snapshot.gems.isEmpty || snapshot.longWait != nil {
            waitingCard(snapshot)
        }

        if let overview = snapshot.overview {
            overviewCard(overview)
        }
    }

    private func paceCard(_ snapshot: BookOrbitInsightsSnapshot) -> some View {
        JournalCard("Time in the pages") {
            JournalAllTimeFigure(seconds: snapshot.totalSeconds)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((snapshot.averageSecondsPerDay / 60).rounded()))")
                    .font(.hearthDisplay(28))
                    .foregroundStyle(hearth.text)
                Text("minutes a day")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
            }
            Text(model.range.caption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
            if snapshot.totalSeconds <= 0 {
                JournalQuietNote(text: "\(model.serverName) has nothing on record for this window yet.")
            }
        }
    }

    private func shelfCard(_ summary: BookOrbitProvider.StatisticsSummary) -> some View {
        JournalCard("On the shelves") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(summary.trackedBooks)", label: "Tracked")
                JournalStatTile(value: "\(summary.startedBooks)", label: "Started")
                JournalStatTile(value: "\(summary.inProgressBooks)", label: "Underway")
                JournalStatTile(value: "\(summary.completedBooks)", label: "Finished")
            }
            JournalMeterRow(
                label: "Average progress",
                detail: "\(Int(summary.meanProgressPercent.rounded()))%",
                fraction: min(max(summary.meanProgressPercent / 100, 0), 1)
            )
        }
    }

    private func streakCard(_ streak: BookOrbitProvider.ReadingStreakWidget) -> some View {
        JournalCard("The run") {
            HStack(spacing: 14) {
                JournalStatTile(value: "\(streak.currentStreak)", label: "Days running")
                JournalStatTile(value: "\(streak.longestStreak)", label: "Longest run")
            }
            HStack(spacing: 7) {
                ForEach(Array(streak.lastSevenDays.enumerated()), id: \.offset) { _, active in
                    Capsule(style: .continuous)
                        .fill(active ? hearth.ember : hearth.hairline)
                        .frame(height: 8)
                }
            }
            .accessibilityLabel("\(streak.lastSevenDays.filter { $0 }.count) of the last seven days had reading")
        }
    }

    private func goalCard(_ goal: BookOrbitProvider.ReadingGoalWidget, target: Int) -> some View {
        JournalCard("\(goal.year) goal") {
            HStack(spacing: 18) {
                JournalGoalRing(
                    fraction: Double(goal.completedBooks) / Double(target),
                    centerValue: "\(goal.completedBooks)",
                    centerUnit: "books"
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        goal.completedBooks >= target
                            ? "The year's goal, kept."
                            : "\(target - goal.completedBooks) to go"
                    )
                    .font(.hearthDisplay(17, weight: .semibold))
                    .foregroundStyle(goal.completedBooks >= target ? hearth.statusOK : hearth.text)
                    Text("Goal: \(target) books")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
        }
    }

    private func challengeCard(_ challenge: BookOrbitProvider.MonthlyChallengeWidget) -> some View {
        JournalCard("This month's challenge") {
            Text(challenge.title)
                .font(.hearthDisplay(18, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text(challenge.description)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            JournalMeterRow(
                label: challenge.completed ? "Done" : "In progress",
                detail: "\(Int(challenge.progress.rounded())) of \(Int(challenge.target.rounded()))",
                fraction: challenge.target > 0 ? min(challenge.progress / challenge.target, 1) : 0,
                tint: challenge.completed ? hearth.statusOK : nil
            )
        }
    }

    private func activityCard(_ snapshot: BookOrbitInsightsSnapshot) -> some View {
        let columns = BookOrbitInsightsFormat.columns(snapshot.daily)
        return JournalCard("Day by day") {
            if columns.contains(where: { $0.value > 0 }) {
                JournalColumns(columns: columns, height: 110)
                Text("\(snapshot.activeDays) active \(snapshot.activeDays == 1 ? "day" : "days") in this window")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            } else {
                JournalQuietNote(text: "Quiet, so far.")
            }
        }
    }

    private func heatmapCard(_ snapshot: BookOrbitInsightsSnapshot, width: CGFloat) -> some View {
        JournalCard("The past year") {
            JournalHeatmap(daily: snapshot.heatmapByDay, width: width)
        }
    }

    private func whenCard(_ snapshot: BookOrbitInsightsSnapshot) -> some View {
        JournalCard("When you read") {
            if let peak = snapshot.peakHourLabel {
                Text("Most often around \(peak)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.ember)
            }
            JournalColumns(
                columns: (0..<24).map { hour in
                    let seconds = snapshot.peakHours.first { $0.hour == hour }?.readingSeconds ?? 0
                    return (label: BookOrbitInsightsFormat.hourLabel(hour), value: seconds / 60)
                },
                height: 96
            )
            if let day = snapshot.favoriteDayLabel {
                Text("Favorite day: \(day)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private func sourcesCard(_ sources: BookOrbitProvider.SourceDistribution) -> some View {
        JournalCard("Where it was read") {
            VStack(spacing: 16) {
                ForEach(sources.slices, id: \.bucket) { slice in
                    JournalMeterRow(
                        label: BookOrbitInsightsFormat.sourceName(slice.bucket),
                        detail: HearthFormat.duration(slice.readingSeconds),
                        fraction: sources.totalSeconds > 0 ? slice.readingSeconds / sources.totalSeconds : 0
                    )
                }
            }
        }
    }

    private func genresCard(_ snapshot: BookOrbitInsightsSnapshot) -> some View {
        let top = Array(snapshot.genres.sorted { $0.readingSeconds > $1.readingSeconds }.prefix(6))
        let peak = top.first?.readingSeconds ?? 1
        return JournalCard("Genres by the hour") {
            VStack(spacing: 16) {
                ForEach(Array(top.enumerated()), id: \.element.genre) { index, genre in
                    JournalMeterRow(
                        rank: index + 1,
                        label: genre.genre,
                        detail: HearthFormat.duration(genre.readingSeconds),
                        fraction: peak > 0 ? genre.readingSeconds / peak : 0
                    )
                }
            }
        }
    }

    private func funnelCard(_ funnel: BookOrbitProvider.ProgressFunnelComparison) -> some View {
        let stages = BookOrbitInsightsFormat.funnelStages(funnel)
        let started = max(funnel.current.started, 1)
        return JournalCard("How far books get") {
            VStack(spacing: 16) {
                ForEach(stages) { stage in
                    JournalMeterRow(
                        label: stage.label,
                        detail: stage.detail,
                        fraction: Double(stage.count) / Double(started)
                    )
                }
            }
            Text("Over the last \(funnel.days) days")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private func latencyCard(_ latency: BookOrbitProvider.CompletionLatency) -> some View {
        JournalCard("How long books take") {
            HStack(spacing: 14) {
                JournalStatTile(
                    value: BookOrbitInsightsFormat.days(latency.medianDays),
                    label: "Median"
                )
                JournalStatTile(
                    value: BookOrbitInsightsFormat.days(latency.percentile90Days),
                    label: "Slowest tenth"
                )
            }
            JournalColumns(
                columns: latency.buckets.map { (label: $0.label, value: Double($0.count)) },
                height: 84
            )
            Text("\(latency.totalCompletions) finished in this window")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private func dnaCard(_ dna: BookOrbitProvider.ReadingDnaWidget) -> some View {
        JournalCard("Reading DNA") {
            Text(dna.archetype)
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
            VStack(spacing: 16) {
                JournalMeterRow(label: "Length", detail: dna.lengthLabel, fraction: dna.lengthScore / 100)
                JournalMeterRow(label: "Variety", detail: dna.varietyLabel, fraction: dna.varietyScore / 100)
                JournalMeterRow(label: "Rhythm", detail: dna.rhythmLabel, fraction: dna.rhythmScore / 100)
                JournalMeterRow(label: "Hour", detail: dna.timeLabel, fraction: dna.timeScore / 100)
                if let speed = dna.speedScore {
                    JournalMeterRow(label: "Pace", detail: dna.speedLabel, fraction: speed / 100)
                }
            }
            Text("From \(dna.booksAnalyzed) \(dna.booksAnalyzed == 1 ? "book" : "books")")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private func diversityCard(_ diversity: BookOrbitProvider.DiversityScoreWidget) -> some View {
        JournalCard("How wide you range") {
            HStack(spacing: 18) {
                JournalGoalRing(
                    fraction: diversity.score / 100,
                    centerValue: "\(Int(diversity.score.rounded()))",
                    centerUnit: "score"
                )
                VStack(alignment: .leading, spacing: 14) {
                    Text(diversity.label)
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text("From \(diversity.booksAnalyzed) \(diversity.booksAnalyzed == 1 ? "book" : "books")")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
            VStack(spacing: 16) {
                JournalMeterRow(
                    label: "Genres",
                    detail: "\(Int(diversity.genreScore.rounded()))",
                    fraction: diversity.genreScore / 100
                )
                JournalMeterRow(
                    label: "Authors",
                    detail: "\(Int(diversity.authorScore.rounded()))",
                    fraction: diversity.authorScore / 100
                )
                JournalMeterRow(
                    label: "Eras",
                    detail: "\(Int(diversity.eraScore.rounded()))",
                    fraction: diversity.eraScore / 100
                )
                JournalMeterRow(
                    label: "Languages",
                    detail: "\(Int(diversity.languageScore.rounded()))",
                    fraction: diversity.languageScore / 100
                )
            }
        }
    }

    private func projectionCard(_ projection: BookOrbitProvider.YearProjectionWidget) -> some View {
        JournalCard("Where the year lands") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(projection.projectedBooks)", label: "Books projected")
                JournalStatTile(value: "\(projection.booksCompletedYtd)", label: "Finished so far")
                JournalStatTile(value: JournalStatsFormat.hours(projection.projectedHours), label: "Hours projected")
                JournalStatTile(value: projection.projectedPages.formatted(), label: "Pages projected")
            }
            Text("\(projection.daysRemaining) days left · \(BookOrbitInsightsFormat.trend(projection.trend))")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private func highlightCard(_ highlight: BookOrbitProvider.HighlightOfTheDayWidget) -> some View {
        JournalCard("Highlight of the day") {
            JournalQuoteView(
                text: highlight.text,
                attribution: highlight.chapterTitle ?? highlight.bookTitle ?? "BookOrbit"
            )
            if let note = highlight.note, !note.isEmpty {
                Text(note)
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let book = model.books[highlight.bookId] {
                BookOrbitBookRow(book: book, detail: highlight.createdAt.formatted(.dateTime.month(.abbreviated).day()))
            }
        }
    }

    private func waitingCard(_ snapshot: BookOrbitInsightsSnapshot) -> some View {
        JournalCard("Waiting for you") {
            if let longWait = snapshot.longWait {
                BookOrbitWaitingRow(
                    title: longWait.title ?? "Untitled",
                    detail: "\(longWait.waitingDays) days on the shelf",
                    book: model.books[longWait.bookId]
                )
            }
            ForEach(snapshot.gems, id: \.bookId) { gem in
                BookOrbitWaitingRow(
                    title: gem.title ?? "Untitled",
                    detail: BookOrbitInsightsFormat.gemDetail(gem),
                    book: model.books[gem.bookId]
                )
            }
        }
    }

    private func overviewCard(_ overview: BookOrbitProvider.LibraryOverviewWidget) -> some View {
        JournalCard("The collection") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: overview.totalBooks.formatted(), label: "Books")
                JournalStatTile(value: overview.totalAuthors.formatted(), label: "Authors")
                JournalStatTile(value: overview.totalSeries.formatted(), label: "Series")
                JournalStatTile(value: overview.booksAddedThisYear.formatted(), label: "Added this year")
            }
            Text("\(BookOrbitInsightsFormat.bytes(overview.totalStorageBytes)) on the server")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var doorways: some View {
        VStack(spacing: 2) {
            NavigationLink {
                BookOrbitAchievementsScreen(connectionId: model.connectionId)
            } label: {
                JournalLinkRow(glyph: "rosette", title: "Honors", subtitle: "The achievement catalogue on \(model.serverName)")
            }
            NavigationLink {
                BookOrbitMarginaliaScreen(connectionId: model.connectionId)
            } label: {
                JournalLinkRow(glyph: "highlighter", title: "Highlights", subtitle: "Every note and highlight on the account")
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct BookOrbitUnavailableCard: View {
    let line: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        JournalCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.textTertiary)
                Text(line)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BookOrbitErrorCard: View {
    let message: String
    let retry: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        JournalCard {
            Text(message)
                .font(.hearthBody)
                .foregroundStyle(hearth.statusError)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Try again", action: retry)
        }
    }
}

struct BookOrbitBookRow: View {
    let book: Book
    var detail: String?

    @Environment(\.hearth) private var hearth

    var body: some View {
        NavigationLink {
            BookDetailScreen(book: book)
        } label: {
            HStack(spacing: 12) {
                CoverTile(book: book, width: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct BookOrbitWaitingRow: View {
    let title: String
    let detail: String
    let book: Book?

    @Environment(\.hearth) private var hearth

    var body: some View {
        if let book {
            BookOrbitBookRow(book: book, detail: detail)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(hearth.emberSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }
}

struct BookOrbitFunnelStage: Identifiable {
    let label: String
    let detail: String
    let count: Int

    var id: String { label }
}

enum BookOrbitInsightsFormat {
    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12a"
        case 6: "6a"
        case 12: "12p"
        case 18: "6p"
        default: ""
        }
    }

    static func sourceName(_ bucket: String) -> String {
        switch bucket {
        case "bookorbit": "BookOrbit"
        case "koreader": "KOReader"
        case "kobo": "Kobo"
        default: bucket.capitalized
        }
    }

    static func trend(_ raw: String) -> String {
        switch raw {
        case "up": "picking up"
        case "down": "easing off"
        default: "holding steady"
        }
    }

    static func days(_ value: Double?) -> String {
        guard let value else { return "-" }
        let rounded = Int(value.rounded())
        return "\(rounded)d"
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
    }

    static func gemDetail(_ gem: BookOrbitProvider.NeglectedGem) -> String {
        var parts = ["\(Int(gem.rating.rounded()))★", "\(gem.waitingDays) days waiting"]
        if let genre = gem.genre, !genre.isEmpty { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    static func funnelStages(_ funnel: BookOrbitProvider.ProgressFunnelComparison) -> [BookOrbitFunnelStage] {
        let current = funnel.current
        let previous = funnel.previous
        return [
            ("Started", current.started, previous?.started),
            ("Past a quarter", current.reached25, previous?.reached25),
            ("Past halfway", current.reached50, previous?.reached50),
            ("Past three quarters", current.reached75, previous?.reached75),
            ("Finished", current.completed, previous?.completed),
        ]
        .map { label, count, prior in
            var detail = "\(count)"
            if let prior, prior != count {
                detail += count > prior ? " (+\(count - prior))" : " (−\(prior - count))"
            }
            return BookOrbitFunnelStage(label: label, detail: detail, count: count)
        }
    }

    static func columns(_ daily: [BookOrbitProvider.DailyReading]) -> [(label: String, value: Double)] {
        guard !daily.isEmpty else { return [] }
        let maximumColumns = 26
        let bucketSize = max(1, Int((Double(daily.count) / Double(maximumColumns)).rounded(.up)))
        var result: [(label: String, value: Double)] = []
        var index = 0
        while index < daily.count {
            let slice = daily[index..<min(index + bucketSize, daily.count)]
            let minutes = slice.reduce(0) { $0 + $1.readingSeconds } / 60
            result.append((label: label(for: slice.first?.day, showsLabel: result.count % 4 == 0), value: minutes))
            index += bucketSize
        }
        return result
    }

    private static func label(for day: String?, showsLabel: Bool) -> String {
        guard showsLabel, let day, day.count >= 10 else { return "" }
        let parts = day.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let dayNumber = Int(parts[2]) else { return "" }
        return "\(month)/\(dayNumber)"
    }
}
