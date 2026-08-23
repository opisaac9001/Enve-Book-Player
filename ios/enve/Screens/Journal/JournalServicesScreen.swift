import SwiftUI

struct JournalServicesScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = JournalHubModel()
    @State private var loaded = false
    @State private var selectedSource: JournalStatsSource?
    @State private var showingBookOrbit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "Every source, in one place", title: "Stats Hub")

                if !loaded {
                    JournalLoadingNote(text: "Calling on the services…")
                } else {
                    sourcePicker
                    if let source = selectedSource, let stat = model.serviceStats[source] {
                        serviceDashboard(stat)
                    } else {
                        rangeChips
                        heroCard
                        if model.combinedTotalSeconds <= 0 {
                            JournalQuietNote(text: "Nothing in this window yet. The record fills as you read and listen.")
                        }
                        paceCard
                        whenCard
                        if model.bestDayDate != nil || model.longestSession != nil {
                            highlightsCard
                        }
                        activityCard
                        servicesCard
                        if !model.recentSessions.isEmpty {
                            recentCard
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingBookOrbit) {
            BookOrbitInsightsScreen()
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            loaded = true
        }
        .onAppear { model.startLiveUpdates() }
        .onDisappear { model.stopLiveUpdates() }
    }

    private var rangeChips: some View {
        HStack(spacing: 8) {
            ForEach(JournalStatsRange.allCases) { range in
                HearthChip(title: range.rawValue, isSelected: model.selectedRange == range) {
                    model.selectedRange = range
                    model.recomputeCombined()
                }
            }
        }
    }

    private var sourcePicker: some View {
        Menu {
            Button("All services") { selectedSource = nil }
            ForEach(JournalStatsSource.allCases.filter { model.serviceStats[$0]?.isAvailable == true }) { source in
                Button(source.displayName) { selectedSource = source }
            }
            if BookOrbitAccess.isAvailable {
                Divider()
                Button("BookOrbit") { showingBookOrbit = true }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedSource?.systemImage ?? "square.stack.3d.up")
                Text(selectedSource?.displayName ?? "All services")
                    .font(.hearthUI(14, weight: .medium))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hearthUI(11, weight: .semibold))
            }
            .foregroundStyle(hearth.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14).fill(hearth.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hearth.hairline, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func serviceDashboard(_ stat: JournalServiceStats) -> some View {
        if selectedSource == .grimmory, let insights = model.grimmoryInsights, insights.hasData {
            GrimmoryStatsDashboard(stats: insights)
        } else {
            JournalCard(stat.serviceName) {
                JournalAllTimeFigure(seconds: stat.totalSeconds)
                Text("\(JournalStatsFormat.hours(stat.totalHours)) reported by this service")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                    JournalStatTile(value: "\(stat.sessionsCount)", label: "Sessions")
                    JournalStatTile(value: "\(stat.booksFinished)", label: "Books finished")
                    JournalStatTile(value: "\(stat.booksInProgress)", label: "Underway")
                    JournalStatTile(value: stat.pagesRead > 0 ? stat.pagesRead.formatted() : stat.totalBooks.formatted(), label: stat.pagesRead > 0 ? "Pages read" : "Books touched")
                    JournalStatTile(value: "\(stat.currentStreak)", label: "Nights running")
                    JournalStatTile(value: "\(stat.longestStreak)", label: "Longest run")
                }
            }

            if !stat.dailySeconds.isEmpty {
                JournalCard("Activity") {
                    JournalColumns(
                        columns: serviceActivityColumns(stat),
                        height: 110
                    )
                }
            }
        }

        if let error = selectedSource.flatMap({ model.serviceErrors[$0] }) {
            JournalCard("Connection") {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private func serviceActivityColumns(_ stat: JournalServiceStats) -> [(label: String, value: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<30).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: -29 + index, to: today) else { return nil }
            let label = index % 7 == 0 ? date.formatted(.dateTime.day()) : ""
            return (label, (stat.dailySeconds[JournalStats.dayKey(for: date)] ?? 0) / 60)
        }
    }

    private var heroCard: some View {
        JournalCard(model.selectedRange == .allTime ? "All of it, together" : "Together, \(model.selectedRange.rawValue.lowercased())") {
            JournalAllTimeFigure(seconds: model.combinedTotalSeconds)
            Text("\(JournalStatsFormat.hours(model.combinedTotalHours)) in this window")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            HStack(spacing: 16) {
                journalSplit(glyph: "headphones", label: "Listening", hours: model.listeningHours)
                journalSplit(glyph: "book", label: "Reading", hours: model.readingHours)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(model.combinedSessions)", label: "Sessions")
                JournalStatTile(value: "\(model.combinedBooksFinished)", label: "Books finished")
                JournalStatTile(value: "\(model.combinedBooksInProgress)", label: "Underway")
                if model.combinedPagesRead > 0 {
                    JournalStatTile(value: model.combinedPagesRead.formatted(), label: "Pages read")
                } else {
                    JournalStatTile(value: model.combinedTotalBooks.formatted(), label: "Books touched")
                }
                JournalStatTile(value: "\(model.combinedCurrentStreak)", label: "Nights running")
                JournalStatTile(value: "\(model.combinedLongestStreak)", label: "Longest run")
            }
        }
    }

    private func journalSplit(glyph: String, label: String, hours: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.ember)
            Text("\(label) \(JournalStatsFormat.hours(hours))")
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(hearth.emberSoft))
    }

    private var paceCard: some View {
        let minutes = model.averageMinutesPerDay()
        return JournalCard("The usual pace") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(minutes.rounded()))")
                    .font(.hearthDisplay(34))
                    .foregroundStyle(hearth.text)
                Text("minutes a day")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
            }
            Text(paceCaption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var paceCaption: String {
        switch model.selectedRange {
        case .week: "Averaged over the last seven days."
        case .month: "Averaged over the last thirty days."
        case .year: "Averaged over the last year."
        case .allTime: "Averaged over the whole record."
        }
    }

    private var whenCard: some View {
        let distribution = model.hourlyDistribution()
        let hasData = distribution.values.contains { $0 > 0 }
        return JournalCard("When you read") {
            if let peak = model.peakHourLabel() {
                Text("Most often \(peak)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.ember)
            }
            if hasData {
                JournalColumns(
                    columns: (0..<24).map { hour in
                        (label: journalHourLabel(hour), value: (distribution[hour] ?? 0) / 60)
                    },
                    height: 96
                )
            } else {
                JournalQuietNote(text: "Not enough nights on record to tell.")
            }
        }
    }

    private func journalHourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12a"
        case 6: "6a"
        case 12: "12p"
        case 18: "6p"
        default: ""
        }
    }

    private var highlightsCard: some View {
        JournalCard("Worth remembering") {
            HStack(spacing: 16) {
                if let bestDay = model.bestDayDate {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(HearthFormat.duration(model.bestDaySeconds))
                            .font(.hearthDisplay(22, weight: .semibold))
                            .foregroundStyle(hearth.text)
                        Overline("Best day · \(journalDayLabel(bestDay))", color: hearth.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let session = model.longestSession {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.formattedDuration)
                            .font(.hearthDisplay(22, weight: .semibold))
                            .foregroundStyle(hearth.text)
                        Overline("Longest sitting · \(JournalStatsFormat.relative(session.startTime))", color: hearth.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func journalDayLabel(_ dayKey: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        input.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = input.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var activityCard: some View {
        let data = model.chartData()
        let hasData = data.contains { $0.seconds > 0 }
        return JournalCard(activityTitle) {
            if hasData {
                JournalColumns(
                    columns: data.map { (label: $0.label, value: $0.seconds / 60) },
                    height: 110
                )
            } else {
                JournalQuietNote(text: "Quiet, so far.")
            }
        }
    }

    private var activityTitle: String {
        switch model.selectedRange {
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        case .allTime: "The recent record"
        }
    }

    private var servicesCard: some View {
        let active = model.sortedServiceStats.filter(\.isAvailable)
        let inactive = JournalStatsSource.allCases.filter { source in
            !(model.serviceStats[source]?.isAvailable ?? false)
        }
        return JournalCard("Service by service") {
            if active.isEmpty {
                JournalQuietNote(text: "No services reporting yet.")
            } else {
                VStack(spacing: 18) {
                    ForEach(active) { stat in
                        journalServiceRow(stat)
                    }
                }
            }
            if !inactive.isEmpty {
                Rectangle().fill(hearth.hairline).frame(height: 1)
                Text("Quiet: \(inactive.map(\.displayName).joined(separator: " · "))")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func journalServiceRow(_ stat: JournalServiceStats) -> some View {
        let source = JournalStatsSource(rawValue: stat.id)
        let error = source.flatMap { model.serviceErrors[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: stat.systemImage)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(hearth.emberSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.serviceName)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Overline(stat.category.rawValue, color: hearth.textTertiary)
                }
                Spacer()
                if stat.totalSeconds > 0 {
                    Text(JournalStatsFormat.hours(stat.totalHours))
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
            }
            Text(journalServiceCaption(stat))
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(2)
            if let error {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
                    .lineLimit(2)
            }
        }
    }

    private func journalServiceCaption(_ stat: JournalServiceStats) -> String {
        var parts: [String] = []
        if stat.sessionsCount > 0 { parts.append("\(stat.sessionsCount) sessions") }
        if stat.booksFinished > 0 { parts.append("\(stat.booksFinished) finished") }
        if stat.booksInProgress > 0 { parts.append("\(stat.booksInProgress) underway") }
        if stat.pagesRead > 0 { parts.append("\(stat.pagesRead.formatted()) pages") }
        if stat.currentStreak > 0 { parts.append("\(stat.currentStreak)-night run") }
        if parts.isEmpty { parts.append("\(stat.totalBooks.formatted()) books on record") }
        return parts.joined(separator: " · ")
    }

    private var recentCard: some View {
        JournalCard("Lately") {
            VStack(spacing: 14) {
                ForEach(model.recentSessions.prefix(12)) { session in
                    JournalSessionRow(session: session)
                }
            }
        }
    }
}
