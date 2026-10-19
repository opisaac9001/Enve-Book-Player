import XCTest

final class SiloSSOOfficialUITests: XCTestCase {
    @MainActor
    func testSiloSSOLogin() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["ENVE_SILO_SSO_USERNAME"],
              let password = environment["ENVE_SILO_SSO_PASSWORD"],
              let serverAddress = environment["ENVE_SILO_SSO_URL"],
              let serverURL = URL(string: serverAddress),
              let host = serverURL.host,
              let libraryName = environment["ENVE_SILO_SSO_LIBRARY"] else {
            throw XCTSkip("SILO lab configuration is required")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let addSource = app.buttons["Add a source"].firstMatch
        XCTAssertTrue(addSource.waitForExistence(timeout: 10))
        addSource.tap()
        app.buttons["Set up manually"].firstMatch.tap()
        app.buttons["Silo"].firstMatch.tap()
        let address = app.textFields["silo.example.com"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(host + (serverURL.port.map { ":\($0)" } ?? ""))
        if serverURL.scheme == "http" {
            app.buttons["https://"].firstMatch.tap()
            app.buttons["http://"].firstMatch.tap()
        }
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)
        let sso = app.buttons["Single Sign-On"].firstMatch
        XCTAssertTrue(sso.waitForExistence(timeout: 10))
        sso.tap()
        app.buttons.matching(identifier: "Connect").allElementsBoundByIndex.last!.tap()

        let browser = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(browser.waitForExistence(timeout: 30))
        XCTAssertTrue(browser.staticTexts["Welcome to authentik!"].waitForExistence(timeout: 30))
        let browserWindow = browser.windows.firstMatch
        browserWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56)).tap()
        browser.typeText(username)
        XCTAssertEqual(browser.textFields["Email or Username"].value as? String, username)
        browser.buttons["Done"].firstMatch.tap()
        browser.buttons["Log in"].firstMatch.tap()
        XCTAssertTrue(browser.staticTexts["Password"].waitForExistence(timeout: 20))
        browser.secureTextFields["Password"].tap()
        browser.typeText(password)
        browser.buttons["Done"].firstMatch.tap()
        browser.buttons["Continue"].firstMatch.tap()
        let library = app.buttons["\(libraryName), Books"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        app.buttons["Done"].firstMatch.tap()
        app.terminate()
        app.launch()
        let settingsAgain = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsAgain.waitForExistence(timeout: 30))
        settingsAgain.tap()
        let connection = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Silo", host)).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 15))
        connection.tap()
        XCTAssertTrue(app.staticTexts["Signed in through your identity provider."].waitForExistence(timeout: 10))
    }
}
