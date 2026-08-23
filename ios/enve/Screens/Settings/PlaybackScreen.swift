import HealthKit
import SwiftUI

struct PlaybackScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
    @State private var intelligence = BookIntelligenceSettingsStore.shared

    @State private var healthAuthorized = SleepDataService.shared.hasRequestedAuthorization
    @State private var healthUnavailable = !HKHealthStore.isHealthDataAvailable()
    @State private var isRequestingHealth = false
    @State private var showHealthExplainer = false

    @State private var librarianAPIKeyDraft = ""
    @State private var librarianServerModels: [String] = []
    @State private var librarianServerStatus: String?
    @State private var isTestingLibrarianServer = false

    private static let speeds: [Double] = [0.75] + (10...30).map { Double($0) / 10 }
    private static let skipOptions = [5, 10, 15, 30, 45, 60, 90, 120]
    private static let rewindThresholds = [15, 30, 45, 60, 120, 300]
    private static let rewindShortAmounts = [0, 3, 5, 7, 10, 15]
    private static let rewindLongAmounts = [15, 30, 45, 60]
    private static let snoozeMinutes = [5, 10, 15, 20, 30]
    private static let fadeSeconds: [TimeInterval] = [10, 15, 20, 30, 45, 60]

    var body: some View {
        SettingsScaffold(
            overline: "Playback & experience",
            title: "Playback",
            subtitle: "Speed, skips, smart rewind, and the sleep timer's habits."
        ) {
            speedCard
            skipCard
            smartRewindCard
            sleepTimerCard
            playerDisplayCard
            librarianCard
            screenCard
        }
        .alert("Apple Health access", isPresented: $showHealthExplainer) {
            Button("Allow access") { requestHealthAccess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enve reads sleep analysis from Apple Watch to find when you actually drifted off, then offers to rewind there. Your health data never leaves this device."
            )
        }
    }

    private var speedCard: some View {
        SourcesCard {
            HStack {
                Overline("Speed")
                Spacer()
                Text(playbackSpeedLabel(prefs.playbackSpeed))
                    .font(.hearthDisplay(20))
                    .foregroundStyle(hearth.ember)
            }
            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Self.speeds, id: \.self) { speed in
                    HearthChip(title: playbackSpeedLabel(speed), isSelected: abs(prefs.playbackSpeed - speed) < 0.01) {
                        prefs = SettingsPrefs.mutate {
                            $0.playbackSpeed = min(
                                max(speed, Double(AppConstants.Playback.minSpeed)),
                                Double(AppConstants.Playback.maxSpeed)
                            )
                        }
                        PlatformHaptics.selection()
                    }
                }
            }
        }
    }

    private var skipCard: some View {
        SourcesCard {
            Overline("Skips")
            SettingsMenuRow(title: "Skip back", value: "\(Int(prefs.skipBackwardAmount))s") {
                ForEach(Self.skipOptions, id: \.self) { seconds in
                    Button("\(seconds) seconds") {
                        prefs = SettingsPrefs.mutate { $0.skipBackwardAmount = TimeInterval(seconds) }
                    }
                }
            }
            SettingsMenuRow(title: "Skip forward", value: "\(Int(prefs.skipForwardAmount))s") {
                ForEach(Self.skipOptions, id: \.self) { seconds in
                    Button("\(seconds) seconds") {
                        prefs = SettingsPrefs.mutate { $0.skipForwardAmount = TimeInterval(seconds) }
                    }
                }
            }
        }
    }

    private var smartRewindCard: some View {
        SourcesCard {
            Overline("Smart rewind")
            SourcesToggleRow(
                title: "Rewind a little on return",
                subtitle: "Step back after time away so you don't lose the thread",
                isOn: Binding(
                    get: { prefs.smartRewindEnabled },
                    set: { value in prefs = SettingsPrefs.mutate { $0.smartRewindEnabled = value } }
                )
            )
            if prefs.smartRewindEnabled {
                SettingsMenuRow(title: "Short pause is under", value: "\(Int(prefs.smartRewindShortPauseThreshold))s") {
                    ForEach(Self.rewindThresholds, id: \.self) { seconds in
                        Button("\(seconds) seconds") {
                            prefs = SettingsPrefs.mutate { $0.smartRewindShortPauseThreshold = TimeInterval(seconds) }
                        }
                    }
                }
                SettingsMenuRow(title: "Then rewind", value: "\(Int(prefs.smartRewindShortAmount))s") {
                    ForEach(Self.rewindShortAmounts, id: \.self) { seconds in
                        Button("\(seconds) seconds") {
                            prefs = SettingsPrefs.mutate { $0.smartRewindShortAmount = TimeInterval(seconds) }
                        }
                    }
                }
                SettingsMenuRow(title: "Long pause is over", value: "\(Int(prefs.smartRewindLongPauseThreshold))s") {
                    ForEach(Self.rewindThresholds, id: \.self) { seconds in
                        Button("\(seconds) seconds") {
                            prefs = SettingsPrefs.mutate { $0.smartRewindLongPauseThreshold = TimeInterval(seconds) }
                        }
                    }
                }
                SettingsMenuRow(title: "Then rewind", value: "\(Int(prefs.smartRewindLongAmount))s") {
                    ForEach(Self.rewindLongAmounts, id: \.self) { seconds in
                        Button("\(seconds) seconds") {
                            prefs = SettingsPrefs.mutate { $0.smartRewindLongAmount = TimeInterval(seconds) }
                        }
                    }
                }
            }
        }
    }

    private func minutesBinding(
        _ keyPath: KeyPath<UserPreferences, Int>,
        _ set: @escaping (inout UserPreferences, Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(prefs[keyPath: keyPath] * 60))
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                prefs = SettingsPrefs.mutate { set(&$0, minutes) }
            }
        )
    }

    private var sleepTimerCard: some View {
        SourcesCard {
            Overline("Sleep timer")
            SourcesToggleRow(
                title: "Fade out",
                subtitle: "Lower the volume gently before stopping",
                isOn: Binding(
                    get: { prefs.sleepTimerFadeOutEnabled },
                    set: { value in prefs = SettingsPrefs.mutate { $0.sleepTimerFadeOutEnabled = value } }
                )
            )
            if prefs.sleepTimerFadeOutEnabled {
                SettingsMenuRow(title: "Fade over", value: "\(Int(prefs.sleepTimerFadeOutDuration))s") {
                    ForEach(Self.fadeSeconds, id: \.self) { seconds in
                        Button("\(Int(seconds)) seconds") {
                            prefs = SettingsPrefs.mutate { $0.sleepTimerFadeOutDuration = seconds }
                        }
                    }
                }
            }

            Divider().overlay(hearth.hairline)

            SourcesToggleRow(
                title: "Shake to snooze",
                subtitle: "Shake the phone while the audio fades to keep listening",
                isOn: Binding(
                    get: { prefs.sleepTimerShakeToSnoozeEnabled },
                    set: { value in prefs = SettingsPrefs.mutate { $0.sleepTimerShakeToSnoozeEnabled = value } }
                )
            )
            if prefs.sleepTimerShakeToSnoozeEnabled {
                SettingsMenuRow(title: "Snooze for", value: "\(prefs.sleepTimerSnoozeDuration) min") {
                    ForEach(Self.snoozeMinutes, id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            prefs = SettingsPrefs.mutate { $0.sleepTimerSnoozeDuration = minutes }
                        }
                    }
                }
            }

            Divider().overlay(hearth.hairline)

            SourcesToggleRow(
                title: "Bedtime auto-sleep",
                subtitle: "Arm the sleep timer automatically when you listen during these hours",
                isOn: Binding(
                    get: { prefs.autoSleepEnabled },
                    set: { value in prefs = SettingsPrefs.mutate { $0.autoSleepEnabled = value } }
                )
            )
            if prefs.autoSleepEnabled {
                HStack(spacing: 8) {
                    Text("From")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                    DatePicker(
                        "",
                        selection: minutesBinding(\.autoSleepStartMinutes) { $0.autoSleepStartMinutes = $1 },
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    Text("to")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                    DatePicker(
                        "",
                        selection: minutesBinding(\.autoSleepEndMinutes) { $0.autoSleepEndMinutes = $1 },
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    Spacer(minLength: 0)
                }
                SettingsMenuRow(title: "Timer length", value: "\(prefs.autoSleepTimerMinutes) min") {
                    ForEach([15, 20, 30, 45, 60, 90], id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            prefs = SettingsPrefs.mutate { $0.autoSleepTimerMinutes = minutes }
                        }
                    }
                }
            }

            Divider().overlay(hearth.hairline)

            if healthUnavailable {
                Text("Apple Health isn't available on this device, so sleep-aware rewind can't be offered.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sleep-aware rewind")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                        Text(
                            healthAuthorized
                                ? "Connected to Apple Health"
                                : "Use Apple Watch sleep data to rewind to where you dozed off"
                        )
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if isRequestingHealth {
                        ProgressView().tint(hearth.ember)
                    } else if healthAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(hearth.statusOK)
                    } else {
                        QuietButton(title: "Connect", systemImage: nil) {
                            showHealthExplainer = true
                        }
                    }
                }
            }
        }
    }

    private var playerDisplayCard: some View {
        SourcesCard {
            Overline("Player")
            SourcesToggleRow(
                title: "Open the player automatically",
                subtitle: "Show the full player whenever playback starts",
                isOn: Binding(
                    get: { prefs.showPlayerAutomatically },
                    set: { value in prefs = SettingsPrefs.mutate { $0.showPlayerAutomatically = value } }
                )
            )
            SourcesToggleRow(
                title: "Continue through Up Next",
                subtitle: "Start the next queued book or episode when the current one ends",
                isOn: Binding(
                    get: { prefs.continuousPlaybackEnabled },
                    set: { value in prefs = SettingsPrefs.mutate { $0.continuousPlaybackEnabled = value } }
                )
            )
            SourcesToggleRow(
                title: "Continue series automatically",
                subtitle: "When a book ends with nothing queued, start the next book in its series",
                isOn: Binding(
                    get: { prefs.autoPlayNextInSeries },
                    set: { value in prefs = SettingsPrefs.mutate { $0.autoPlayNextInSeries = value } }
                )
            )
            SourcesToggleRow(
                title: "Blurred cover behind the player",
                isOn: Binding(
                    get: { prefs.useBlurredPlayerBackground },
                    set: { value in prefs = SettingsPrefs.mutate { $0.useBlurredPlayerBackground = value } }
                )
            )
            SourcesToggleRow(
                title: "Lock Screen progress bar",
                subtitle: "Allow seeking from the Lock Screen and Control Center",
                isOn: Binding(
                    get: { prefs.showLockScreenProgressBar },
                    set: { value in prefs = SettingsPrefs.mutate { $0.showLockScreenProgressBar = value } }
                )
            )
        }
    }

    private var librarianCard: some View {
        SourcesCard {
            Overline("Librarian")
            SourcesToggleRow(
                title: "Show the Librarian in the player",
                subtitle: "Spoiler-safe transcripts and catch-up for the current book.",
                isOn: Binding(
                    get: { intelligence.showPlayerButton },
                    set: { intelligence.showPlayerButton = $0 }
                )
            )
            HStack(spacing: 8) {
                HearthChip(
                    title: "Apple Intelligence",
                    isSelected: intelligence.librarianBackendID == "apple"
                ) {
                    intelligence.librarianBackendID = "apple"
                }
                HearthChip(
                    title: "Local Server",
                    isSelected: intelligence.librarianBackendID == "server"
                ) {
                    intelligence.librarianBackendID = "server"
                }
            }
            if intelligence.librarianBackendID == "server" {
                SourcesField(
                    label: "Server URL",
                    text: Binding(
                        get: { intelligence.librarianServerURLString },
                        set: { intelligence.librarianServerURLString = $0 }
                    ),
                    placeholder: "192.168.1.10:11434",
                    keyboard: .URL
                )
                SourcesField(
                    label: "Model",
                    text: Binding(
                        get: { intelligence.librarianServerModel },
                        set: { intelligence.librarianServerModel = $0 }
                    ),
                    placeholder: "Model id - use Test connection to list"
                )
                SourcesField(
                    label: "API key (optional)",
                    text: $librarianAPIKeyDraft,
                    placeholder: intelligence.librarianServerAPIKey == nil ? "" : "Saved - type to replace",
                    secure: true
                )
                if !librarianServerModels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(librarianServerModels, id: \.self) { model in
                                HearthChip(
                                    title: model,
                                    isSelected: intelligence.librarianServerModel == model
                                ) {
                                    intelligence.librarianServerModel = model
                                }
                            }
                        }
                    }
                }
                HStack {
                    QuietButton(title: isTestingLibrarianServer ? "Testing…" : "Test connection", systemImage: nil) {
                        testLibrarianServer()
                    }
                    .disabled(isTestingLibrarianServer)
                    if let status = librarianServerStatus {
                        Text(status)
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                Text("Works with Ollama, LM Studio, llama.cpp, and any OpenAI-compatible server on your network.")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private func testLibrarianServer() {
        isTestingLibrarianServer = true
        librarianServerStatus = nil
        if !librarianAPIKeyDraft.isEmpty {
            intelligence.librarianServerAPIKey = librarianAPIKeyDraft
        }
        Task {
            do {
                let models = try await OpenAICompatibleLibrarianBackend.shared.availableModels()
                librarianServerModels = models
                if intelligence.librarianServerModel.isEmpty, let first = models.first {
                    intelligence.librarianServerModel = first
                }
                librarianServerStatus = "Connected - \(models.count) model\(models.count == 1 ? "" : "s")"
            } catch {
                librarianServerModels = []
                librarianServerStatus = error.localizedDescription
            }
            isTestingLibrarianServer = false
        }
    }

    private var screenCard: some View {
        SourcesCard {
            Overline("Screen")
            SourcesToggleRow(
                title: "Keep the screen awake",
                subtitle: "Prevent auto-lock while audio is playing",
                isOn: Binding(
                    get: { prefs.disableAutoLockWhilePlaying },
                    set: { value in prefs = SettingsPrefs.mutate { $0.disableAutoLockWhilePlaying = value } }
                )
            )
        }
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
}

private func playbackSpeedLabel(_ speed: Double) -> String {
    let formatted =
        speed.truncatingRemainder(dividingBy: 1) == 0
        ? String(format: "%.0f", speed)
        : String(format: "%.2f", speed)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    return "\(formatted)×"
}
