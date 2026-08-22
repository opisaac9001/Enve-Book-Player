import SwiftUI
import UIKit

enum Hearth {
    enum Mode: String, CaseIterable {
        case system, ink, paper

        var title: String {
            switch self {
            case .system: "System"
            case .ink: "Ink"
            case .paper: "Paper"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .ink: .dark
            case .paper: .light
            }
        }
    }

    private static let modeKey = "hearth.mode"
    private static let oledKey = "hearth.oled"

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var oledEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: oledKey) }
        set { UserDefaults.standard.set(newValue, forKey: oledKey) }
    }

    static var accent: Color {
        accent(fromHex: UserDefaults.standard.string(forKey: "themeColorHex"))
    }

    static func accent(fromHex hex: String?) -> Color {
        if let hex, let color = Color(hexString: hex) {
            return color
        }
        return Color(hexValue: 0xF5921A)
    }

    static func palette(
        for scheme: ColorScheme,
        accent: Color? = nil,
        oled: Bool = false,
        highContrast: Bool = false,
        reduceTransparency: Bool = false
    ) -> HearthPalette {
        let resolved = accent ?? Self.accent
        let base =
            if scheme == .dark {
                oled ? HearthPalette.oled(accent: resolved) : HearthPalette.ink(accent: resolved)
            } else {
                HearthPalette.paper(accent: resolved)
            }
        return base.accessible(highContrast: highContrast, reduceTransparency: reduceTransparency)
    }

    static func scaled(_ size: CGFloat) -> CGFloat {
        var scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        if ThemeManager.shared.isVisionMode {
            scaled *= 1.15
        }
        return scaled
    }

    static let radiusCover: CGFloat = 12
    static let radiusInner: CGFloat = 14
    static let radiusCard: CGFloat = 20
    static let radiusBar: CGFloat = 30
}

struct HearthPalette: Equatable {
    var isInk: Bool
    var bg: Color
    var bgElevated: Color
    var bgSunken: Color
    var text: Color
    var textSecondary: Color
    var textTertiary: Color
    var ember: Color
    var emberSoft: Color
    var hairline: Color

    var onEmber: Color
    var readableOnEmber: Color {
        Self.readableForeground(on: ember, dark: onEmber)
    }
    var statusOK: Color
    var statusWarn: Color
    var statusError: Color

    static func ink(accent: Color) -> HearthPalette {
        HearthPalette(
            isInk: true,
            bg: Color(hexValue: 0x0C0A09),
            bgElevated: Color(hexValue: 0x191512),
            bgSunken: .black,
            text: Color(hexValue: 0xF0E9DC),
            textSecondary: Color(hexValue: 0xA99F92),
            textTertiary: Color(hexValue: 0x6E665C),
            ember: accent,
            emberSoft: accent.opacity(0.14),
            hairline: .white.opacity(0.08),
            onEmber: Color(hexValue: 0x1A120A),
            statusOK: Color(hexValue: 0x8FBF7F),
            statusWarn: Color(hexValue: 0xE0A458),
            statusError: Color(hexValue: 0xD06A5C)
        )
    }

    static func oled(accent: Color) -> HearthPalette {
        HearthPalette(
            isInk: true,
            bg: .black,
            bgElevated: Color(hexValue: 0x0C0C0D),
            bgSunken: .black,
            text: Color(hexValue: 0xF0E9DC),
            textSecondary: Color(hexValue: 0xA99F92),
            textTertiary: Color(hexValue: 0x6E665C),
            ember: accent,
            emberSoft: accent.opacity(0.16),
            hairline: .white.opacity(0.11),
            onEmber: Color(hexValue: 0x1A120A),
            statusOK: Color(hexValue: 0x8FBF7F),
            statusWarn: Color(hexValue: 0xE0A458),
            statusError: Color(hexValue: 0xD06A5C)
        )
    }

    static func paper(accent: Color) -> HearthPalette {
        HearthPalette(
            isInk: false,
            bg: Color(hexValue: 0xF7F2E9),
            bgElevated: .white,
            bgSunken: Color(hexValue: 0xEFE8DB),
            text: Color(hexValue: 0x231F1B),
            textSecondary: Color(hexValue: 0x7A7064),
            textTertiary: Color(hexValue: 0xA89D8F),
            ember: deepened(accent),
            emberSoft: accent.opacity(0.12),
            hairline: .black.opacity(0.08),
            onEmber: Color(hexValue: 0x1A120A),
            statusOK: Color(hexValue: 0x4F7942),
            statusWarn: Color(hexValue: 0xA8762A),
            statusError: Color(hexValue: 0xA8453A)
        )
    }

    private static func deepened(_ color: Color) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return Color(uiColor: UIColor(hue: h, saturation: min(s * 1.08, 1), brightness: b * 0.91, alpha: a))
    }

    static func readableForeground(
        on color: Color,
        dark: Color = Color(hexValue: 0x1A120A),
        light: Color = Color(hexValue: 0xFFF7EA)
    ) -> Color {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return dark }
        let luminance = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
        return luminance < 0.52 ? light : dark
    }

    func accessible(highContrast: Bool, reduceTransparency: Bool) -> HearthPalette {
        var palette = self
        if highContrast {
            palette.textSecondary = palette.text
            palette.textTertiary = palette.text
            palette.hairline = palette.isInk ? .white.opacity(0.45) : .black.opacity(0.45)
            palette.statusOK = palette.isInk ? Color(hexValue: 0xC6F1AF) : Color(hexValue: 0x245A1C)
            palette.statusWarn = palette.isInk ? Color(hexValue: 0xFFD28C) : Color(hexValue: 0x824600)
            palette.statusError = palette.isInk ? Color(hexValue: 0xFFB4AA) : Color(hexValue: 0x8F1D14)
        }
        if reduceTransparency {
            palette.emberSoft = palette.bgElevated
        }
        return palette
    }
}

private struct HearthPaletteKey: EnvironmentKey {
    static let defaultValue = HearthPalette.ink(accent: Color(hexValue: 0xF5921A))
}

private struct MantelInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var hearth: HearthPalette {
        get { self[HearthPaletteKey.self] }
        set { self[HearthPaletteKey.self] = newValue }
    }

    var mantelInset: CGFloat {
        get { self[MantelInsetKey.self] }
        set { self[MantelInsetKey.self] = newValue }
    }
}

private struct HearthRootModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("themeColorHex") private var accentHex: String?
    @AppStorage("hearth.oled") private var oledEnabled = false
    @AppStorage("visionImpairedModeEnabled") private var visionModeEnabled = false

    func body(content: Content) -> some View {
        content
            .environment(
                \.hearth,
                Hearth.palette(
                    for: colorScheme,
                    accent: Hearth.accent(fromHex: accentHex),
                    oled: oledEnabled,
                    highContrast: visionModeEnabled || colorSchemeContrast == .increased,
                    reduceTransparency: reduceTransparency
                )
            )
    }
}

extension View {
    func hearthRoot() -> some View {
        modifier(HearthRootModifier())
    }
}

extension Font {

    static func hearthDisplay(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: Hearth.scaled(size), weight: weight, design: .serif)
    }

    static func hearthUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: Hearth.scaled(size), weight: weight)
    }

    static var hearthScreenTitle: Font { .hearthDisplay(32) }
    static var hearthBookTitle: Font { .hearthDisplay(22, weight: .semibold) }
    static var hearthBody: Font { .hearthUI(16) }
    static var hearthCaption: Font { .hearthUI(13) }
}

struct Overline: View {
    let text: String
    var color: Color?
    @Environment(\.hearth) private var hearth

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.hearthUI(11, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(color ?? hearth.textSecondary)
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

    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(hexValue: value)
    }
}
