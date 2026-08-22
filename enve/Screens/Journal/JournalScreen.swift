import Combine
import SwiftUI

struct JournalScreen: View {

    var isActive: Bool = true

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var weekListening: TimeInterval = 0
    @State private var weekReading: TimeInterval = 0
    @State private var streak = 0
    @State private var daily: [String: TimeInterval] = [:]
    @State private var hasHeatmap = false
    @State private var quotes: [JournalQuote] = []
    @State private var finished: [Book] = []
    @State private var loaded = false

    private static let refreshSignal: AnyPublisher<Void, Never> = Publishers.MergeMany(
        [Notification.Name.bookStoreDidChange, .bookProgressDidChange, .listeningStatsDidChange, .readingStatsDidChange]
            .map { NotificationCenter.default.publisher(for: $0).map { _ in () }.eraseToAnyPublisher() }
    )
    .throttle(for: .seconds(15), scheduler: DispatchQueue.main, latest: true)
    .eraseToAnyPublisher()

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header

                    if loaded && isJournalEmpty {
                        Text("The journal opens when the reading begins.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                    }

                    if weekListening > 0 || weekReading > 0 {
                        thisWeek
                    }

                    if streak > 0 {
                        streakRow
                    }

                    if hasHeatmap {
                        VStack(alignment: .leading, spacing: 14) {
                            ShelfHeader(title: "The past year")
                            JournalHeatmap(daily: daily, width: geo.size.width - 48)
                                .padding(.horizontal, 24)
                        }
                    }

                    if !quotes.isEmpty {
                        marginalia
                    }

                    if !finished.isEmpty {
                        mantel(width: geo.size.width - 48)
                    }

                    closerLook
                }
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .task(id: isActive) {
            guard isActive else { return }
            await load()
            loaded = true
        }
        .onReceive(Self.refreshSignal) { _ in
            guard isActive else { return }
            Task { await load() }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Overline("Your reading life")
                Text("Journal")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer()
            NavigationLink {
                SettingsScreen()
            } label: {
                Image(systemName: "gearshape")
                    .font(.hearthUI(17, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(hearth.bgElevated)
                            .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 24)
    }

    private var thisWeek: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "This week")
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                JournalWeekNumber(seconds: weekListening, label: "Listening")
                JournalWeekNumber(seconds: weekReading, label: "Reading")
            }
            .padding(.horizontal, 24)
        }
    }

    private var streakRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.ember)
            Text(streak == 1 ? "1 night running" : "\(streak) nights running")
                .font(.hearthDisplay(18, weight: .semibold))
                .foregroundStyle(hearth.text)
        }
        .padding(.horizontal, 24)
    }

    private var marginalia: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Overline("Marginalia")
                Spacer()
                NavigationLink {
                    JournalMarginaliaScreen()
                } label: {
                    Text("See all")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(quotes) { quote in
                    JournalQuoteView(text: quote.annotation.text, attribution: quote.book.title)
                    if quote.id != quotes.last?.id {
                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func mantel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Overline("The Mantel")
                Spacer()
                NavigationLink {
                    CompletionCenterScreen()
                } label: {
                    Text("See all")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 24)
            let cellWidth = max(1, (width - 32) / 3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16) {
                ForEach(finished, id: \.stableId) { book in
                    NavigationLink {
                        BookDetailScreen(book: book)
                    } label: {
                        ShelfCoverCell(book: book, width: cellWidth, showsProgress: false)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var closerLook: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "A closer look")
            VStack(spacing: 2) {
                NavigationLink {
                    JournalServicesScreen()
                } label: {
                    JournalLinkRow(glyph: "chart.bar.xaxis", title: "Stats Hub", subtitle: "All services, or one at a time")
                }
                NavigationLink {
                    JournalInsightsScreen()
                } label: {
                    JournalLinkRow(glyph: "chart.xyaxis.line", title: "Insights", subtitle: "Your rhythm, favorites, and year in review")
                }
                NavigationLink {
                    JournalListeningStatsScreen()
                } label: {
                    JournalLinkRow(glyph: "headphones", title: "Listening", subtitle: "Hours, standing, the authors you return to")
                }
                NavigationLink {
                    JournalReadingStatsScreen()
                } label: {
                    JournalLinkRow(glyph: "book", title: "Reading", subtitle: "Time in the text and pages turned")
                }
                NavigationLink {
                    SleepInsightsScreen()
                } label: {
                    JournalLinkRow(
                        glyph: "bed.double.fill",
                        title: "Sleep stats",
                        subtitle: "Stages, trends, and bedtime listening patterns"
                    )
                }
                NavigationLink {
                    CompletionCenterScreen()
                } label: {
                    JournalLinkRow(glyph: "checkmark.seal", title: "Finished", subtitle: "The final stretch and books completed")
                }
                NavigationLink {
                    PodcastStatsScreen()
                } label: {
                    JournalLinkRow(
                        glyph: "antenna.radiowaves.left.and.right",
                        title: "Podcasts",
                        subtitle: "Shows and episodes, by the hour"
                    )
                }
                NavigationLink {
                    AchievementsScreen()
                } label: {
                    JournalLinkRow(glyph: "rosette", title: "Achievements", subtitle: "Goals kept, streaks, honors earned")
                }
                NavigationLink {
                    JournalLibraryStatsScreen()
                } label: {
                    JournalLinkRow(glyph: "books.vertical", title: "Library", subtitle: "The whole collection, counted")
                }
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, 24)
        }
    }

    private var isJournalEmpty: Bool {
        weekListening <= 0 && weekReading <= 0 && streak == 0 && !hasHeatmap
            && quotes.isEmpty && finished.isEmpty
    }

    private func load() async {
        let listening = await ListeningStatsTracker.shared.currentSnapshot()
        let reading = await ReadingStatsTracker.shared.currentSnapshot()

        weekListening = JournalStats.weekTotal(listening.dailySeconds)
        weekReading = JournalStats.weekTotal(reading.dailySecondsRead)
        daily = listening.dailySeconds.merging(reading.dailySecondsRead, uniquingKeysWith: +)
        streak = JournalStats.streak(daily)
        hasHeatmap = JournalStats.hasActivity(daily, withinDays: JournalHeatmap.weeks * 7)

        quotes = await engine.journal.recentQuotes(limit: 5)
        finished = await engine.journal.recentlyFinishedBooks(limit: 6)
    }
}

private struct JournalWeekNumber: View {
    let seconds: TimeInterval
    let label: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HearthFormat.duration(seconds))
                .font(.hearthDisplay(36))
                .foregroundStyle(hearth.text)
            Overline(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JournalQuoteView: View {
    let text: String
    let attribution: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\u{201C}\(cleaned)\u{201D}")
                .font(.hearthDisplay(17, weight: .regular))
                .foregroundStyle(hearth.text)
                .lineSpacing(3)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            Overline(attribution, color: hearth.textTertiary)
        }
    }

    private var cleaned: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum JournalStats {
    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        return fmt
    }()

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    static func weekTotal(_ daily: [String: TimeInterval]) -> TimeInterval {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<7).reduce(0) { sum, back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return sum }
            return sum + daily[dayKey(for: day), default: 0]
        }
    }

    static func streak(_ daily: [String: TimeInterval]) -> Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: .now)

        if daily[dayKey(for: day), default: 0] <= 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while daily[dayKey(for: day), default: 0] > 0 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    static func hasActivity(_ daily: [String: TimeInterval], withinDays days: Int) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for back in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            if daily[dayKey(for: day), default: 0] > 0 { return true }
        }
        return false
    }
}
