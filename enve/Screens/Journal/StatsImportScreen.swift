import SwiftUI

struct StatsImportScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = JournalListeningStatsModel()
    @State private var loaded = false
    @State private var importing = false
    @State private var confirmation: String?

    @State private var months = ""
    @State private var days = ""
    @State private var hours = ""
    @State private var minutes = ""
    @State private var booksFinished = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "Carried over", title: "Import stats")

                Text("Enter your time exactly as the other app states it. It is added to your totals here, never written over them.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                entryCard

                if let confirmation {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.hearthUI(14))
                            .foregroundStyle(hearth.statusOK)
                        Text(confirmation)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.text)
                    }
                }

                currentCard
                howToCard
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
        .task {
            await model.refresh()
            loaded = true
        }
    }

    private var importHasInput: Bool {
        [months, days, hours, minutes, booksFinished].contains { (Int($0) ?? 0) > 0 }
    }

    private var entryCard: some View {
        JournalCard("The time to add") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    importField("Months", text: $months)
                    importField("Days", text: $days)
                }
                HStack(spacing: 12) {
                    importField("Hours", text: $hours)
                    importField("Minutes", text: $minutes)
                }
                importField("Books finished", text: $booksFinished)
            }
            EmberButton(title: importing ? "Adding…" : "Add to the ledger", systemImage: "plus") {
                importAdd()
            }
            .disabled(!importHasInput || importing)
            .opacity(importHasInput && !importing ? 1 : 0.5)
            Text("If the app reads \u{201C}2 months 27 days 14 hours 28 minutes\u{201D}, enter exactly that.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func importField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Overline(title, color: hearth.textTertiary)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hearth.bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        )
                }
        }
        .frame(maxWidth: .infinity)
    }

    private func importAdd() {
        let monthsValue = Int(months) ?? 0
        let daysValue = Int(days) ?? 0
        let hoursValue = Int(hours) ?? 0
        let minutesValue = Int(minutes) ?? 0
        let booksValue = Int(booksFinished) ?? 0
        guard monthsValue > 0 || daysValue > 0 || hoursValue > 0 || minutesValue > 0 || booksValue > 0 else { return }

        let totalHours =
            Double(monthsValue) * 720 + Double(daysValue) * 24
            + Double(hoursValue) + Double(minutesValue) / 60

        importing = true
        Task {
            await ListeningStatsTracker.shared.addManualListeningTime(
                seconds: totalHours * 3600,
                booksFinished: booksValue
            )
            await model.refresh()
            importing = false

            var parts: [String] = []
            if monthsValue > 0 { parts.append("\(monthsValue) months") }
            if daysValue > 0 { parts.append("\(daysValue) days") }
            if hoursValue > 0 { parts.append("\(hoursValue) hours") }
            if minutesValue > 0 { parts.append("\(minutesValue) minutes") }
            if booksValue > 0 { parts.append("\(booksValue) \(booksValue == 1 ? "book" : "books")") }
            confirmation = "Added \(parts.joined(separator: " ")) to the ledger."

            months = ""
            days = ""
            hours = ""
            minutes = ""
            booksFinished = ""
        }
    }

    private var currentCard: some View {
        JournalCard("The ledger today") {
            if !loaded {
                JournalLoadingNote(text: "Tallying the hours…")
            } else {
                VStack(spacing: 12) {
                    importStatRow(
                        "All time",
                        value:
                            "\(JournalStatsFormat.hours(model.snapshot.totalHours)) · \(String(format: "%.1f", model.snapshot.totalDays)) days"
                    )
                    importStatRow("This week", value: JournalStatsFormat.hours(model.weeklyHours()))
                    importStatRow("This month", value: JournalStatsFormat.hours(model.monthlyHours()))
                    importStatRow("Books finished", value: "\(model.snapshot.totalBooksFinished)")
                }
            }
        }
    }

    private func importStatRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.text)
            Spacer()
            Text(value)
                .font(.hearthUI(14, weight: .semibold))
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private var howToCard: some View {
        JournalCard("Where to find it") {
            VStack(alignment: .leading, spacing: 16) {
                importHowTo(
                    "Audiobookshelf",
                    steps: [
                        "Open your Audiobookshelf server",
                        "Go to your user profile",
                        "Look for \u{201C}Listening Time\u{201D}",
                        "Enter the months, days, hours and minutes",
                    ]
                )
                Rectangle().fill(hearth.hairline).frame(height: 1)
                importHowTo(
                    "Apple Books",
                    steps: [
                        "Open Settings, then Books",
                        "View Reading Goals",
                        "Check your listening statistics",
                    ]
                )
                Rectangle().fill(hearth.hairline).frame(height: 1)
                importHowTo(
                    "Other apps",
                    steps: [
                        "Look for a Stats or Profile section",
                        "Find the total listening time",
                        "Convert to hours if needed",
                    ]
                )
            }
        }
    }

    private func importHowTo(_ app: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(app)
                .font(.hearthDisplay(15, weight: .semibold))
                .foregroundStyle(hearth.text)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .frame(width: 18, alignment: .leading)
                    Text(step)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
