import SwiftUI

@MainActor
@Observable
final class EnveAchievementsModel {
    private(set) var tally = EnveAchievementTally()
    private(set) var achievements: [EnveAchievement] = []
    private(set) var loaded = false

    private let journal: JournalEngine
    private let books: any BookQuerying

    init(
        journal: JournalEngine = EnveEngine.shared.journal,
        books: any BookQuerying = AppState.shared.bookStore
    ) {
        self.journal = journal
        self.books = books
    }

    var earnedCount: Int { achievements.filter(\.earned).count }

    var sourceLine: String {
        let count = tally.sources.count
        guard count > 0 else { return "Counted across every source you read from." }
        return "Counted once across \(count) \(count == 1 ? "source" : "sources"), duplicates removed."
    }

    func refresh() async {
        async let listening = HistorySessionStore.shared.loadListeningSessions()
        async let reading = HistorySessionStore.shared.loadReadingSessions()
        async let remote = journal.remoteHistorySessions()
        async let library = books.finishedBookSummaries()

        let sessions = await listening + reading + remote
        let finishedBooks = await library
        tally = EnveAchievementsPolicy.tally(sessions: sessions, finishedBooks: finishedBooks)
        achievements = EnveAchievementsPolicy.achievements(tally)
        loaded = true
    }
}

struct EnveAchievementsCard: View {
    @Environment(\.hearth) private var hearth

    @State private var model = EnveAchievementsModel()

    var body: some View {
        JournalCard("Milestones · every source") {
            if !model.loaded {
                JournalLoadingNote(text: "Counting the whole record…")
            } else {
                summary
                if let next = EnveAchievementsPolicy.nextUp(model.achievements) {
                    Rectangle().fill(hearth.hairline).frame(height: 1)
                    JournalMeterRow(label: next.title, detail: next.detail, fraction: next.fraction)
                }
                Rectangle().fill(hearth.hairline).frame(height: 1)
                grid
                Text(model.sourceLine)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .task { await model.refresh() }
    }

    private var summary: some View {
        HStack(spacing: 18) {
            JournalGoalRing(
                fraction: model.achievements.isEmpty
                    ? 0 : Double(model.earnedCount) / Double(model.achievements.count),
                centerValue: "\(model.earnedCount)",
                centerUnit: "earned"
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.earnedCount) of \(model.achievements.count)")
                    .font(.hearthDisplay(20, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(
                    "\(EnveAchievementsPolicy.hoursLabel(model.tally.totalHours)) across "
                        + "\(model.tally.sessionCount) \(model.tally.sessionCount == 1 ? "sitting" : "sittings")"
                )
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                Text("\(model.tally.finishedBooks) finished · \(model.tally.streak) night streak")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            Spacer()
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 18) {
            ForEach(model.achievements) { achievement in
                badge(achievement)
            }
        }
    }

    private func badge(_ achievement: EnveAchievement) -> some View {
        VStack(spacing: 7) {
            Image(systemName: achievement.earned ? achievement.systemImage : "lock.fill")
                .font(.hearthUI(17, weight: .medium))
                .foregroundStyle(achievement.earned ? hearth.ember : hearth.textTertiary)
                .frame(width: 46, height: 46)
                .background(Circle().fill(achievement.earned ? hearth.emberSoft : hearth.hairline))
            Text(achievement.title)
                .font(.hearthUI(11, weight: .medium))
                .foregroundStyle(achievement.earned ? hearth.text : hearth.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Overline(achievement.group, color: hearth.textTertiary)
            if !achievement.earned, achievement.fraction > 0 {
                Ribbon(progress: achievement.fraction, tint: hearth.ember, height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(achievement.group) milestone, \(achievement.title), \(achievement.earned ? "earned" : "not yet earned")")
        .accessibilityValue(achievement.detail)
    }
}
