import SwiftUI

struct RestReminderSettingsScreen: View {
    @Binding var appearance: ClassicReaderAppearance

    @Environment(\.hearth) private var hearth

    var body: some View {
        SettingsScaffold(
            overline: "Playback & experience",
            title: "Rest your eyes",
            subtitle: "A gentle reminder to look away from the page after you've been reading for a while."
        ) {
            SourcesCard {
                SourcesToggleRow(title: "Remind me to rest", isOn: $appearance.restReminderEnabled)
                if appearance.restReminderEnabled {
                    HStack(spacing: 14) {
                        Text("Every \(appearance.restReminderMinutes) minutes")
                            .font(.hearthUI(15, weight: .medium).monospacedDigit())
                            .foregroundStyle(hearth.text)
                        Spacer()
                        Stepper("", value: $appearance.restReminderMinutes, in: ReaderRestReminder.minuteRange, step: 5)
                            .labelsHidden()
                            .accessibilityLabel("Reminder interval")
                            .accessibilityValue("\(appearance.restReminderMinutes) minutes")
                    }
                }
            }

            SourcesCard {
                Text(
                    "Only time with a book open on screen counts. Leaving the reader pauses the timer, and a break of five minutes or more starts it over."
                )
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StoredRestReminderSettingsScreen: View {
    @State private var appearance = ClassicReaderAppearance.load()

    var body: some View {
        RestReminderSettingsScreen(appearance: $appearance)
            .onAppear { appearance = ClassicReaderAppearance.load() }
            .onChange(of: appearance) { _, updated in
                var stored = ClassicReaderAppearance.load()
                stored.restReminderEnabled = updated.restReminderEnabled
                stored.restReminderMinutes = updated.restReminderMinutes
                stored.persist()
            }
    }
}
