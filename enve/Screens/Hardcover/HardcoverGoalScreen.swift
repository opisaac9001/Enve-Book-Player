import SwiftUI

struct HardcoverGoalScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var goal: HardcoverReadingGoalLegacy?
    @State private var loaded = false
    @State private var editorShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Reading goal")

                if !loaded {
                    HardcoverLoading()
                } else if let goal {
                    ring(goal)
                    pace(goal)
                    QuietButton(title: "Change the goal", systemImage: "pencil") {
                        editorShown = true
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    noGoal
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await hardcoverLoadGoal() }
        .sheet(isPresented: $editorShown) {
            HardcoverGoalEditorSheet(currentTarget: goal?.target ?? 12) { target in
                Task {
                    try? await HardcoverService.shared.setReadingGoal(target: target)
                    await hardcoverLoadGoal()
                }
            }
        }
    }

    private func ring(_ goal: HardcoverReadingGoalLegacy) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(hearth.hairline, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(goal.progress, 1))
                    .stroke(hearth.ember, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.35), value: goal.progress)
                VStack(spacing: 4) {
                    Text("\(goal.current)")
                        .font(.hearthDisplay(52))
                        .foregroundStyle(hearth.text)
                    Text("of \(goal.target)")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, 8)

            Text(goal.progress >= 1 ? "Done, with the year still going." : "\(Int(goal.progress * 100)) percent of the way there.")
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func pace(_ goal: HardcoverReadingGoalLegacy) -> some View {
        let remaining = max(0, goal.target - goal.current)
        let daysLeft = hardcoverDaysRemainingInYear()
        let perMonth = daysLeft > 0 ? Double(remaining) / (Double(daysLeft) / 30) : 0
        let perWeek = daysLeft > 0 ? Double(remaining) / (Double(daysLeft) / 7) : 0

        return VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "The pace")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                paceCell(value: "\(remaining)", label: "Books left")
                paceCell(value: "\(daysLeft)", label: "Days remaining")
                paceCell(value: String(format: "%.1f", perMonth), label: "Per month")
                paceCell(value: String(format: "%.1f", perWeek), label: "Per week")
            }
            .padding(.horizontal, 24)
        }
    }

    private func paceCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.hearthDisplay(28))
                .foregroundStyle(hearth.text)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private var noGoal: some View {
        VStack(spacing: 20) {
            HardcoverEmpty(
                glyph: "target",
                title: "No goal set yet.",
                line: "Name a number for the year and watch it fill."
            )
            EmberButton(title: "Set a goal", systemImage: "plus") {
                editorShown = true
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func hardcoverDaysRemainingInYear() -> Int {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        guard let endOfYear = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return 0 }
        return max(0, calendar.dateComponents([.day], from: now, to: endOfYear).day ?? 0)
    }

    private func hardcoverLoadGoal() async {
        goal = try? await HardcoverService.shared.getReadingGoal()
        loaded = true
    }
}

struct HardcoverGoalEditorSheet: View {
    let currentTarget: Int
    let onSave: (Int) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var targetInput: String

    init(currentTarget: Int, onSave: @escaping (Int) -> Void) {
        self.currentTarget = currentTarget
        self.onSave = onSave
        _targetInput = State(initialValue: "\(currentTarget)")
    }

    private var target: Int? {
        let value = Int(targetInput) ?? 0
        return value > 0 ? value : nil
    }

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 6) {
                Overline("Reading goal")
                Text("How many books this year?")
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)

            TextField("12", text: $targetInput)
                .keyboardType(.numberPad)
                .font(.hearthDisplay(52))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(hearth.bg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }

            HStack(spacing: 10) {
                ForEach([12, 24, 36, 52], id: \.self) { preset in
                    HearthChip(title: "\(preset)", isSelected: targetInput == "\(preset)") {
                        targetInput = "\(preset)"
                    }
                }
            }

            EmberButton(title: "Keep this goal", systemImage: nil, tint: nil) {
                guard let target else { return }
                onSave(target)
                PlatformHaptics.notification(.success)
                dismiss()
            }
            .disabled(target == nil)
            .opacity(target == nil ? 0.5 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(380)])
        .hearthPresentationBackground()
    }
}
