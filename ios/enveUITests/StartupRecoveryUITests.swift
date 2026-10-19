import XCTest

final class StartupRecoveryUITests: XCTestCase {
    @MainActor
    func testStartupAndSettingsRemainUsableWithoutStorageWarning() throws {
        guard ProcessInfo.processInfo.environment["ENVE_IOS17_COMPATIBILITY"] == "1" else {
            throw XCTSkip("Requires the iOS 17.0 compatibility simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts["Playback storage unavailable"].exists)
        settings.tap()
        let experience = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playback & experience")).firstMatch
        XCTAssertTrue(experience.waitForExistence(timeout: 10))
        experience.tap()
        let comic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Comic reader")).firstMatch
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(experience.waitForExistence(timeout: 10))
        experience.tap()
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ios17-startup-settings-without-storage-warning"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
