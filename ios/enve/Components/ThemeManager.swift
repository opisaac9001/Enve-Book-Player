import Combine
import SwiftUI

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
