import XCTest

final class ProfileCompatibilityUITests: XCTestCase {
    @MainActor
    func testProfilesSwitchAndRestoreSelectionAfterBackgroundAndRestart() throws {
        guard ProcessInfo.processInfo.environment["ENVE_PROFILE_UI"] == "1" else {
            throw XCTSkip("Requires a dedicated compatibility simulator with profiles disabled")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "profiles"]
        app.launch()
        let enable = app.buttons["profiles-enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 30))
        enable.tap()
        let name = app.textFields["profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Compatibility owner")
        app.buttons["profile-save"].tap()
        let addProfile = app.buttons["profiles-add"]
        XCTAssertTrue(addProfile.waitForExistence(timeout: 10))
        addProfile.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Compatibility reader")
        app.buttons["profile-save"].tap()

        let reader = app.buttons["Use Compatibility reader"].firstMatch
        let owner = app.buttons["Use Compatibility owner"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let readerID = reader.identifier.replacingOccurrences(of: "profile-switch-", with: "")
        let ownerID = owner.identifier.replacingOccurrences(of: "profile-switch-", with: "")
        for _ in 0..<3 {
            reader.tap()
            XCTAssertTrue(app.staticTexts["profile-current-\(readerID)"].waitForExistence(timeout: 15))
            XCTAssertTrue(owner.waitForExistence(timeout: 10))
            owner.tap()
            XCTAssertTrue(app.staticTexts["profile-current-\(ownerID)"].waitForExistence(timeout: 15))
            XCTAssertTrue(reader.waitForExistence(timeout: 10))
        }
        reader.tap()
        XCTAssertTrue(app.staticTexts["profile-current-\(readerID)"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["profile-current-\(readerID)"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["profile-current-\(readerID)"].waitForExistence(timeout: 30))
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        owner.tap()
        XCTAssertTrue(app.staticTexts["profile-current-\(ownerID)"].waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["profile-current-\(ownerID)"].waitForExistence(timeout: 10))
        app.buttons["Remove"].firstMatch.tap()
        let remove = app.buttons["profile-save"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: 10))
        app.buttons["Turn off profiles"].tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ipad-profile-switching-and-cleanup"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
