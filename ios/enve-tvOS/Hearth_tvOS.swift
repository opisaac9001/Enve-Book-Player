import SwiftUI

// tvOS has no appearance setting, so it always uses the iOS Hearth Ink palette.
struct HearthPalette: Equatable {
    var bg: Color
    var bgElevated: Color
    var bgSunken: Color
    var text: Color
    var textSecondary: Color
    var ember: Color
    var hairline: Color

    static func ink(accent: Color, highContrast: Bool = false) -> HearthPalette {
        var palette = HearthPalette(
            bg: Color(hexValue: 0x2D2322),
            bgElevated: Color(hexValue: 0x3A2B26),
            bgSunken: Color(hexValue: 0x1C1513),
            text: Color(hexValue: 0xF6DEAA),
            textSecondary: Color(hexValue: 0xD4BE98),
            ember: accent,
            hairline: Color(hexValue: 0xF6DEAA).opacity(0.12)
        )
        if highContrast {
            palette.textSecondary = palette.text
            palette.hairline = .white.opacity(0.45)
        }
        return palette
    }
}

private struct HearthPaletteKey: EnvironmentKey {
    static let defaultValue = HearthPalette.ink(accent: ThemeManager.defaultAccentColor)
}

extension EnvironmentValues {
    var hearth: HearthPalette {
        get { self[HearthPaletteKey.self] }
        set { self[HearthPaletteKey.self] = newValue }
    }
}

private struct HearthRootModifier: ViewModifier {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let palette = HearthPalette.ink(
            accent: theme.themeColor,
            highContrast: theme.isVisionMode || colorSchemeContrast == .increased
        )
        content
            .environment(\.hearth, palette)
            .tint(palette.ember)
            .preferredColorScheme(.dark)
    }
}

private struct HearthCanvasModifier: ViewModifier {
    @Environment(\.hearth) private var hearth

    func body(content: Content) -> some View {
        content
            .background(hearth.bg.ignoresSafeArea())
    }
}

extension View {
    func hearthRoot() -> some View { modifier(HearthRootModifier()) }
    func hearthCanvas() -> some View { modifier(HearthCanvasModifier()) }
}

extension Font {
    static func hearthDisplay(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension Color {
    init(hexValue: Int) {
        self.init(
            red: Double((hexValue >> 16) & 0xFF) / 255,
            green: Double((hexValue >> 8) & 0xFF) / 255,
            blue: Double(hexValue & 0xFF) / 255
        )
    }
}
