import XCTest

final class BookloreSearchUITests: XCTestCase {
    @MainActor
    func testSourceWideSearchFindsRemoteBookAndOpensDetail() throws {
        guard ProcessInfo.processInfo.environment["ENVE_LAB_PLAYBACK_UI"] == "1" else {
            throw XCTSkip("Requires the connected Grimmory lab source")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let source = app.buttons["library-source-menu"]
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        source.tap()
        let grimmory = app.buttons["Grimmory"].firstMatch
        XCTAssertTrue(grimmory.waitForExistence(timeout: 10))
        grimmory.tap()
        let search = app.buttons["Search the library"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Enve Namespace Prefix Regression\n")
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Enve Namespace Prefix Regression")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "grimmory-source-wide-search"
        attachment.lifetime = .keepAlways
        add(attachment)
        result.tap()
        XCTAssertTrue(app.staticTexts["Enve Namespace Prefix Regression"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Resume"].firstMatch.waitForExistence(timeout: 15))
    }
}
