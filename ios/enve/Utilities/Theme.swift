import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct Theme {
    nonisolated(unsafe) public static var currentPreferences: UserPreferences = .default
    nonisolated private static let themeColorHexDefaultsKey = "themeColorHex"

    nonisolated private static var hasStoredThemeColorHex: Bool {
        UserDefaults.standard.string(forKey: themeColorHexDefaultsKey) != nil
    }

    nonisolated private static var usesLegacyDefaultAccent: Bool {
        abs(currentPreferences.primaryColorRed - ThemeManager.legacyAccentRed) < 0.0001
            && abs(currentPreferences.primaryColorGreen - ThemeManager.legacyAccentGreen) < 0.0001
            && abs(currentPreferences.primaryColorBlue - ThemeManager.legacyAccentBlue) < 0.0001
    }

    nonisolated private static func rgbComponents(fromHex hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat?)? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        switch hexSanitized.count {
        case 6:
            return (
                CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
                CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
                CGFloat(rgb & 0x0000FF) / 255.0,
                nil
            )
        case 8:
            return (
                CGFloat((rgb & 0xFF00_0000) >> 24) / 255.0,
                CGFloat((rgb & 0x00FF_0000) >> 16) / 255.0,
                CGFloat((rgb & 0x0000_FF00) >> 8) / 255.0,
                CGFloat(rgb & 0x0000_00FF) / 255.0
            )
        default:
            return nil
        }
    }

    nonisolated private static var resolvedAccentComponents: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        if let storedHex = UserDefaults.standard.string(forKey: themeColorHexDefaultsKey),
            let storedComponents = rgbComponents(fromHex: storedHex)
        {
            if let alpha = storedComponents.alpha, alpha <= 0 {
                return (
                    ThemeManager.defaultAccentRed,
                    ThemeManager.defaultAccentGreen,
                    ThemeManager.defaultAccentBlue
                )
            }

            return (
                storedComponents.red,
                storedComponents.green,
                storedComponents.blue
            )
        }

        if !hasStoredThemeColorHex && usesLegacyDefaultAccent {
            return (
                ThemeManager.defaultAccentRed,
                ThemeManager.defaultAccentGreen,
                ThemeManager.defaultAccentBlue
            )
        }

        return (
            currentPreferences.primaryColorRed,
            currentPreferences.primaryColorGreen,
            currentPreferences.primaryColorBlue
        )
    }

    nonisolated private static var resolvedAccentColor: Color {
        let components = resolvedAccentComponents
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    nonisolated public static var isVisionMode: Bool {
        currentPreferences.visionImpairedModeEnabled
    }

    nonisolated public static var dynamicBackgroundEnabled: Bool {
        currentPreferences.dynamicBackgroundEnabled
    }

    nonisolated public static var primaryColor: Color {
        resolvedAccentColor
    }

    nonisolated public static var accentColor: Color {
        primaryColor
    }

    nonisolated public static var backgroundColor: Color {
        switch currentPreferences.theme {
        case .light:
            #if os(iOS)
            return Color(.systemBackground)
            #elseif os(macOS)
            return Color(NSColor.windowBackgroundColor)
            #else
            return Color.black
            #endif
        case .dark:
            return Color.black
        case .oled:
            return Color(red: 0, green: 0, blue: 0, opacity: 1.0)
        case .system:
            #if os(iOS)
            return Color(.systemBackground)
            #elseif os(macOS)
            return Color(NSColor.windowBackgroundColor)
            #else
            return Color.black
            #endif
        }
    }

    nonisolated public static var cardBackground: Color {
        switch currentPreferences.theme {
        case .light:
            #if os(iOS)
            return Color(.systemBackground)
            #elseif os(macOS)
            return Color(NSColor.windowBackgroundColor)
            #else
            return Color.black
            #endif
        case .dark:
            return Color(white: 0.15)
        case .oled:
            return Color(white: 0.08)
        case .system:
            #if os(iOS)
            return Color(
                UIColor { traitCollection in
                    traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1.0) : UIColor.systemBackground
                }
            )
            #elseif os(macOS)
            return Color(NSColor.windowBackgroundColor)
            #else
            return Color(white: 0.15)
            #endif
        }
    }

    nonisolated public static var secondaryBackground: Color {
        switch currentPreferences.theme {
        case .light:
            #if os(iOS)
            return Color(.secondarySystemBackground)
            #elseif os(macOS)
            return Color(NSColor.controlBackgroundColor)
            #else
            return Color(white: 0.12)
            #endif
        case .dark:
            return Color(white: 0.1)
        case .oled:
            return Color(white: 0.05)
        case .system:
            #if os(iOS)
            return Color(.secondarySystemBackground)
            #elseif os(macOS)
            return Color(NSColor.controlBackgroundColor)
            #else
            return Color(white: 0.12)
            #endif
        }
    }

    nonisolated public static var primaryText: Color {
        if isVisionMode {
            if currentPreferences.theme == .system {
                #if canImport(UIKit)
                return Color(
                    UIColor { traitCollection in
                        traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
                    }
                )
                #else
                return Color.primary
                #endif
            }
            return currentPreferences.theme == .light ? .black : .white
        }

        switch currentPreferences.theme {
        case .light:
            return Color.primary
        case .dark, .oled:
            return Color.white
        case .system:
            return Color.primary
        }
    }

    nonisolated public static var onPrimaryText: Color {
        let components = resolvedAccentComponents
        let r = components.red
        let g = components.green
        let b = components.blue
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.5 ? .black : .white
    }

    nonisolated public static var secondaryText: Color {
        if isVisionMode {
            if currentPreferences.theme == .system {
                #if canImport(UIKit)
                return Color(
                    UIColor { traitCollection in
                        traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
                    }
                )
                #else
                return Color.primary
                #endif
            }
            return currentPreferences.theme == .light ? .black : .white
        }
        switch currentPreferences.theme {
        case .light:
            return Color(white: 0.3)
        case .dark:
            return Color(white: 0.8)
        case .oled:
            return Color(white: 0.75)
        case .system:
            #if canImport(UIKit)
            return Color(
                UIColor { traitCollection in
                    traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.8, alpha: 1.0) : UIColor(white: 0.3, alpha: 1.0)
                }
            )
            #else
            return Color.secondary
            #endif
        }
    }

    nonisolated public static var tertiaryText: Color {
        if isVisionMode {
            if currentPreferences.theme == .system {
                #if canImport(UIKit)
                return Color(
                    UIColor { traitCollection in
                        traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
                    }
                )
                #else
                return Color.primary
                #endif
            }
            return currentPreferences.theme == .light ? .black : .white
        }
        switch currentPreferences.theme {
        case .light:
            return Color(white: 0.5)
        case .dark:
            return Color(white: 0.6)
        case .oled:
            return Color(white: 0.55)
        case .system:
            #if canImport(UIKit)
            return Color(
                UIColor { traitCollection in
                    traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.6, alpha: 1.0) : UIColor(white: 0.5, alpha: 1.0)
                }
            )
            #else
            return Color.gray
            #endif
        }
    }

    nonisolated public static var placeholderText: Color {
        if isVisionMode {
            if currentPreferences.theme == .system {
                #if canImport(UIKit)
                return Color(
                    UIColor { traitCollection in
                        traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
                    }
                )
                #else
                return Color.primary
                #endif
            }
            return currentPreferences.theme == .light ? .black : .white
        }
        switch currentPreferences.theme {
        case .light:
            return Color(white: 0.55)
        case .dark:
            return Color(white: 0.45)
        case .oled:
            return Color(white: 0.5)
        case .system:
            #if canImport(UIKit)
            return Color(
                UIColor { traitCollection in
                    traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.45, alpha: 1.0) : UIColor(white: 0.55, alpha: 1.0)
                }
            )
            #else
            return Color.secondary
            #endif
        }
    }

    public static let spacingSmall: CGFloat = 8
    public static let spacingMedium: CGFloat = 16
    public static let spacingLarge: CGFloat = 24
    public static let spacingXLarge: CGFloat = 32

    public static var minimumTouchTarget: CGFloat {
        isVisionMode ? 56 : 44
    }

    public static let cornerRadiusSmall: CGFloat = 8
    public static let cornerRadiusMedium: CGFloat = 12
    public static let cornerRadiusLarge: CGFloat = 16

    public static func shadow(radius: CGFloat = 10, opacity: Double = 0.3) -> some View {
        Color.black.opacity(opacity)
            .blur(radius: radius)
    }

    #if canImport(UIKit)
    public static var primaryColorUIColor: UIColor {
        let components = resolvedAccentComponents
        return UIColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1.0
        )
    }
    #endif

    nonisolated public static func headlineFont(visionMode: Bool) -> Font {
        visionMode ? .system(size: 24, weight: .bold) : .headline
    }

    nonisolated public static func titleFont(visionMode: Bool) -> Font {
        visionMode ? .system(size: 22, weight: .bold) : .title
    }

    nonisolated public static func bodyFont(visionMode: Bool) -> Font {
        visionMode ? .system(size: 17) : .body
    }

    nonisolated public static func captionFont(visionMode: Bool) -> Font {
        visionMode ? .system(size: 15) : .caption
    }

    nonisolated public static func spacingMultiplier(visionMode: Bool) -> CGFloat {
        visionMode ? 1.5 : 1.0
    }
}

struct ThemedPlaceholderModifier: ViewModifier {
    let placeholder: String
    let text: String

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(Theme.placeholderText)
            }
            content
                .foregroundColor(Theme.primaryText)
        }
    }
}

extension View {
    func themedPlaceholder(_ placeholder: String, text: String) -> some View {
        modifier(ThemedPlaceholderModifier(placeholder: placeholder, text: text))
    }
}
