import HealthKit
import SwiftUI

@MainActor
@Observable
final class SleepInsightsModel {
    enum Phase {
        case loading, unavailable, needsAccess, empty, failed, loaded
    }

    private(set) var phase: Phase = .loading
    private(set) var summary: SleepInsightsSummary?
    private(set) var bookTitles: [String: String] = [:]
    private(set) var isRequestingAccess = false

    @ObservationIgnored private var hasLoaded = false

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        #if DEBUG
        if SleepInsightsFixture.isActive {
            let reference = Date()
            summary = SleepInsightsBuilder.summary(
                samples: SleepInsightsFixture.samples(reference: reference),
                sessions: SleepInsightsFixture.sessions(reference: reference)
            )
            bookTitles = SleepInsightsFixture.bookTitles
            phase = summary == nil ? .empty : .loaded
            return
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else {
            phase = .unavailable
            return
        }
        guard SleepDataService.shared.hasRequestedAuthorization else {
            phase = .needsAccess
            return
        }
        await fetch()
    }

    func connect() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            try await SleepDataService.shared.requestAuthorization()
        } catch {
            phase = .failed
            return
        }
        await fetch()
    }

    private func fetch() async {
        phase = .loading
        do {
            let samples = try await SleepDataService.shared.fetchSleepAnalysis(daysBack: 30)
            let sessions = await HistorySessionStore.shared.loadListeningSessions()
            guard let built = SleepInsightsBuilder.summary(samples: samples, sessions: sessions) else {
                phase = .empty
                return
            }
            summary = built
            let ids = Set(built.nights.compactMap { $0.listening?.bookId })
            if !ids.isEmpty {
                bookTitles = await JournalStatsBookLookup.build(ids: ids).mapValues(\.title)
            }
            phase = .loaded
        } catch {
            phase = .failed
        }
    }
}

struct PlayerSleepInsightsView: View {
    let tint: Color
    let model: SleepInsightsModel

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.phase {
            case .loading:
                loadingState
            case .unavailable:
                infoCard(
                    glyph: "heart.slash",
                    title: "Apple Health isn't available",
                    line: "Sleep insights need Apple Health, which this device doesn't offer."
                )
            case .needsAccess:
                connectCard
            case .failed:
                failedCard
            case .empty:
                infoCard(
                    glyph: "moon.zzz",
                    title: "No sleep data returned",
                    line:
                        "Check Enve's Sleep permission in Apple Health, or record sleep with Apple Watch or another tracker. HealthKit doesn't reveal whether read access was denied."
                )
            case .loaded:
                if let summary = model.summary, let latest = summary.nights.first {
                    nightCard(latest)
                    trendCard(summary)
                    listeningCard(summary: summary, latest: latest)
                        .id("sleep-insights-listening")
                    disclosure(latest: latest, summary: summary)
                }
            }
        }
        .padding(.bottom, 24)
        .task { await model.loadIfNeeded() }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(tint)
            Text("Reading sleep from Apple Health…")
                .font(.hearthUI(13))
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var connectCard: some View {
        card {
            Label {
                Text("Sleep insights")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
            } icon: {
                Image(systemName: "bed.double.fill")
                    .font(.hearthUI(15))
                    .foregroundStyle(tint)
            }
            Text(
                "See how your nights unfold — sleep stages, bedtimes, and how listening before bed lines up with your sleep. Enve only reads sleep analysis from Apple Health, and it stays on this device."
            )
            .font(.hearthUI(13))
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if model.isRequestingAccess {
                ProgressView()
                    .tint(tint)
            } else {
                Button {
                    Task { await model.connect() }
                } label: {
                    Text("Connect Apple Health")
                        .font(.hearthUI(14, weight: .semibold))
                        .foregroundStyle(HearthPalette.readableForeground(on: tint, dark: hearth.onEmber))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(tint, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private var failedCard: some View {
        card {
            Text("Couldn't read sleep data")
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text("Apple Health didn't return sleep analysis. Check Health access for Enve in Settings, then try again.")
                .font(.hearthUI(13))
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Try again") {
                Task { await model.load() }
            }
        }
    }

    private func infoCard(glyph: String, title: String, line: String) -> some View {
        card {
            Label {
                Text(title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
            } icon: {
                Image(systemName: glyph)
                    .font(.hearthUI(15))
                    .foregroundStyle(tint)
            }
            Text(line)
                .font(.hearthUI(13))
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nightCard(_ night: SleepNight) -> some View {
        card {
            Overline(nightTitle(night))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HearthFormat.duration(night.totalSleep))
                    .font(.hearthDisplay(36))
                    .foregroundStyle(hearth.text)
                Text("asleep")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textTertiary)
            }
            stageTimeline(night)
            stageLegend(night)
            if !night.hasStageDetail {
                Text("This night's source recorded sleep without stage detail.")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle()
                .fill(hearth.hairline)
                .frame(height: 1)
            metricsGrid(night)
        }
    }

    private func nightTitle(_ night: SleepNight) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(night.id) || calendar.isDateInYesterday(night.id) { return "Last night" }
        return "Night of \(night.id.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func stageTimeline(_ night: SleepNight) -> some View {
        let start = night.bedtime ?? night.segments.first?.start ?? night.sleepOnset
        let end = max(night.wakeTime, night.segments.last?.end ?? night.wakeTime)
        let span = max(end.timeIntervalSince(start), 1)
        let laneHeight: CGFloat = 10
        let laneGap: CGFloat = 4
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(night.segments) { segment in
                    let x = CGFloat(segment.start.timeIntervalSince(start) / span) * geo.size.width
                    let width = max(CGFloat(segment.duration / span) * geo.size.width, 2)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: segment.kind))
                        .frame(width: width, height: laneHeight)
                        .offset(x: x, y: CGFloat(lane(for: segment.kind)) * (laneHeight + laneGap))
                }
            }
        }
        .frame(height: laneHeight * 4 + laneGap * 3)
        .accessibilityElement()
        .accessibilityLabel(timelineAccessibilityLabel(night))
    }

    private func stageLegend(_ night: SleepNight) -> some View {
        let kinds: [SleepStageKind] = [.deep, .core, .rem, .unspecified, .awake]
            .filter { night.stageDurations[$0, default: 0] > 0 }
        return VStack(spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: kind))
                        .frame(width: 8, height: 8)
                    Text(kind.label)
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(HearthFormat.duration(night.stageDurations[kind, default: 0]))
                        .font(.hearthUI(13).monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                    if kind != .awake, night.totalSleep > 0 {
                        Text(percent(night.stageDurations[kind, default: 0] / night.totalSleep))
                            .font(.hearthUI(12).monospacedDigit())
                            .foregroundStyle(hearth.textTertiary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func metricsGrid(_ night: SleepNight) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
            spacing: 14
        ) {
            metric("Bedtime", night.bedtime.map(timeString) ?? timeString(night.sleepOnset))
            metric("Wake", timeString(night.wakeTime))
            metric("Fell asleep in", night.latency.map(minutesString) ?? "—")
            metric("Efficiency", night.efficiency.map(percent) ?? "—")
            metric("Awakenings", "\(night.awakenings)")
            metric("Source", night.sourceName.isEmpty ? "—" : night.sourceName)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Overline(label, color: hearth.textTertiary)
            Text(value)
                .font(.hearthUI(15, weight: .medium).monospacedDigit())
                .foregroundStyle(hearth.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendCard(_ summary: SleepInsightsSummary) -> some View {
        let nights = Array(summary.nights.prefix(14).reversed())
        let maxSleep = max(nights.map(\.totalSleep).max() ?? 1, 1)
        return card {
            Overline("Recent nights")
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(nights) { night in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(night.hadBedtimeListening ? tint : hearth.textTertiary.opacity(0.45))
                            .frame(height: max(10, CGFloat(night.totalSleep / maxSleep) * 80))
                        Text(night.id.formatted(.dateTime.weekday(.narrow)))
                            .font(.hearthUI(9))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .bottom)
            .accessibilityElement()
            .accessibilityLabel(
                "Sleep over the last \(nights.count) nights, averaging \(HearthFormat.duration(summary.averageSleep)) per night."
            )
            HStack(spacing: 14) {
                legendDot(tint, "Listened before bed")
                legendDot(hearth.textTertiary.opacity(0.45), "No bedtime listening")
            }
            VStack(spacing: 6) {
                averageRow("Average sleep", HearthFormat.duration(summary.averageSleep))
                if let offset = summary.averageBedtimeOffset {
                    averageRow("Typical bedtime", offsetTimeString(offset))
                }
                if let offset = summary.averageWakeOffset {
                    averageRow("Typical wake", offsetTimeString(offset))
                }
            }
        }
    }

    private func averageRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.hearthUI(13))
                .foregroundStyle(hearth.textSecondary)
            Spacer()
            Text(value)
                .font(.hearthUI(13, weight: .medium).monospacedDigit())
                .foregroundStyle(hearth.text)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private func listeningCard(summary: SleepInsightsSummary, latest: SleepNight) -> some View {
        card {
            Overline("Listening & sleep")
            if let link = latest.listening {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.bookTitles[link.bookId] ?? "An audiobook")
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Listened \(minutesString(link.secondsBeforeOnset)) in the three hours before falling asleep")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if link.secondsAfterOnset > 0 {
                        Label {
                            Text("Playback ran about \(minutesString(link.secondsAfterOnset)) past sleep onset")
                                .font(.hearthUI(13))
                                .foregroundStyle(hearth.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "moon.zzz.fill")
                                .font(.hearthUI(12))
                                .foregroundStyle(hearth.statusWarn)
                        }
                    } else if let gap = link.gapToOnset {
                        Text("Stopped \(minutesString(gap)) before falling asleep")
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            } else if let start = summary.historyStart, start <= latest.sleepOnset {
                Text("No Enve listening in the three hours before sleep that night.")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enve has no listening history for this night yet, so it can't be matched to sleep.")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let average = summary.averageBedtimeListening {
                Rectangle()
                    .fill(hearth.hairline)
                    .frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    listeningMetric(minutesString(average), "Avg. wind-down")
                    listeningMetric(
                        "\(summary.nights.filter(\.hadBedtimeListening).count)",
                        "Matched nights"
                    )
                    listeningMetric(
                        summary.averagePlaybackAfterOnset.map(minutesString) ?? "—",
                        "Avg. after onset"
                    )
                }
                if let bookId = summary.topBedtimeBookId {
                    HStack(spacing: 7) {
                        Image(systemName: "books.vertical.fill")
                            .font(.hearthUI(11))
                            .foregroundStyle(tint)
                        Text("Most-listened at bedtime")
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textTertiary)
                        Spacer(minLength: 8)
                        Text(model.bookTitles[bookId] ?? "An audiobook")
                            .font(.hearthUI(12, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                    }
                }
            }
            if let comparison = summary.comparison {
                Rectangle()
                    .fill(hearth.hairline)
                    .frame(height: 1)
                comparisonRow(
                    title: "With bedtime listening",
                    nights: comparison.nightsWith,
                    sleep: comparison.averageSleepWith,
                    latency: comparison.averageLatencyWith,
                    efficiency: comparison.averageEfficiencyWith,
                    rem: comparison.averageREMWith,
                    deep: comparison.averageDeepWith,
                    highlight: true
                )
                comparisonRow(
                    title: "Without",
                    nights: comparison.nightsWithout,
                    sleep: comparison.averageSleepWithout,
                    latency: comparison.averageLatencyWithout,
                    efficiency: comparison.averageEfficiencyWithout,
                    rem: comparison.averageREMWithout,
                    deep: comparison.averageDeepWithout,
                    highlight: false
                )
                deltaLine(comparison)
            } else {
                Text("Once there are nights both with and without bedtime listening, they'll be compared here.")
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func listeningMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.hearthDisplay(17, weight: .semibold).monospacedDigit())
                .foregroundStyle(hearth.text)
            Text(label)
                .font(.hearthUI(10))
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func comparisonRow(
        title: String,
        nights: Int,
        sleep: TimeInterval,
        latency: TimeInterval?,
        efficiency: Double?,
        rem: Double?,
        deep: Double?,
        highlight: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.text)
                Text("\(nights) night\(nights == 1 ? "" : "s")")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
                Spacer()
                Text(HearthFormat.duration(sleep))
                    .font(.hearthUI(14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(highlight ? tint : hearth.textSecondary)
            }
            Text(comparisonDetails(latency: latency, efficiency: efficiency, rem: rem, deep: deep))
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comparisonDetails(
        latency: TimeInterval?,
        efficiency: Double?,
        rem: Double?,
        deep: Double?
    ) -> String {
        var details: [String] = []
        if let latency { details.append("fell asleep in \(minutesString(latency))") }
        if let efficiency { details.append("\(percent(efficiency)) efficient") }
        if let rem { details.append("REM \(percent(rem))") }
        if let deep { details.append("deep \(percent(deep))") }
        return details.joined(separator: " · ")
    }

    private func deltaLine(_ comparison: SleepListeningComparison) -> some View {
        let delta = comparison.averageSleepWith - comparison.averageSleepWithout
        let text =
            if abs(delta) < 300 {
                "Sleep looks about the same either way."
            } else if delta > 0 {
                "Sleep averaged \(minutesString(delta)) longer on nights with bedtime listening."
            } else {
                "Sleep averaged \(minutesString(-delta)) shorter on nights with bedtime listening."
            }
        return Text(text)
            .font(.hearthUI(12))
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func disclosure(latest: SleepNight, summary: SleepInsightsSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Sleep stages are recorded by \(latest.sourceName.isEmpty ? "your devices" : latest.sourceName) and read from Apple Health. Enve doesn't measure or diagnose sleep, and your health data never leaves this device."
            )
            Text("Listening comparisons show an on-device association, not cause and effect.")
            if let note = historyNote(summary) {
                Text(note)
            }
        }
        .font(.hearthUI(11))
        .foregroundStyle(hearth.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func historyNote(_ summary: SleepInsightsSummary) -> String? {
        guard let start = summary.historyStart else {
            return "Listening comparisons use sessions Enve records on this device — none yet."
        }
        guard let oldest = summary.nights.last, start > oldest.sleepOnset else { return nil }
        return
            "Enve's listening history on this device starts \(start.formatted(.dateTime.month(.abbreviated).day())), so earlier nights can't be matched."
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hearth.bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    )
            }
    }

    private func lane(for kind: SleepStageKind) -> Int {
        switch kind {
        case .awake: 0
        case .rem: 1
        case .core, .unspecified: 2
        case .deep: 3
        }
    }

    private func color(for kind: SleepStageKind) -> Color {
        switch kind {
        case .awake: hearth.statusWarn
        case .rem: tint.opacity(0.35)
        case .core, .unspecified: tint.opacity(0.65)
        case .deep: tint
        }
    }

    private func timelineAccessibilityLabel(_ night: SleepNight) -> String {
        let parts = [SleepStageKind.deep, .core, .rem, .unspecified, .awake].compactMap { kind -> String? in
            guard let seconds = night.stageDurations[kind], seconds > 0 else { return nil }
            return "\(kind.label) \(HearthFormat.duration(seconds))"
        }
        return "Sleep stages: " + parts.joined(separator: ", ")
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func offsetTimeString(_ offset: TimeInterval) -> String {
        Calendar.current.startOfDay(for: .now)
            .addingTimeInterval(43_200 + offset)
            .formatted(date: .omitted, time: .shortened)
    }

    private func minutesString(_ seconds: TimeInterval) -> String {
        "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

struct SleepInsightsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss
    @State private var model = SleepInsightsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 14) {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Nights & listening")
                        Text("Sleep")
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                    }
                    Spacer(minLength: 0)
                }

                PlayerSleepInsightsView(tint: hearth.ember, model: model)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}
