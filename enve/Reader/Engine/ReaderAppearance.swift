import ReadiumNavigator
import ReadiumShared
import SwiftUI

struct ReaderAppearance: Codable, Equatable {

    enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
        case light, sepia, dark, midnight
        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return "Light"
            case .sepia: return "Sepia"
            case .dark: return "Dark"
            case .midnight: return "Midnight"
            }
        }

        var iconName: String {
            switch self {
            case .light: return "sun.max"
            case .sepia: return "book"
            case .dark: return "moon"
            case .midnight: return "moon.stars"
            }
        }
    }

    enum TextAlignment: String, Codable, CaseIterable, Identifiable {
        case left, right, center, justify
        var id: String { rawValue }
    }

    var theme: ReaderTheme = .dark

    var fontSize: Double = 100

    var fontFamily: String = "Original"

    var lineHeight: Double = 1.4

    var letterSpacing: Double = 0.0

    var wordSpacing: Double = 0.0

    var paragraphSpacing: Double = 0.0

    var pageMargins: Double = 0.5

    var topMargins: Double = 0.5

    var bottomMargins: Double = 0.5

    var textAlignment: TextAlignment = .justify

    var scrollEnabled: Bool = false

    var volumeButtonNavigation: Bool = false

    var statusBarBackground: UIColor {
        switch theme {
        case .light: return .systemBackground
        case .sepia: return UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1)
        case .dark: return UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        case .midnight: return UIColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        }
    }

    var primaryTextColor: SwiftUI.Color {
        switch theme {
        case .light: return .primary
        case .sepia: return SwiftUI.Color(red: 0.26, green: 0.20, blue: 0.14)
        case .dark: return SwiftUI.Color.white.opacity(0.92)
        case .midnight: return SwiftUI.Color.white.opacity(0.82)
        }
    }

    var secondaryTextColor: SwiftUI.Color {
        switch theme {
        case .light: return .secondary
        case .sepia: return SwiftUI.Color(red: 0.42, green: 0.36, blue: 0.28)
        case .dark: return SwiftUI.Color.white.opacity(0.55)
        case .midnight: return SwiftUI.Color.white.opacity(0.42)
        }
    }

    var panelBackgroundColor: SwiftUI.Color {
        switch theme {
        case .light: return SwiftUI.Color(.systemBackground)
        case .sepia: return SwiftUI.Color(red: 0.94, green: 0.90, blue: 0.84)
        case .dark: return SwiftUI.Color(red: 0.14, green: 0.16, blue: 0.20)
        case .midnight: return SwiftUI.Color(red: 0.06, green: 0.06, blue: 0.08)
        }
    }

    var buttonBackgroundColor: SwiftUI.Color {
        switch theme {
        case .light: return SwiftUI.Color(.secondarySystemBackground)
        case .sepia: return SwiftUI.Color(red: 0.90, green: 0.86, blue: 0.78).opacity(0.7)
        case .dark: return SwiftUI.Color.white.opacity(0.08)
        case .midnight: return SwiftUI.Color.white.opacity(0.06)
        }
    }

    var accentColor: SwiftUI.Color {
        switch theme {
        case .light: return .blue
        case .sepia: return SwiftUI.Color(red: 0.72, green: 0.45, blue: 0.20)
        case .dark: return SwiftUI.Color(red: 0.45, green: 0.68, blue: 1.0)
        case .midnight: return SwiftUI.Color(red: 0.40, green: 0.60, blue: 1.0)
        }
    }

    var isPureLightMode: Bool {
        theme == .light || theme == .sepia
    }

    var readiumPreferences: EPUBPreferences {
        var prefs = EPUBPreferences()

        prefs.publisherStyles = false

        prefs.fontSize = fontSize / 100.0

        prefs.scroll = scrollEnabled

        prefs.pageMargins = pageMargins

        if fontFamily != "Original" {
            prefs.fontFamily = FontFamily(rawValue: fontFamily)
        }

        prefs.lineHeight = lineHeight
        prefs.letterSpacing = max(letterSpacing, 0.0)
        prefs.wordSpacing = max(wordSpacing, 0.0)
        prefs.paragraphSpacing = max(paragraphSpacing, 0.0)

        switch textAlignment {
        case .left: prefs.textAlign = .left
        case .right: prefs.textAlign = .right
        case .center: prefs.textAlign = .center
        case .justify: prefs.textAlign = .justify
        }

        switch theme {
        case .light: prefs.theme = .light
        case .sepia: prefs.theme = .sepia
        case .dark: prefs.theme = .dark
        case .midnight: prefs.theme = .dark
        }

        return prefs
    }

    var readiumDefaults: EPUBDefaults {
        EPUBDefaults(
            publisherStyles: false,
            scroll: false
        )
    }

    var readiumPreferencesForFixedLayout: EPUBPreferences {
        var prefs = EPUBPreferences()

        switch theme {
        case .light: prefs.theme = .light
        case .sepia: prefs.theme = .sepia
        case .dark, .midnight: prefs.theme = .dark
        }
        return prefs
    }

    private static let storageKey = "enve.reader.appearance.v3"

    static func load() -> ReaderAppearance {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(ReaderAppearance.self, from: data)
        else { return ReaderAppearance() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
