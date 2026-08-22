import SwiftUI

struct AccessibilityScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()

    var body: some View {
        SettingsScaffold(
            overline: "Playback & experience",
            title: "Accessibility",
            subtitle: "Larger type, higher contrast, and a quieter screen for low vision."
        ) {
            SourcesCard {
                SourcesToggleRow(
                    title: "Vision-impaired mode",
                    subtitle: "Larger type, bigger covers and touch targets, simplified screens",
                    isOn: Binding(
                        get: { prefs.visionImpairedModeEnabled },
                        set: { setVisionMode($0) }
                    )
                )

                if prefs.visionImpairedModeEnabled {
                    Divider().overlay(hearth.hairline)
                    Overline("While it's on")
                    accessibilityBullet("Type across the app scales up 15% beyond Dynamic Type")
                    accessibilityBullet("Covers and buttons grow to larger touch targets")
                    accessibilityBullet("Contrast meets the WCAG AA minimum")
                }
            }

            SourcesCard {
                Overline("VoiceOver")
                Text(
                    "VoiceOver reads the screen aloud and lets you navigate by gesture. Turn it on under Settings > Accessibility > VoiceOver, or assign it to the triple-click shortcut."
                )
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SourcesCard {
                Overline("In Enve")
                accessibilityBullet("Library items announce title, author, progress, and download state")
                accessibilityBullet("Playback controls announce their current values")
                accessibilityBullet("Most book rows offer a Play action when VoiceOver is on")
            }
        }
    }

    private func accessibilityBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.hearthUI(13))
                .foregroundStyle(hearth.ember)
                .padding(.top, 2)
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setVisionMode(_ enabled: Bool) {
        prefs = SettingsPrefs.mutate { $0.visionImpairedModeEnabled = enabled }
        ThemeManager.shared.isVisionMode = enabled
        NotificationCenter.default.post(name: .init("VisionImpairedModeChanged"), object: nil)
        PlatformHaptics.selection()
    }
}
