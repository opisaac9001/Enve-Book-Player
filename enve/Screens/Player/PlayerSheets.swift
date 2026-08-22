import HealthKit
import SwiftUI

struct PlayerSpeedSheet: View {
    let tint: Color

    @Environment(\.hearth) private var hearth
    @Environment(PlayerViewModel.self) private var playerVM
    @State private var speed = 1.0

    private let minSpeed = Double(AppConstants.Playback.minSpeed)
    private let maxSpeed = Double(AppConstants.Playback.maxSpeed)
    private var span: Double { maxSpeed - minSpeed }
    private var tickCount: Int { Int((span / 0.05).rounded()) }

    var body: some View {
        VStack(spacing: 24) {
            Overline("Playback speed")
                .padding(.top, 28)

            Text(label(for: speed))
                .font(.hearthDisplay(52))
                .foregroundStyle(abs(speed - 1.0) < 0.001 ? hearth.text : tint)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: speed)

            ruler
                .padding(.horizontal, 28)

            QuietButton(title: "Reset to 1×") {
                set(1.0)
            }
            .opacity(abs(speed - 1.0) < 0.001 ? 0.4 : 1)
            .disabled(abs(speed - 1.0) < 0.001)

            Spacer(minLength: 0)
        }
        .onAppear { speed = playerVM.playbackSpeed }
    }

    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .bottomLeading) {
                ForEach(0...tickCount, id: \.self) { step in
                    let value = minSpeed + Double(step) * 0.05
                    let isMajor = step % 5 == 0
                    Rectangle()
                        .fill(tickColor(for: value, isMajor: isMajor))
                        .frame(width: isMajor ? 2 : 1, height: isMajor ? 26 : 14)
                        .offset(x: x(for: value, width: width))
                }
                Capsule()
                    .fill(tint)
                    .frame(width: 4, height: 40)
                    .offset(x: x(for: speed, width: width) - 1.5)
                    .animation(.snappy(duration: 0.15), value: speed)

                ForEach([0.75, 1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { value in
                    Text(label(for: value))
                        .font(.hearthUI(11, weight: .medium))
                        .foregroundStyle(hearth.textTertiary)
                        .frame(width: 44)
                        .offset(x: x(for: value, width: width) - 22, y: 20)
                }
            }
            .frame(width: width, height: 40, alignment: .bottomLeading)
            .contentShape(Rectangle().inset(by: -16))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        set(minSpeed + Double(min(max(value.location.x / width, 0), 1)) * span)
                    }
            )
        }
        .frame(height: 64)
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        CGFloat((value - minSpeed) / span) * width
    }

    private func tickColor(for value: Double, isMajor: Bool) -> Color {
        if abs(value - 1.0) < 0.001 { return tint.opacity(0.9) }
        return isMajor ? hearth.textTertiary : hearth.hairline
    }

    private func set(_ raw: Double) {
        var snapped = (raw / 0.05).rounded() * 0.05
        if abs(snapped - 1.0) < 0.034 { snapped = 1.0 }
        snapped = min(max(snapped, minSpeed), maxSpeed)
        guard abs(snapped - speed) > 0.001 else { return }
        speed = snapped
        PlatformHaptics.selection()
        playerVM.setPlaybackSpeed(snapped)
    }

    private func label(for value: Double) -> String {
        String(format: "%g×", (value * 100).rounded() / 100)
    }
}

private enum SleepSheetPane: String, CaseIterable, Identifiable {
    case timer, insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timer: "Timer"
        case .insights: "Sleep insights"
        }
    }
}

struct PlayerSleepSheet: View {
    let tint: Color
    let chapters: [Chapter]
    @Binding var chapterLabel: String?

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var pane: SleepSheetPane = .timer
    @State private var insightsModel = SleepInsightsModel()
    @State private var customMinutes = 30
    @State private var healthAuthorized = SleepDataService.shared.hasRequestedAuthorization
    @State private var isRequestingHealth = false
    @State private var showHealthExplainer = false

    private static let durations = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    paneToggle
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)

                    switch pane {
                    case .timer:
                        timerPane
                    case .insights:
                        PlayerSleepInsightsView(tint: tint, model: insightsModel)
                    }
                }
                .padding(.horizontal, 24)
            }
            .onAppear {
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if SleepInsightsFixture.isActive {
                    pane = .insights
                    if arguments.contains("-sleepInsightsFixtureLower") {
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            proxy.scrollTo("sleep-insights-listening", anchor: .top)
                        }
                    }
                }
                #endif
            }
        }
        .scrollIndicators(.hidden)
        .onChange(of: pane) { _, pane in
            if pane == .timer {
                healthAuthorized = SleepDataService.shared.hasRequestedAuthorization
            }
        }
        .alert("Apple Health access", isPresented: $showHealthExplainer) {
            Button("Allow access") { requestHealthAccess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enve reads sleep analysis from Apple Watch to find when you fell asleep, then offers to rewind there. Your health data never leaves this device."
            )
        }
    }

    private var paneToggle: some View {
        HStack(spacing: 4) {
            ForEach(SleepSheetPane.allCases) { option in
                Button {
                    guard pane != option else { return }
                    pane = option
                    PlatformHaptics.selection()
                } label: {
                    Text(option.title)
                        .font(.hearthUI(13, weight: pane == option ? .semibold : .medium))
                        .foregroundStyle(
                            pane == option
                                ? HearthPalette.readableForeground(on: tint, dark: hearth.onEmber)
                                : hearth.textSecondary
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            Capsule()
                                .fill(pane == option ? tint : .clear)
                        }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(3)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep sheet section")
    }

    @ViewBuilder
    private var timerPane: some View {
        if playerVM.sleepTimer != nil {
            activeRow
        }

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(Self.durations, id: \.self) { minutes in
                Button {
                    start(minutes: minutes)
                } label: {
                    Text("\(minutes)m")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            Capsule()
                                .fill(hearth.bg)
                                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                        }
                }
                .buttonStyle(PressableStyle())
            }
        }

        VStack(spacing: 0) {
            chapterRow(title: "End of chapter", available: currentChapter != nil) {
                playerVM.setSleepTimerToEndOfChapter()
                finishStart(label: "End of chapter")
            }
            Rectangle().fill(hearth.hairline).frame(height: 1)
            chapterRow(title: "End of next chapter", available: nextChapter != nil) {
                playerVM.setSleepTimerToEndOfNextChapter()
                finishStart(label: "End of next chapter")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hearth.bg)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hearth.hairline, lineWidth: 1))
        }

        HStack(spacing: 14) {
            Text("\(customMinutes) minutes")
                .font(.hearthUI(15, weight: .medium).monospacedDigit())
                .foregroundStyle(hearth.text)
            Spacer()
            Stepper("", value: $customMinutes, in: 5...180, step: 5)
                .labelsHidden()
                .accessibilityLabel("Custom minutes")
            Button {
                start(minutes: customMinutes)
            } label: {
                Text("Start")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.onEmber)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(tint, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }

        smartSleepRewindRow

        Text("Shake to snooze while the timer runs.")
            .font(.hearthUI(12))
            .foregroundStyle(hearth.textTertiary)
            .padding(.bottom, 24)
    }

    @ViewBuilder
    private var smartSleepRewindRow: some View {
        if HKHealthStore.isHealthDataAvailable() {
            HStack(spacing: 12) {
                Image(systemName: "bed.double.fill")
                    .font(.hearthUI(15))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart sleep rewind")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text(
                        healthAuthorized
                            ? "Apple Health access is set up"
                            : "Use Apple Watch sleep data to rewind to where you fell asleep"
                    )
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isRequestingHealth {
                    ProgressView()
                        .tint(tint)
                } else if healthAuthorized {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(hearth.statusOK)
                } else {
                    QuietButton(title: "Connect", systemImage: nil) {
                        showHealthExplainer = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hearth.bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    )
            }
        } else {
            Text("Apple Health isn't available on this device, so smart sleep rewind can't be offered.")
                .font(.hearthUI(12))
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var activeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.hearthUI(15))
                .foregroundStyle(tint)
            Text(chapterLabel ?? HearthFormat.clock(playerVM.sleepTimerRemainingSeconds))
                .font(.hearthUI(15, weight: .medium).monospacedDigit())
                .foregroundStyle(hearth.text)
            Spacer()
            Button {
                playerVM.stopSleepTimer()
                chapterLabel = nil
                PlatformHaptics.impact(.light)
            } label: {
                Text("Stop")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.4), lineWidth: 1))
        }
    }

    private func chapterRow(title: String, available: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
    }

    private var currentChapter: Chapter? {
        let time = playerVM.progress
        return chapters.first { $0.start <= time && $0.end > time }
    }

    private var nextChapter: Chapter? {
        guard let current = currentChapter,
            let index = chapters.firstIndex(where: { $0.id == current.id }),
            index + 1 < chapters.count
        else { return nil }
        return chapters[index + 1]
    }

    private func start(minutes: Int) {
        playerVM.startSleepTimer(minutes: minutes)
        finishStart(label: nil)
    }

    private func requestHealthAccess() {
        isRequestingHealth = true
        Task {
            try? await SleepDataService.shared.requestAuthorization()
            withAnimation(.smooth(duration: 0.35)) {
                healthAuthorized = true
                isRequestingHealth = false
            }
        }
    }

    private func finishStart(label: String?) {
        chapterLabel = label
        ShakeDetectionService.shared.startMonitoring()
        PlatformHaptics.notification(.success)
        dismiss()
    }
}
