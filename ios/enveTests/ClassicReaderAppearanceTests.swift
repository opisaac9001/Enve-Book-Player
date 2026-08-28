import Foundation
@preconcurrency import ReadiumNavigator
import SwiftUI
import Testing

@testable import enve

struct ClassicReaderAppearanceTests {
    @Test func paragraphIndentRoundTripsAndMapsToReadium() throws {
        var appearance = ClassicReaderAppearance()
        appearance.paragraphIndent = 1.25

        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(ClassicReaderAppearance.self, from: data)

        #expect(decoded.paragraphIndent == 1.25)
        #expect(decoded.readiumPreferences.paragraphIndent == 1.25)
    }

    @Test func paragraphIndentDefaultsAndClampsStoredValues() throws {
        let missing = try JSONDecoder().decode(
            ClassicReaderAppearance.self,
            from: Data("{}".utf8)
        )
        let excessive = try JSONDecoder().decode(
            ClassicReaderAppearance.self,
            from: Data(#"{"paragraphIndent":9}"#.utf8)
        )

        #expect(missing.paragraphIndent == 0)
        #expect(missing.readiumPreferences.paragraphIndent == 0)
        #expect(excessive.paragraphIndent == 3)
    }

    @Test func automaticThemeSettingsDefaultWithoutResettingOlderPreferences() throws {
        let decoded = try JSONDecoder().decode(
            ClassicReaderAppearance.self,
            from: Data(#"{"theme":"sepia","fontSize":1.4}"#.utf8)
        )

        #expect(decoded.theme == .sepia)
        #expect(decoded.fontSize == 1.4)
        #expect(decoded.themeMode == .fixed)
        #expect(decoded.lightTheme == .paper)
        #expect(decoded.darkTheme == .midnight)
    }

    @Test func automaticThemeRoundTripsAndResolvesForBothColorSchemes() throws {
        var appearance = ClassicReaderAppearance()
        appearance.themeMode = .automatic
        appearance.lightTheme = .sepia
        appearance.darkTheme = .midnight

        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(ClassicReaderAppearance.self, from: data)

        #expect(decoded.themeMode == .automatic)
        #expect(decoded.resolved(for: .light).theme == .sepia)
        #expect(decoded.resolved(for: .dark).theme == .midnight)
        #expect(decoded.theme == .midnight)
    }

    @Test func nextSeriesPromptPlacementDefaultsAndRoundTrips() throws {
        let missing = try JSONDecoder().decode(
            ClassicReaderAppearance.self,
            from: Data("{}".utf8)
        )
        var appearance = ClassicReaderAppearance()
        appearance.nextSeriesPromptPlacement = .top

        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(ClassicReaderAppearance.self, from: data)

        #expect(missing.nextSeriesPromptPlacement == .bottom)
        #expect(decoded.nextSeriesPromptPlacement == .top)
    }
}
