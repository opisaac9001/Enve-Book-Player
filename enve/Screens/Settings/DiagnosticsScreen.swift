#if DEBUG
import SwiftUI

struct DiagnosticsScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var scenario: SyntheticLibrarySeeder.Scenario = .mixed
    @State private var targetCount = 50_000
    @State private var isSeeding = false
    @State private var progressText = ""
    @State private var currentCount = 0
    @State private var syncResults: [SyncConflictScenarioResult] = []
    @State private var guardrailResults: [ImportGuardrailFixtureResult] = []

    private let countOptions = [5_000, 50_000, 100_000]

    var body: some View {
        SettingsScaffold(
            overline: "Developer & admin",
            title: "Diagnostics",
            subtitle: "Synthetic-library tooling, debug builds only."
        ) {
            seederCard
            storeCard
            syncScenariosCard
            guardrailsCard
        }
        .task {
            currentCount = await SyntheticLibrarySeeder.shared.currentBookCount()
        }
    }

    private var seederCard: some View {
        SourcesCard {
            Overline("Synthetic library")
            SettingsMenuRow(title: "Scenario", value: scenario.displayName) {
                ForEach(SyntheticLibrarySeeder.Scenario.allCases) { option in
                    Button(option.displayName) { scenario = option }
                }
            }
            HStack(spacing: 10) {
                ForEach(countOptions, id: \.self) { count in
                    HearthChip(title: count.formatted(), isSelected: targetCount == count) {
                        targetCount = count
                    }
                }
            }
            EmberButton(
                title: isSeeding ? "Seeding…" : "Seed \(targetCount.formatted()) books",
                systemImage: isSeeding ? nil : "books.vertical",
                tint: nil
            ) {
                Task { await seed() }
            }
            .disabled(isSeeding)
            QuietButton(title: "Remove synthetic library", systemImage: "trash") {
                Task { await teardown() }
            }
            .disabled(isSeeding)
            if !progressText.isEmpty {
                Text(progressText)
                    .font(.hearthCaption.monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var storeCard: some View {
        SourcesCard {
            Overline("Store")
            HStack {
                Text("Books in the store")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                Text(currentCount.formatted())
                    .font(.hearthBody.monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
            }
            QuietButton(title: "Refresh count", systemImage: "arrow.clockwise") {
                Task { currentCount = await SyntheticLibrarySeeder.shared.currentBookCount() }
            }
        }
    }

    private var syncScenariosCard: some View {
        SourcesCard {
            Overline("Sync conflict scenarios")
            QuietButton(title: "Run deterministic scenarios", systemImage: "play") {
                syncResults = SyncConflictScenarioRunner.run()
            }
            ForEach(syncResults) { result in
                diagnosticsResultRow(
                    name: result.name,
                    passed: result.passed,
                    detail: result.passed ? "PASS" : "\(String(describing: result.actual)) ≠ \(String(describing: result.expected))"
                )
            }
        }
    }

    private var guardrailsCard: some View {
        SourcesCard {
            Overline("Import guardrail fixtures")
            QuietButton(title: "Run import guardrails", systemImage: "play") {
                Task { guardrailResults = await ImportGuardrailFixtureRunner.run() }
            }
            ForEach(guardrailResults) { result in
                diagnosticsResultRow(
                    name: result.name,
                    passed: result.passed,
                    detail: result.passed ? "PASS" : result.detail
                )
            }
        }
    }

    private func diagnosticsResultRow(name: String, passed: Bool, detail: String) -> some View {
        HStack {
            Text(name)
                .font(.hearthCaption)
                .foregroundStyle(hearth.text)
            Spacer()
            Text(detail)
                .font(.hearthCaption.monospaced())
                .foregroundStyle(passed ? hearth.statusOK : hearth.statusError)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func seed() async {
        isSeeding = true
        progressText = "Starting…"
        let signpost = PerfSignpost.begin("synthetic-seed", "\(targetCount) \(scenario.rawValue)")
        await SyntheticLibrarySeeder.shared.seed(count: targetCount, scenario: scenario) { progress in
            progressText = "Wrote \(progress.written.formatted()) / \(progress.total.formatted()) · \(PerfSignpost.residentMemoryMB()) MB"
        }
        PerfSignpost.end(signpost)
        currentCount = await SyntheticLibrarySeeder.shared.currentBookCount()
        progressText = "Done. \(currentCount.formatted()) books in store."
        isSeeding = false
    }

    private func teardown() async {
        isSeeding = true
        progressText = "Removing…"
        await SyntheticLibrarySeeder.shared.teardown()
        currentCount = await SyntheticLibrarySeeder.shared.currentBookCount()
        progressText = "Synthetic library removed."
        isSeeding = false
    }
}
#endif
