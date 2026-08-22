import SwiftUI

struct AchievementsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var listening = JournalListeningStatsModel()
    @State private var reading = JournalReadingStatsModel()
    @State private var loaded = false
    @State private var goalInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "Goals and honors", title: "Achievements")

                if !loaded {
                    JournalLoadingNote(text: "Opening the record…")
                } else {
                    todayCard
                    weeklyGoalCard
                    monthlyBooksCard
                    streaksCard
                    streakBadgesCard
                    EnveAchievementsCard()
                    achievementsCard
                    importLink
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
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await listening.refresh()
            await reading.refresh()
        }
        .task {
            await listening.refresh()
            await reading.refresh()
            goalInput = listening.weeklyGoalHours > 0 ? String(format: "%.1f", listening.weeklyGoalHours) : ""
            loaded = true
        }
        .onAppear {
            listening.startLiveUpdates()
            reading.startLiveUpdates()
        }
        .onDisappear {
            listening.stopLiveUpdates()
            reading.stopLiveUpdates()
        }
    }

    private var achievementsMergedDaily: [String: TimeInterval] {
        listening.snapshot.dailySeconds.merging(reading.snapshot.dailySecondsRead, uniquingKeysWith: +)
    }

    private var achievementsCurrentStreak: Int {
        JournalStats.streak(achievementsMergedDaily)
    }

    private var achievementsTodayMinutes: Int {
        Int(achievementsMergedDaily[JournalStats.dayKey(for: .now), default: 0] / 60)
    }

    private var achievementsDailyGoalMinutes: Int {
        listening.weeklyGoalHours > 0 ? max(1, Int(listening.weeklyGoalHours * 60 / 7)) : 30
    }

    private var achievementsBooksThisMonth: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        return listening.snapshot.perBook.values.filter { stat in
            guard stat.isCompleted, let lastPlayed = stat.lastPlayed else { return false }
            return lastPlayed >= cutoff
        }.count
    }

    private var todayCard: some View {
        let today = achievementsTodayMinutes
        let goal = achievementsDailyGoalMinutes
        let met = today >= goal
        return JournalCard("Today") {
            HStack(spacing: 18) {
                JournalGoalRing(
                    fraction: Double(today) / Double(goal),
                    centerValue: "\(today)",
                    centerUnit: "min"
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(met ? "The day's goal, kept." : "\(goal - today) minutes to go")
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(met ? hearth.statusOK : hearth.text)
                    Text("Daily goal: \(goal) minutes")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var weeklyGoalCard: some View {
        JournalCard("Weekly goal") {
            if listening.weeklyGoalHours > 0 {
                JournalMeterRow(
                    label: "This week",
                    detail:
                        "\(JournalStatsFormat.hours(listening.weeklyHours())) of \(JournalStatsFormat.hours(listening.weeklyGoalHours))",
                    fraction: listening.weeklyGoalProgress(),
                    tint: listening.weeklyGoalProgress() >= 1 ? hearth.statusOK : nil
                )
            } else {
                JournalQuietNote(text: "No goal set. Choose the hours of listening you mean to keep each week.")
            }
            HStack(spacing: 10) {
                TextField("Hours", text: $goalInput)
                    .keyboardType(.decimalPad)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(hearth.bg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            )
                    }
                QuietButton(title: "Set") {
                    guard let hours = Double(goalInput), hours >= 0 else { return }
                    listening.setWeeklyGoal(hours: hours)
                }
            }
        }
    }

    private var monthlyBooksCard: some View {
        let goal = listening.monthlyBookGoal
        let finished = achievementsBooksThisMonth
        return JournalCard("Books this month") {
            JournalMeterRow(
                label: "Finished in the last thirty days",
                detail: "\(finished) of \(goal)",
                fraction: goal > 0 ? min(Double(finished) / Double(goal), 1) : 0,
                tint: finished >= goal ? hearth.statusOK : nil
            )
            HStack(spacing: 14) {
                GlyphButton(systemImage: "minus", glyphSize: 14, label: "Lower the monthly goal") {
                    listening.setMonthlyBookGoal(count: max(1, goal - 1))
                }
                Text("\(goal) \(goal == 1 ? "book" : "books")")
                    .font(.hearthDisplay(18, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .frame(minWidth: 80)
                GlyphButton(systemImage: "plus", glyphSize: 14, label: "Raise the monthly goal") {
                    listening.setMonthlyBookGoal(count: goal + 1)
                }
            }
        }
    }

    private var streaksCard: some View {
        JournalCard("Streaks") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: "\(listening.snapshot.streak.current)", label: "Listening, current")
                JournalStatTile(value: "\(listening.snapshot.streak.longest)", label: "Listening, best")
                JournalStatTile(value: "\(reading.snapshot.streak.current)", label: "Reading, current")
                JournalStatTile(value: "\(reading.snapshot.streak.longest)", label: "Reading, best")
            }
        }
    }

    private var streakBadgesCard: some View {
        let current = achievementsCurrentStreak
        let thresholds = [7, 30, 100]
        return JournalCard("Streak badges") {
            HStack(spacing: 12) {
                ForEach(thresholds, id: \.self) { days in
                    let earned = current >= days
                    VStack(spacing: 8) {
                        Image(systemName: earned ? "checkmark.seal.fill" : "lock.fill")
                            .font(.hearthUI(18, weight: .medium))
                            .foregroundStyle(earned ? hearth.ember : hearth.textTertiary)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(earned ? hearth.emberSoft : hearth.hairline))
                        Text("\(days) nights")
                            .font(.hearthUI(12, weight: .medium))
                            .foregroundStyle(earned ? hearth.text : hearth.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(days)-night streak badge, \(earned ? "earned" : "not yet earned")")
                }
            }
            Text(current == 1 ? "1 night running" : "\(current) nights running")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private struct AchievementsItem: Identifiable {
        let id: String
        let title: String
        let glyph: String
        let domain: String
        let earned: Bool
    }

    private var achievementsCatalog: [AchievementsItem] {
        let earnedListening = Set(listening.badges.map(\.id))
        let earnedReading = Set(reading.badges.map(\.id))
        let listeningRun: [(String, String, String)] = [
            ("first_hour", "First hour", "1.circle.fill"),
            ("ten_hours", "10 hours", "10.circle.fill"),
            ("fifty_hours", "50 hours", "star.circle.fill"),
            ("fin_5", "5 finished", "checkmark.circle.fill"),
            ("fin_20", "Book finisher", "book.fill"),
            ("consistency_80", "Consistency", "calendar.badge.clock"),
        ]
        let readingRun: [(String, String, String)] = [
            ("first_hour", "First hour", "1.circle.fill"),
            ("ten_hours", "10 hours", "10.circle.fill"),
            ("fifty_hours", "50 hours", "star.circle.fill"),
            ("fin_1", "First finish", "book.closed.fill"),
            ("fin_5", "5 books done", "checkmark.circle.fill"),
            ("fin_20", "Voracious reader", "books.vertical.fill"),
            ("pages_1k", "A thousand pages", "doc.text.fill"),
            ("streak_7", "Week streak", "flame.fill"),
            ("consistency", "Consistency", "calendar.badge.clock"),
        ]
        return listeningRun.map { id, title, glyph in
            AchievementsItem(id: "listening.\(id)", title: title, glyph: glyph, domain: "Listening", earned: earnedListening.contains(id))
        }
            + readingRun.map { id, title, glyph in
                AchievementsItem(id: "reading.\(id)", title: title, glyph: glyph, domain: "Reading", earned: earnedReading.contains(id))
            }
    }

    private var achievementsCard: some View {
        JournalCard("The full run") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 18) {
                ForEach(achievementsCatalog) { item in
                    VStack(spacing: 7) {
                        Image(systemName: item.earned ? item.glyph : "lock.fill")
                            .font(.hearthUI(17, weight: .medium))
                            .foregroundStyle(item.earned ? hearth.ember : hearth.textTertiary)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(item.earned ? hearth.emberSoft : hearth.hairline))
                        Text(item.title)
                            .font(.hearthUI(11, weight: .medium))
                            .foregroundStyle(item.earned ? hearth.text : hearth.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Overline(item.domain, color: hearth.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .accessibilityLabel("\(item.domain) achievement, \(item.title), \(item.earned ? "earned" : "not yet earned")")
                }
            }
        }
    }

    private var importLink: some View {
        NavigationLink {
            StatsImportScreen()
        } label: {
            JournalLinkRow(
                glyph: "square.and.arrow.down",
                title: "Import listening stats",
                subtitle: "Carry hours over from other apps"
            )
        }
        .buttonStyle(PressableStyle())
    }
}
