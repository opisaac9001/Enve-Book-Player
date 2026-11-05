import XCTest

final class OnboardingSmokeUITests: XCTestCase {
    @MainActor
    func testSkipDismissesOnboarding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagine.hasSeenTour", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 30))
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab_library"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["tab_library"].waitForExistence(timeout: 30))
        XCTAssertFalse(skip.waitForExistence(timeout: 5), "Skipping the tour must remain saved after relaunch")
    }
}
