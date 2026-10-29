import SwiftUI
import UIKit

struct AppearanceScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var profileSession
    @EnvironmentObject private var theme: ThemeManager

    @AppStorage("hearth.oled") private var oledEnabled = false
    @AppStorage("hearth.paletteStyle") private var paletteStyle: Hearth.PaletteStyle = .parchment
    @State private var accentColor: Color
    @State private var prefs: UserPreferences

    init(profileSession: ProfileSession = .owner) {
        _prefs = State(initialValue: profileSession.preferences.loadPreferences())
        _accentColor = State(initialValue: Hearth.accent(fromHex: profileSession.defaults.string(forKey: "themeColorHex")))
    }

    private var session: ProfileSession { profileSession ?? .owner }

    var body: some View {
        SettingsScaffold(overline: "Playback & experience", title: "Appearance") {
            SourcesCard {
                Overline("Theme")
                HStack(spacing: 10) {
                    ForEach(Hearth.Mode.allCases, id: \.rawValue) { mode in
                        HearthChip(title: mode.title, isSelected: theme.appearanceMode == mode) {
                            theme.appearanceMode = mode
                            PlatformHaptics.selection()
                        }
                    }
                }

                Toggle(isOn: $oledEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("True black")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                        Text("Pure-black surfaces in dark mode, for OLED screens.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                .tint(hearth.ember)

                Overline("Palette")
                HStack(spacing: 10) {
                    ForEach(Hearth.PaletteStyle.allCases, id: \.rawValue) { style in
                        HearthChip(title: style.title, isSelected: paletteStyle == style) {
                            paletteStyle = style
                            PlatformHaptics.selection()
                        }
                    }
                }
                Text("Classic restores the earlier colors and flat covers.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)

                HStack(spacing: 14) {
                    Text("Accent")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Button {
                        session.theme.themeColorHex = ThemeManager.defaultThemeHex
                        accentColor = Color(hexValue: 0xF5921A)
                        PlatformHaptics.selection()
                    } label: {
                        Circle()
                            .fill(Color(hexValue: 0xF5921A))
                            .frame(width: 26, height: 26)
                            .overlay {
                                if session.theme.themeColorHex.uppercased() == ThemeManager.defaultThemeHex.uppercased() {
                                    Image(systemName: "checkmark")
                                        .font(.hearthUI(11, weight: .bold))
                                        .foregroundStyle(hearth.onEmber)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Reset accent to orange")
                    ColorPicker("", selection: $accentColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: accentColor) { _, newColor in
                            if let hex = newColor.settingsHexString {
                                session.theme.themeColorHex = hex
                            }
                        }
                }
            }

            SourcesCard {
                SettingsMenuRow(
                    title: "Player background",
                    value: prefs.playerBackgroundStyle == .albumArt ? "Blurred cover" : "Solid"
                ) {
                    Button("Blurred cover") {
                        prefs = SettingsPrefs.mutate(in: session.preferences) { $0.playerBackgroundStyle = .albumArt }
                    }
                    Button("Solid") {
                        prefs = SettingsPrefs.mutate(in: session.preferences) { $0.playerBackgroundStyle = .solid }
                    }
                }

                SettingsMenuRow(
                    title: "Navigation style",
                    value: prefs.shellNavigationStyle.displayName
                ) {
                    ForEach(UserPreferences.ShellNavigationStyle.allCases) { style in
                        Button(style.displayName) {
                            prefs = SettingsPrefs.mutate(in: session.preferences) { $0.shellNavigationStyle = style }
                        }
                    }
                }

                Text(prefs.shellNavigationStyle.description)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .onAppear { prefs = session.preferences.loadPreferences() }
    }
}

extension Color {

    var settingsHexString: String? {
        let ui = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}
