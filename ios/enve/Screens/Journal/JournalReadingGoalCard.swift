#if os(iOS)
import SwiftUI

struct JournalReadingGoalCard: View {
    let store: ReadingGoalStore
    let dailySeconds: [String: TimeInterval]

    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var activatedAt = Date.now
    @State private var editorShown = false

    var body: some View {
        Group {
            if store.dailyMinutes == nil {
                offCard
            } else {
                // Re-evaluates today's ledger bucket across midnight and time zone changes.
                TimelineView(.everyMinute) { context in
                    if let progress = store.progress(dailySeconds: dailySeconds, on: context.date) {
                        goalCard(progress)
                    }
                }
                .id(activatedAt)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activatedAt = .now }
        }
        .sheet(isPresented: $editorShown) {
            JournalReadingGoalEditor(store: store)
                .enveEnvironment()
        }
    }

    private var offCard: some View {
        JournalCard("Daily reading goal") {
            Text("Give each day a few quiet minutes in a book.")
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(readingGoalLedgerNote)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Set daily goal", systemImage: "target") { editorShown = true }
        }
    }

    private func goalCard(_ progress: ReadingGoalProgress) -> some View {
        let summary = "\(progress.completedMinutes) of \(minutesPhrase(progress.targetMinutes))"
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return JournalCard("Today's goal") {
            layout {
                Text(summary)
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button { editorShown = true } label: {
                    Text("Edit")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Edit daily reading goal")
            }
            ProgressView(value: progress.fraction)
                .tint(hearth.ember)
                .accessibilityLabel("Today's reading goal")
                .accessibilityValue(summary)
            Text(progress.isComplete ? "Goal reached for today." : "\(minutesPhrase(progress.remainingMinutes)) to go today.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
            Text(readingGoalLedgerNote)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct JournalReadingGoalEditor: View {
    let store: ReadingGoalStore

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Int

    private static let presets = [10, 20, 30, 60]

    init(store: ReadingGoalStore) {
        self.store = store
        _draft = State(initialValue: store.dailyMinutes ?? ReadingGoalStore.suggestedMinutes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Daily reading goal")
                    Text("Minutes a day")
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
                .padding(.top, 24)

                Text(readingGoalLedgerNote)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                JournalCard {
                    Stepper(value: $draft, in: ReadingGoalStore.minuteRange) {
                        Text(minutesPhrase(draft))
                            .font(.hearthDisplay(22, weight: .semibold))
                            .foregroundStyle(hearth.text)
                    }
                    .accessibilityLabel("Daily goal")
                    .accessibilityValue(minutesPhrase(draft))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { presetChips }
                    VStack(alignment: .leading, spacing: 8) { presetChips }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 12) { actions }
                }

                if store.dailyMinutes != nil {
                    Button {
                        store.setDailyMinutes(nil)
                        dismiss()
                    } label: {
                        Text("Turn off daily goal")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.textSecondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.medium, .large])
        .hearthPresentationBackground()
    }

    @ViewBuilder
    private var presetChips: some View {
        ForEach(Self.presets, id: \.self) { minutes in
            HearthChip(title: "\(minutes) min", isSelected: draft == minutes) { draft = minutes }
                .accessibilityLabel(minutesPhrase(minutes))
        }
    }

    @ViewBuilder
    private var actions: some View {
        QuietButton(title: "Cancel") { dismiss() }
        EmberButton(title: "Save") {
            store.setDailyMinutes(draft)
            dismiss()
        }
    }
}

private let readingGoalLedgerNote = "Counts recorded ebook reading time, separate from listening. Updates as your reading is saved."

private func minutesPhrase(_ minutes: Int) -> String {
    minutes == 1 ? "1 minute" : "\(minutes) minutes"
}
#endif
