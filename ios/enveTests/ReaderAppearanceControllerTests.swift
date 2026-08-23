import SwiftUI
import Testing

@testable import enve

@MainActor
struct ReaderAppearanceControllerTests {
    @Test func invalidCustomFontIsRemovedAtInitialization() {
        var appearance = ClassicReaderAppearance()
        appearance.usesCustomFont = true
        appearance.customFontFamilyName = "Missing"
        var persisted: ClassicReaderAppearance?

        let controller = ReaderAppearanceController(
            appearance: appearance,
            persist: { persisted = $0 },
            hasUsableFontFamily: { _ in false }
        )

        #expect(!controller.appearance.usesCustomFont)
        #expect(controller.appearance.customFontFamilyName == nil)
        #expect(persisted == controller.appearance)
    }

    @Test func automaticThemeTracksSystemColorScheme() {
        var appearance = ClassicReaderAppearance()
        appearance.themeMode = .automatic
        appearance.lightTheme = .paper
        appearance.darkTheme = .midnight
        let controller = ReaderAppearanceController(
            appearance: appearance,
            systemColorScheme: .light,
            persist: { _ in },
            hasUsableFontFamily: { _ in true }
        )
        var applied: ClassicReaderAppearance?
        controller.onApply = { applied = $0 }

        #expect(controller.effectiveAppearance.theme == .paper)
        controller.updateSystemColorScheme(.dark)

        #expect(controller.effectiveAppearance.theme == .midnight)
        #expect(applied?.theme == .midnight)
        #expect(controller.preferredColorScheme == nil)
    }

    @Test func pendingAppearanceChangesPersistOnlyTheLatestValue() {
        var persisted: [ClassicReaderAppearance] = []
        var applied: [ClassicReaderAppearance] = []
        let controller = ReaderAppearanceController(
            appearance: ClassicReaderAppearance(),
            persist: { persisted.append($0) },
            hasUsableFontFamily: { _ in true }
        )
        controller.onApply = { applied.append($0) }

        controller.appearance.fontSize = 1.1
        controller.appearance.fontSize = 1.2
        controller.flushPendingUpdate()

        #expect(persisted.count == 1)
        #expect(persisted.last?.fontSize == 1.2)
        #expect(applied.count == 1)
        #expect(applied.last?.fontSize == 1.2)
    }
}
