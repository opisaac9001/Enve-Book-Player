import Combine
import SwiftUI

struct ColorSet {
    let background: Color
    let secondaryBackground: Color
    let tertiaryBackground: Color
    let cardBackground: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let separator: Color

    static let light: ColorSet = {
        #if os(iOS)
        return ColorSet(
            background: Color(.systemBackground),
            secondaryBackground: Color(.secondarySystemBackground),
            tertiaryBackground: Color(.tertiarySystemBackground),
            cardBackground: Color(.systemBackground),
            text: Color(.label),
            secondaryText: Color(.secondaryLabel),
            tertiaryText: Color(.tertiaryLabel),
            accent: ThemeManager.defaultAccentColor,
            separator: Color(.separator)
        )
        #elseif os(macOS)
        return ColorSet(
            background: Color(NSColor.windowBackgroundColor),
            secondaryBackground: Color(NSColor.controlBackgroundColor),
            tertiaryBackground: Color(NSColor.selectedControlColor),
            cardBackground: Color(NSColor.windowBackgroundColor),
            text: Color(NSColor.labelColor),
            secondaryText: Color(NSColor.secondaryLabelColor),
            tertiaryText: Color(NSColor.tertiaryLabelColor),
            accent: ThemeManager.defaultAccentColor,
            separator: Color(NSColor.separatorColor)
        )
        #else

        return ColorSet(
            background: .white,
            secondaryBackground: Color(white: 0.95),
            tertiaryBackground: Color(white: 0.92),
            cardBackground: .white,
            text: .primary,
            secondaryText: .secondary,
            tertiaryText: Color(white: 0.6),
            accent: ThemeManager.defaultAccentColor,
            separator: Color(white: 0.85)
        )
        #endif
    }()

    static let dark: ColorSet = {
        #if os(iOS)
        return ColorSet(
            background: Color(.systemBackground),
            secondaryBackground: Color(.secondarySystemBackground),
            tertiaryBackground: Color(.tertiarySystemBackground),
            cardBackground: Color(.secondarySystemBackground),
            text: Color(.label),
            secondaryText: Color(.secondaryLabel),
            tertiaryText: Color(.tertiaryLabel),
            accent: ThemeManager.defaultAccentColor,
            separator: Color(.separator)
        )
        #elseif os(macOS)
        return ColorSet(
            background: Color(NSColor.windowBackgroundColor),
            secondaryBackground: Color(NSColor.controlBackgroundColor),
            tertiaryBackground: Color(NSColor.selectedControlColor),
            cardBackground: Color(NSColor.controlBackgroundColor),
            text: Color(NSColor.labelColor),
            secondaryText: Color(NSColor.secondaryLabelColor),
            tertiaryText: Color(NSColor.tertiaryLabelColor),
            accent: ThemeManager.defaultAccentColor,
            separator: Color(NSColor.separatorColor)
        )
        #else

        return ColorSet(
            background: Color(white: 0.11),
            secondaryBackground: Color(white: 0.16),
            tertiaryBackground: Color(white: 0.20),
            cardBackground: Color(white: 0.16),
            text: .primary,
            secondaryText: .secondary,
            tertiaryText: Color(white: 0.5),
            accent: ThemeManager.defaultAccentColor,
            separator: Color(white: 0.25)
        )
        #endif
    }()

    static let oled = ColorSet(
        background: .black,
        secondaryBackground: Color(white: 0.05),
        tertiaryBackground: Color(white: 0.08),
        cardBackground: Color(white: 0.1),
        text: .white,
        secondaryText: Color(white: 0.7),
        tertiaryText: Color(white: 0.5),
        accent: ThemeManager.defaultAccentColor,
        separator: Color(white: 0.2)
    )
}

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    nonisolated static let defaultThemeHex = "#F5921A"
    nonisolated static let defaultAccentRed: CGFloat = 245.0 / 255.0
    nonisolated static let defaultAccentGreen: CGFloat = 146.0 / 255.0
    nonisolated static let defaultAccentBlue: CGFloat = 26.0 / 255.0
    nonisolated static let previousDefaultHex = "#EF4444"
    nonisolated static let legacyAccentRed: CGFloat = 0.8
    nonisolated static let legacyAccentGreen: CGFloat = 0.3
    nonisolated static let legacyAccentBlue: CGFloat = 1.0

    nonisolated static var defaultAccentColor: Color {
        Color(red: defaultAccentRed, green: defaultAccentGreen, blue: defaultAccentBlue)
    }

    enum AppTheme: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        case oled = "OLED"

        var id: String { self.rawValue }
    }

    @AppStorage("selectedAppTheme") var selectedTheme: AppTheme = .system

    @AppStorage("visionImpairedModeEnabled") var isVisionMode: Bool = false

    @AppStorage("themeColorHex") private var themeColorHex: String = ThemeManager.defaultThemeHex

    private init() {

        if themeColorHex.uppercased() == ThemeManager.previousDefaultHex {
            themeColorHex = ThemeManager.defaultThemeHex
        }
    }

    var themeColor: Color {
        Color(hex: themeColorHex) ?? ThemeManager.defaultAccentColor
    }

    func updateThemeColor(_ color: Color) {
        let hex = color.toHex() ?? ThemeManager.defaultThemeHex
        guard themeColorHex != hex else { return }
        self.themeColorHex = hex
    }

    var isOLEDDevice: Bool {
        #if canImport(UIKit)
        if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive })
            as? UIWindowScene
        {
            return windowScene.screen.traitCollection.displayGamut == .P3
        }
        #endif
        return false
    }

    func colors(for systemScheme: ColorScheme) -> ColorSet {
        let accentColor = themeColor

        let effectiveScheme: ColorScheme
        let useOLED: Bool

        switch selectedTheme {
        case .system:
            effectiveScheme = systemScheme
            useOLED = isOLEDDevice && systemScheme == .dark
        case .light:
            effectiveScheme = .light
            useOLED = false
        case .dark:
            effectiveScheme = .dark
            useOLED = false
        case .oled:
            effectiveScheme = .dark
            useOLED = true
        }

        if effectiveScheme == .light {
            #if os(iOS)
            return ColorSet(
                background: Color(.systemBackground),
                secondaryBackground: Color(.secondarySystemBackground),
                tertiaryBackground: Color(.tertiarySystemBackground),
                cardBackground: Color(.systemBackground),
                text: Color(.label),
                secondaryText: Color(.secondaryLabel),
                tertiaryText: Color(.tertiaryLabel),
                accent: accentColor,
                separator: Color(.separator)
            )
            #elseif os(macOS)
            return ColorSet(
                background: Color(nsColor: .windowBackgroundColor),
                secondaryBackground: Color(nsColor: .controlBackgroundColor),
                tertiaryBackground: Color(nsColor: .textBackgroundColor),
                cardBackground: Color(nsColor: .windowBackgroundColor),
                text: Color(nsColor: .labelColor),
                secondaryText: Color(nsColor: .secondaryLabelColor),
                tertiaryText: Color(nsColor: .tertiaryLabelColor),
                accent: accentColor,
                separator: Color(nsColor: .separatorColor)
            )
            #else
            return ColorSet(
                background: .white,
                secondaryBackground: Color(white: 0.95),
                tertiaryBackground: Color(white: 0.92),
                cardBackground: .white,
                text: .primary,
                secondaryText: .secondary,
                tertiaryText: Color(white: 0.6),
                accent: accentColor,
                separator: Color(white: 0.85)
            )
            #endif
        } else {
            let baseSet = useOLED ? ColorSet.oled : ColorSet.dark
            return ColorSet(
                background: baseSet.background,
                secondaryBackground: baseSet.secondaryBackground,
                tertiaryBackground: baseSet.tertiaryBackground,
                cardBackground: baseSet.cardBackground,
                text: baseSet.text,
                secondaryText: baseSet.secondaryText,
                tertiaryText: baseSet.tertiaryText,
                accent: accentColor,
                separator: baseSet.separator
            )
        }
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0

        let length = hexSanitized.count

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0

        } else if length == 8 {
            r = CGFloat((rgb & 0xFF00_0000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF_0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000_FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x0000_00FF) / 255.0

        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String? {
        #if canImport(UIKit)
        let uic = UIColor(self)
        guard let components = uic.cgColor.components, components.count >= 3 else {
            return nil
        }
        #else
        let nsc = NSColor(self)
        guard let components = nsc.cgColor.components, components.count >= 3 else {
            return nil
        }
        #endif
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        var a = Float(1.0)

        if components.count >= 4 {
            a = Float(components[3])
        }

        if a != 1.0 {
            return String(format: "#%02lX%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255), lroundf(a * 255))
        } else {
            return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeManager.shared
}

extension EnvironmentValues {
    var theme: ThemeManager {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var isVisionMode: Bool {
        get { self[VisionModeKey.self] }
        set { self[VisionModeKey.self] = newValue }
    }
}

private struct VisionModeKey: EnvironmentKey {
    static let defaultValue = false
}
