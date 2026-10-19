import XCTest

final class OnboardingSmokeUITests: XCTestCase {
    @MainActor
    func testSkipDismissesOnboarding() {
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5))
    }
}
