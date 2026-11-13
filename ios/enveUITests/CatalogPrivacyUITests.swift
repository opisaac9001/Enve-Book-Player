import XCTest

final class CatalogPrivacyUITests: XCTestCase {
    @MainActor
    func testAudibleSwitchPersistsAndDiscoverExplainsWhyItIsOff() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "settings"]
        app.launch()
        openPrivacy(app)
        let toggle = app.descendants(matching: .any).matching(identifier: "external-service-audible").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        let original = toggle.value as? String
        if original == "On" { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "Off")

        defer {
            app.terminate()
            app.launchArguments = ["-imagineScreen", "settings"]
            app.launch()
            openPrivacy(app)
            let restored = app.descendants(matching: .any).matching(identifier: "external-service-audible").firstMatch
            if restored.waitForExistence(timeout: 5), restored.value as? String != original { restored.tap() }
        }

        app.terminate()
        app.launchArguments = ["-imagineScreen", "discover"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Discover is turned off."].waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "discover-catalog-turned-off"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openPrivacy(_ app: XCUIApplication) {
        let library = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Library & content")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        let settings = app.scrollViews["settings-screen"].firstMatch
        for _ in 0..<4 where !library.isHittable { settings.swipeUp() }
        library.tap()
        let privacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "External services")).firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        privacy.tap()
        XCTAssertTrue(app.descendants(matching: .any)["external-services-screen"].firstMatch.waitForExistence(timeout: 5))
    }
}
