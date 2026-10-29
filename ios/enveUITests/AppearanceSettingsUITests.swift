import CoreImage
import XCTest

final class AppearanceSettingsUITests: XCTestCase {
    @MainActor
    func testThemeChangesImmediatelyAndSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "hearth"]
        app.launch()
        openAppearance(app)
        let originalMode = ["System", "Ink", "Paper"].first {
            app.buttons[$0].firstMatch.value as? String == "Selected"
        } ?? "System"
        let oled = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "True black")).firstMatch
        let originalOLED = oled.value as? String
        defer {
            if oled.value as? String != originalOLED { oled.tap() }
            app.buttons[originalMode].firstMatch.tap()
        }
        if oled.value as? String == "1" { oled.tap() }

        app.buttons["Paper"].firstMatch.tap()
        XCTAssertGreaterThan(try backgroundBrightness(app), 0.7)
        app.buttons["Ink"].firstMatch.tap()
        XCTAssertEqual(app.buttons["Ink"].firstMatch.value as? String, "Selected")
        XCTAssertLessThan(try backgroundBrightness(app), 0.3)
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "appearance-ink-live"
        dark.lifetime = .keepAlways
        add(dark)
        if oled.value as? String != "1" { oled.tap() }
        XCTAssertLessThan(try backgroundBrightness(app), 0.01)

        app.terminate()
        app.launch()
        openAppearance(app)
        XCTAssertEqual(app.buttons["Ink"].firstMatch.value as? String, "Selected")
        XCTAssertLessThan(try backgroundBrightness(app), 0.3)
        XCTAssertEqual(oled.value as? String, "1")
        app.buttons["Paper"].firstMatch.tap()
        XCTAssertGreaterThan(try backgroundBrightness(app), 0.7)
    }

    @MainActor
    private func openAppearance(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let experience = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playback & experience")).firstMatch
        XCTAssertTrue(experience.waitForExistence(timeout: 30))
        experience.tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Appearance")).firstMatch
        app.swipeUp()
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "appearance-settings-navigation"
        screen.lifetime = .keepAlways
        add(screen)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.buttons["Ink"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func backgroundBrightness(_ app: XCUIApplication) throws -> Double {
        let image = try XCTUnwrap(CIImage(data: app.screenshot().pngRepresentation))
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            image,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 4, y: image.extent.height / 2, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (255 * 3)
    }
}
