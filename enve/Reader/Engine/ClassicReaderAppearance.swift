@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftUI
import UIKit

enum ReadAloudHighlightColor: String, CaseIterable, Identifiable, Codable {
    case gold, blue, green, pink, purple
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gold: "Gold"
        case .blue: "Blue"
        case .green: "Green"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }

    var cssRGBA: String {
        switch self {
        case .gold: "rgba(255,200,50,0.3)"
        case .blue: "rgba(80,160,255,0.3)"
        case .green: "rgba(80,220,120,0.3)"
        case .pink: "rgba(255,120,160,0.3)"
        case .purple: "rgba(160,100,255,0.3)"
        }
    }

    var cssRGBAStrong: String {
        switch self {
        case .gold: "rgba(255,200,50,0.55)"
        case .blue: "rgba(80,160,255,0.45)"
        case .green: "rgba(80,220,120,0.45)"
        case .pink: "rgba(255,120,160,0.45)"
        case .purple: "rgba(160,100,255,0.45)"
        }
    }

    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .gold: .yellow
        case .blue: .blue
        case .green: .green
        case .pink: .pink
        case .purple: .purple
        }
    }

    var uiColor: UIColor {
        switch self {
        case .gold: UIColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 0.55)
        case .blue: UIColor(red: 0.31, green: 0.63, blue: 1.0, alpha: 0.45)
        case .green: UIColor(red: 0.31, green: 0.86, blue: 0.47, alpha: 0.45)
        case .pink: UIColor(red: 1.0, green: 0.47, blue: 0.63, alpha: 0.45)
        case .purple: UIColor(red: 0.63, green: 0.39, blue: 1.0, alpha: 0.45)
        }
    }
}

enum ReaderThemeOption: String, CaseIterable, Identifiable, Codable {
    case paper, sepia, midnight, eink
    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .midnight: "Midnight"
        case .eink: "E-Ink"
        }
    }

    var previewGradient: LinearGradient {
        switch self {
        case .paper:
            LinearGradient(colors: [SwiftUI.Color(hex: 0xF7F4EF), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sepia:
            LinearGradient(
                colors: [SwiftUI.Color(hex: 0xF3E8D0), SwiftUI.Color(hex: 0xE8D4B0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .midnight:
            LinearGradient(
                colors: [SwiftUI.Color(hex: 0x111318), SwiftUI.Color(hex: 0x1D2430)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .eink:
            LinearGradient(colors: [SwiftUI.Color.white, SwiftUI.Color(hex: 0xF5F5F5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

enum ReaderThemeMode: String, Codable {
    case fixed
    case automatic
}

enum ReaderFontFamilyOption: String, CaseIterable, Identifiable, Codable {
    case serif, sansSerif, openDyslexic, duospace
    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "Serif"
        case .sansSerif: "Sans"
        case .openDyslexic: "Dyslexic"
        case .duospace: "Mono"
        }
    }

    var readiumValue: ReadiumNavigator.FontFamily {
        switch self {
        case .serif: .serif
        case .sansSerif: .sansSerif
        case .openDyslexic: .openDyslexic
        case .duospace: .iaWriterDuospace
        }
    }
}

enum ReaderColumnOption: String, CaseIterable, Identifiable, Codable {
    case auto, one, two
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .one: "1"
        case .two: "2"
        }
    }

    var readiumValue: ReadiumNavigator.ColumnCount {
        switch self {
        case .auto: .auto
        case .one: .one
        case .two: .two
        }
    }
}

enum ReaderComicLayoutOption: String, CaseIterable, Identifiable, Codable {
    case scroll, leftToRight, rightToLeft
    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: "Scroll"
        case .leftToRight: "LTR"
        case .rightToLeft: "RTL"
        }
    }

    var description: String {
        switch self {
        case .scroll:
            return "Stacks pages vertically for uninterrupted scrolling, ideal for webtoons."
        case .leftToRight:
            return "Standard western comic reading order (left to right)."
        case .rightToLeft:
            return "Manga-style reading with right-to-left page progression."
        }
    }
}

enum ComicPageFit: String, CaseIterable, Identifiable, Codable {
    case fitPage, fitWidth, fitHeight
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitPage: "Fit Page"
        case .fitWidth: "Fit Width"
        case .fitHeight: "Fit Height"
        }
    }

    var description: String {
        switch self {
        case .fitPage: return "Show the full page on screen."
        case .fitWidth: return "Fill the screen width, scroll vertically for tall pages."
        case .fitHeight: return "Fill the screen height, scroll horizontally for wide pages."
        }
    }
}

enum ComicBackgroundColor: String, CaseIterable, Identifiable, Codable {
    case black, dark, white
    var id: String { rawValue }

    var label: String {
        switch self {
        case .black: "Black"
        case .dark: "Dark"
        case .white: "White"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .dark: return UIColor(white: 0.12, alpha: 1)
        case .white: return .white
        }
    }

    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .black: return .black
        case .dark: return SwiftUI.Color(white: 0.12)
        case .white: return .white
        }
    }
}

enum ComicPageLoadingMode: String, CaseIterable, Identifiable, Codable {
    case onDemand, sessionCache
    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDemand: "Stream"
        case .sessionCache: "Preload"
        }
    }

    var description: String {
        switch self {
        case .onDemand: "Keeps only nearby pages cached, best for very large comics."
        case .sessionCache: "Caches the whole comic for this reading session, then removes it when you close the reader."
        }
    }
}

enum WritingDirectionOption: String, CaseIterable, Identifiable, Codable {
    case auto, ltr, rtl
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .ltr: "Left → Right"
        case .rtl: "Right → Left"
        }
    }

    var description: String {
        switch self {
        case .auto: "Detect from the book's metadata (recommended)."
        case .ltr: "Force left-to-right reading (English, French, etc.)."
        case .rtl: "Force right-to-left reading (Arabic, Hebrew, etc.)."
        }
    }
}

enum ReadAloudGranularityMode: String, CaseIterable, Identifiable, Codable {
    case auto, sentenceOnly, wordOnly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .sentenceOnly: "Sentence"
        case .wordOnly: "Word"
        }
    }

    var description: String {
        switch self {
        case .auto: "Follow the active phrase without slowing the page."
        case .sentenceOnly: "Only highlight the full sentence."
        case .wordOnly: "Only highlight the current word."
        }
    }
}

struct ClassicReaderAppearance: Codable, Equatable {
    static let storageKey = "enve.ebookReaderAppearance.v2"
    private static let legacyStorageKey = "enve.reader.appearance.v3"

    init() {}

    var theme: ReaderThemeOption = .midnight
    var themeMode: ReaderThemeMode = .fixed
    var lightTheme: ReaderThemeOption = .paper
    var darkTheme: ReaderThemeOption = .midnight
    var fontFamily: ReaderFontFamilyOption = .serif
    var usesCustomFont = false
    var customFontFamilyName: String?
    var columnMode: ReaderColumnOption = .auto
    var comicLayout: ReaderComicLayoutOption = .leftToRight
    var comicPageFit: ComicPageFit = .fitPage
    var comicZoomEnabled: Bool = true
    var comicOneHandedZoom: Bool = false
    var comicBackgroundColor: ComicBackgroundColor = .black
    var comicLandscapeSpread: Bool = true
    var comicPageLoadingMode: ComicPageLoadingMode = .onDemand
    var fontSize: Double = 1.0
    var lineHeight: Double = 1.45
    var pageMargins: Double = 0.5
    var topMargins: Double = 0.5
    var bottomMargins: Double = 0.5
    var paragraphSpacing: Double = 0.0
    var paragraphIndent: Double = 0.0
    var scrollEnabled = false
    var pdfScrollEnabled = false
    var publisherStyles = false
    var justifiedText = true
    var wordSpacing: Double = 0.0
    var letterSpacing: Double = 0.0
    var brightness: Double = 1.0
    var volumeButtonsTurnPages = false
    var tapEdgesTurnPages = true
    var showNextSeriesPrompt = true

    var bionicReading: Bool = false

    var readAloudSyncOffset: Double = 0.0
    var readAloudHighlightColor: ReadAloudHighlightColor = .gold
    var readAloudSkipOnPageTurn: Bool = true
    var readAloudGranularityMode: ReadAloudGranularityMode = .auto
    var readAloudHighlightEnabled: Bool = true
    var readAloudPageTurnLeadMs: Int = 800

    var writingDirection: WritingDirectionOption = .auto
    var verticalWriting: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case theme
        case themeMode
        case lightTheme
        case darkTheme
        case fontFamily
        case usesCustomFont
        case customFontFamilyName
        case columnMode
        case comicLayout
        case comicPageFit
        case comicZoomEnabled
        case comicOneHandedZoom
        case comicBackgroundColor
        case comicLandscapeSpread
        case comicPageLoadingMode
        case fontSize
        case lineHeight
        case pageMargins
        case topMargins
        case bottomMargins
        case paragraphSpacing
        case paragraphIndent
        case scrollEnabled
        case pdfScrollEnabled
        case publisherStyles
        case justifiedText
        case wordSpacing
        case letterSpacing
        case brightness
        case volumeButtonsTurnPages
        case tapEdgesTurnPages
        case showNextSeriesPrompt
        case bionicReading
        case readAloudSyncOffset
        case readAloudHighlightColor
        case readAloudSkipOnPageTurn
        case readAloudGranularityMode
        case readAloudHighlightEnabled
        case readAloudPageTurnLeadMs
        case writingDirection
        case verticalWriting
    }

    init(from decoder: Decoder) throws {
        self = ClassicReaderAppearance()
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let rawTheme = try? c.decode(String.self, forKey: .theme) {
            theme = Self.migratedTheme(from: rawTheme)
        }

        if let rawThemeMode = try? c.decode(String.self, forKey: .themeMode),
            let decodedThemeMode = ReaderThemeMode(rawValue: rawThemeMode)
        {
            themeMode = decodedThemeMode
        }

        if let rawLightTheme = try? c.decode(String.self, forKey: .lightTheme) {
            lightTheme = Self.migratedTheme(from: rawLightTheme)
        }

        if let rawDarkTheme = try? c.decode(String.self, forKey: .darkTheme) {
            darkTheme = Self.migratedTheme(from: rawDarkTheme)
        }

        if let rawFontFamily = try? c.decode(String.self, forKey: .fontFamily) {
            fontFamily = Self.migratedFontFamily(from: rawFontFamily)
        }

        usesCustomFont = (try? c.decode(Bool.self, forKey: .usesCustomFont)) ?? usesCustomFont
        customFontFamilyName = try? c.decodeIfPresent(String.self, forKey: .customFontFamilyName)

        if let rawColumn = try? c.decode(String.self, forKey: .columnMode),
            let mode = ReaderColumnOption(rawValue: rawColumn)
        {
            columnMode = mode
        }

        if let rawComicLayout = try? c.decode(String.self, forKey: .comicLayout),
            let layout = ReaderComicLayoutOption(rawValue: rawComicLayout)
        {
            comicLayout = layout
        }

        if let rawComicPageFit = try? c.decode(String.self, forKey: .comicPageFit),
            let fit = ComicPageFit(rawValue: rawComicPageFit)
        {
            comicPageFit = fit
        }

        comicZoomEnabled = (try? c.decode(Bool.self, forKey: .comicZoomEnabled)) ?? comicZoomEnabled
        comicOneHandedZoom = (try? c.decode(Bool.self, forKey: .comicOneHandedZoom)) ?? comicOneHandedZoom

        if let rawComicBackground = try? c.decode(String.self, forKey: .comicBackgroundColor),
            let color = ComicBackgroundColor(rawValue: rawComicBackground)
        {
            comicBackgroundColor = color
        }

        comicLandscapeSpread = (try? c.decode(Bool.self, forKey: .comicLandscapeSpread)) ?? comicLandscapeSpread

        if let rawLoadingMode = try? c.decode(String.self, forKey: .comicPageLoadingMode),
            let loadingMode = ComicPageLoadingMode(rawValue: rawLoadingMode)
        {
            comicPageLoadingMode = loadingMode
        }

        if let storedFontSize = try? c.decode(Double.self, forKey: .fontSize) {
            let normalized = storedFontSize > 10 ? storedFontSize / 100.0 : storedFontSize
            fontSize = max(0.5, min(3.0, normalized))
        }

        lineHeight = (try? c.decode(Double.self, forKey: .lineHeight)) ?? lineHeight
        pageMargins = (try? c.decode(Double.self, forKey: .pageMargins)) ?? pageMargins
        topMargins = (try? c.decode(Double.self, forKey: .topMargins)) ?? topMargins
        bottomMargins = (try? c.decode(Double.self, forKey: .bottomMargins)) ?? bottomMargins
        paragraphSpacing = (try? c.decode(Double.self, forKey: .paragraphSpacing)) ?? paragraphSpacing
        paragraphIndent = min(
            max((try? c.decode(Double.self, forKey: .paragraphIndent)) ?? paragraphIndent, 0),
            3
        )
        scrollEnabled = (try? c.decode(Bool.self, forKey: .scrollEnabled)) ?? scrollEnabled
        pdfScrollEnabled = (try? c.decode(Bool.self, forKey: .pdfScrollEnabled)) ?? pdfScrollEnabled
        publisherStyles = (try? c.decode(Bool.self, forKey: .publisherStyles)) ?? publisherStyles
        justifiedText = (try? c.decode(Bool.self, forKey: .justifiedText)) ?? justifiedText
        wordSpacing = (try? c.decode(Double.self, forKey: .wordSpacing)) ?? wordSpacing
        letterSpacing = (try? c.decode(Double.self, forKey: .letterSpacing)) ?? letterSpacing
        brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? brightness
        volumeButtonsTurnPages = (try? c.decode(Bool.self, forKey: .volumeButtonsTurnPages)) ?? volumeButtonsTurnPages
        tapEdgesTurnPages = (try? c.decode(Bool.self, forKey: .tapEdgesTurnPages)) ?? tapEdgesTurnPages
        showNextSeriesPrompt = (try? c.decode(Bool.self, forKey: .showNextSeriesPrompt)) ?? showNextSeriesPrompt
        bionicReading = (try? c.decode(Bool.self, forKey: .bionicReading)) ?? bionicReading

        readAloudSyncOffset = (try? c.decode(Double.self, forKey: .readAloudSyncOffset)) ?? readAloudSyncOffset
        if let rawHighlight = try? c.decode(String.self, forKey: .readAloudHighlightColor),
            let highlight = ReadAloudHighlightColor(rawValue: rawHighlight)
        {
            readAloudHighlightColor = highlight
        }
        readAloudSkipOnPageTurn = (try? c.decode(Bool.self, forKey: .readAloudSkipOnPageTurn)) ?? readAloudSkipOnPageTurn
        readAloudHighlightEnabled = (try? c.decode(Bool.self, forKey: .readAloudHighlightEnabled)) ?? readAloudHighlightEnabled
        readAloudPageTurnLeadMs = max(0, min(1500, (try? c.decode(Int.self, forKey: .readAloudPageTurnLeadMs)) ?? readAloudPageTurnLeadMs))
        if let rawGranularity = try? c.decode(String.self, forKey: .readAloudGranularityMode),
            let granularity = ReadAloudGranularityMode(rawValue: rawGranularity)
        {
            readAloudGranularityMode = granularity
        }

        if let rawDirection = try? c.decode(String.self, forKey: .writingDirection),
            let direction = WritingDirectionOption(rawValue: rawDirection)
        {
            writingDirection = direction
        }
        verticalWriting = try? c.decodeIfPresent(Bool.self, forKey: .verticalWriting)
    }

    private static func migratedTheme(from raw: String) -> ReaderThemeOption {
        switch raw.lowercased() {
        case ReaderThemeOption.paper.rawValue, "light": return .paper
        case ReaderThemeOption.sepia.rawValue: return .sepia
        case ReaderThemeOption.midnight.rawValue, "dark": return .midnight
        case ReaderThemeOption.eink.rawValue: return .eink
        default: return .midnight
        }
    }

    private static func migratedFontFamily(from raw: String) -> ReaderFontFamilyOption {
        switch raw.lowercased() {
        case ReaderFontFamilyOption.serif.rawValue.lowercased(), "original": return .serif
        case ReaderFontFamilyOption.sansSerif.rawValue.lowercased(), "sans", "sansserif": return .sansSerif
        case ReaderFontFamilyOption.openDyslexic.rawValue.lowercased(), "dyslexic": return .openDyslexic
        case ReaderFontFamilyOption.duospace.rawValue.lowercased(), "mono": return .duospace
        default: return .serif
        }
    }

    private static func migratedFromLegacyIfAvailable() -> ClassicReaderAppearance? {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey),
            let legacy = try? JSONDecoder().decode(ReaderAppearance.self, from: data)
        else {
            return nil
        }

        var migrated = ClassicReaderAppearance()
        switch legacy.theme {
        case .light:
            migrated.theme = .paper
        case .sepia:
            migrated.theme = .sepia
        case .dark, .midnight:
            migrated.theme = .midnight
        }

        migrated.fontFamily = migratedFontFamily(from: legacy.fontFamily)
        migrated.fontSize = max(0.5, min(3.0, legacy.fontSize / 100.0))
        migrated.lineHeight = legacy.lineHeight
        migrated.letterSpacing = legacy.letterSpacing
        migrated.wordSpacing = legacy.wordSpacing
        migrated.paragraphSpacing = legacy.paragraphSpacing
        migrated.pageMargins = legacy.pageMargins
        migrated.topMargins = legacy.topMargins
        migrated.bottomMargins = legacy.bottomMargins
        migrated.scrollEnabled = legacy.scrollEnabled
        migrated.volumeButtonsTurnPages = legacy.volumeButtonNavigation
        migrated.justifiedText = legacy.textAlignment == .justify
        return migrated
    }

    static func load() -> ClassicReaderAppearance {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
            let value = try? JSONDecoder().decode(ClassicReaderAppearance.self, from: data)
        else {
            if let migrated = migratedFromLegacyIfAvailable() {
                migrated.persist()
                UserDefaults.standard.removeObject(forKey: legacyStorageKey)
                return migrated
            }
            return ClassicReaderAppearance()
        }
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        return value
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func resolved(for colorScheme: ColorScheme) -> ClassicReaderAppearance {
        guard themeMode == .automatic else { return self }
        var resolved = self
        resolved.theme = colorScheme == .dark ? darkTheme : lightTheme
        return resolved
    }

    private var pageBackgroundHex: Int {
        switch theme {
        case .paper: return 0xF2EEE3
        case .sepia: return 0xFAF4E8
        case .midnight: return 0x000000
        case .eink: return 0xFFFFFF
        }
    }

    private var pageTextHex: Int {
        switch theme {
        case .paper: return 0x1D1D1D
        case .sepia: return 0x121212
        case .midnight: return 0xFEFEFE
        case .eink: return 0x000000
        }
    }

    var readiumPreferencesForFixedLayout: EPUBPreferences {
        var prefs = EPUBPreferences()
        prefs.publisherStyles = true
        prefs.theme = .light
        return prefs
    }

    var readiumPreferences: EPUBPreferences {
        var prefs = EPUBPreferences()
        prefs.fontSize = fontSize
        prefs.lineHeight = lineHeight
        prefs.pageMargins = pageMargins
        prefs.scroll = scrollEnabled
        if !scrollEnabled {
            prefs.columnCount = columnMode.readiumValue
        }
        prefs.textAlign = justifiedText ? .justify : .start
        prefs.publisherStyles = theme == .eink ? false : publisherStyles

        switch writingDirection {
        case .auto:
            break
        case .ltr:
            prefs.readingProgression = .ltr
        case .rtl:
            prefs.readingProgression = .rtl
        }

        if let verticalWriting {
            prefs.verticalText = verticalWriting
        }

        if usesCustomFont, let name = customFontFamilyName, !name.isEmpty {
            prefs.fontFamily = FontFamily(rawValue: name)
        } else {
            prefs.fontFamily = fontFamily.readiumValue
        }

        if letterSpacing > 0 { prefs.letterSpacing = letterSpacing }
        if wordSpacing > 0 { prefs.wordSpacing = wordSpacing }
        if paragraphSpacing > 0 { prefs.paragraphSpacing = paragraphSpacing }
        prefs.paragraphIndent = paragraphIndent

        switch theme {
        case .paper, .eink:
            prefs.theme = .light
            prefs.backgroundColor = ReadiumNavigator.Color(rawValue: pageBackgroundHex)
            prefs.textColor = ReadiumNavigator.Color(rawValue: pageTextHex)
        case .sepia:
            prefs.theme = .sepia
        case .midnight:
            prefs.theme = .dark
        }

        return prefs
    }

    private var readiumTheme: ReadiumNavigator.Theme {
        switch theme {
        case .paper: .light
        case .sepia: .sepia
        case .midnight: .dark
        case .eink: .light
        }
    }

    var shellBackgroundColor: UIColor {
        UIColor(
            red: CGFloat((pageBackgroundHex >> 16) & 0xFF) / 255,
            green: CGFloat((pageBackgroundHex >> 8) & 0xFF) / 255,
            blue: CGFloat(pageBackgroundHex & 0xFF) / 255,
            alpha: 1
        )
    }

    var accentColor: SwiftUI.Color {
        switch theme {
        case .paper: SwiftUI.Color(hex: 0x2E5AAC)
        case .sepia: SwiftUI.Color(hex: 0x8C5A22)
        case .midnight: SwiftUI.Color(hex: 0x7CB8FF)
        case .eink: .black
        }
    }

    var panelBackgroundColor: SwiftUI.Color {
        switch theme {
        case .paper: .white.opacity(0.8)
        case .sepia: .white.opacity(0.5)
        case .midnight: .black.opacity(0.46)
        case .eink: .white
        }
    }

    var buttonBackgroundColor: SwiftUI.Color {
        switch theme {
        case .paper: .white.opacity(0.86)
        case .sepia: .white.opacity(0.48)
        case .midnight: .black.opacity(0.5)
        case .eink: .white
        }
    }

    var primaryTextColor: SwiftUI.Color {
        switch theme {
        case .paper, .sepia, .eink: .black.opacity(theme == .eink ? 1 : 0.82)
        case .midnight: .white.opacity(0.96)
        }
    }

    var secondaryTextColor: SwiftUI.Color {
        switch theme {
        case .paper, .sepia: .black.opacity(0.55)
        case .eink: .black.opacity(0.72)
        case .midnight: .white.opacity(0.66)
        }
    }

    var isPureLightMode: Bool {
        theme == .eink
    }

    var selectedFontLabel: String {
        if usesCustomFont, let customFontFamilyName, !customFontFamilyName.isEmpty {
            return customFontFamilyName
        }
        return fontFamily.label
    }

    func previewFont(size: CGFloat) -> Font {
        if usesCustomFont, let customFontFamilyName, !customFontFamilyName.isEmpty {
            return .custom(customFontFamilyName, size: size)
        }

        switch fontFamily {
        case .serif:
            return .system(size: size, weight: .semibold, design: .serif)
        case .sansSerif:
            return .system(size: size, weight: .semibold, design: .default)
        case .openDyslexic:
            return .system(size: size, weight: .semibold, design: .rounded)
        case .duospace:
            return .system(size: size, weight: .semibold, design: .monospaced)
        }
    }
}

extension SwiftUI.Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
