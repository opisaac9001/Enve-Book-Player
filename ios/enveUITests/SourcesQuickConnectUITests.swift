import XCTest

final class SourcesQuickConnectUITests: XCTestCase {
    @MainActor
    func testServerAddressAcceptsInputWhenKeyboardAppears() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "addsource"]
        app.launch()

        let address = app.textFields["books.example.com"]
        XCTAssertTrue(address.waitForExistence(timeout: 30))
        address.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        for character in "books.example.com" {
            address.typeText(String(character))
            usleep(50_000)
        }
        XCTAssertEqual(address.value as? String, "books.example.com")
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "quick-connect-address-keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
