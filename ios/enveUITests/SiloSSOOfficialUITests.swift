import XCTest

final class SiloSSOOfficialUITests: XCTestCase {
    @MainActor
    func testPasswordLoginWithPINProfile() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["ENVE_SILO_USERNAME"],
              let password = environment["ENVE_SILO_PASSWORD"],
              let address = environment["ENVE_SILO_ADDRESS"],
              let pin = environment["ENVE_SILO_PIN"] else { throw XCTSkip("Requires isolated Silo PIN fixtures") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Add a source"].firstMatch.tap()
        app.buttons["Browse all sources"].firstMatch.tap()
        app.buttons["Silo"].firstMatch.tap()
        let server = app.textFields["silo.example.com"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        for character in address { server.typeText(String(character)) }
        app.textFields["Silo (optional)"].firstMatch.tap()
        app.buttons["https://"].firstMatch.tap()
        app.buttons["http://"].firstMatch.tap()
        app.buttons["Username & Password"].firstMatch.tap()
        let user = app.textFields.allElementsBoundByIndex.last!
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        user.tap()
        user.typeText(username)
        XCTAssertTrue(user.value as? String == username)
        let secret = app.secureTextFields.allElementsBoundByIndex.last!
        secret.tap()
        secret.typeText(password)
        let connect = app.buttons.matching(identifier: "Connect").allElementsBoundByIndex.last!
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        let profile = app.alerts.buttons["Native PIN Verification"]
        if !profile.waitForExistence(timeout: 20) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Silo profile selection did not appear")
        }
        profile.tap()
        let pinField = app.secureTextFields["Silo profile PIN"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 10))
        pinField.tap()
        pinField.typeText(pin)
        app.alerts.buttons["Unlock"].tap()
        let library = app.buttons["Enve v2 Verification ebooks, Books"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        app.buttons["Done"].firstMatch.tap()
        app.terminate()
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let connection = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Silo", address.components(separatedBy: ":")[0])).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 20))
        connection.tap()
        app.buttons["Verify"].tap()
        XCTAssertTrue(app.staticTexts["Connection looks good."].waitForExistence(timeout: 30))
    }

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
        let browse = app.buttons["Browse all sources"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.tap()
        app.buttons["Silo"].firstMatch.tap()
        let address = app.textFields["silo.example.com"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        let authority = host + (serverURL.port.map { ":\($0)" } ?? "")
        for character in authority {
            address.typeText(String(character))
        }
        XCTAssertEqual(address.value as? String, authority)
        let sourceName = app.textFields["Silo (optional)"].firstMatch
        sourceName.tap()
        for character in "Silo SSO Verification" { sourceName.typeText(String(character)) }
        XCTAssertTrue(sourceName.value as? String == "Silo SSO Verification")
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
        let usernameField = browser.textFields["Email or Username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 10))
        usernameField.tap()
        usernameField.typeText(username)
        XCTAssertEqual(browser.textFields["Email or Username"].value as? String, username)
        browser.buttons["Done"].firstMatch.tap()
        browser.buttons["Log in"].firstMatch.tap()
        XCTAssertTrue(browser.staticTexts["Password"].waitForExistence(timeout: 20))
        browser.secureTextFields["Password"].tap()
        for character in password { browser.typeText(String(character)) }
        browser.buttons["Done"].firstMatch.tap()
        browser.buttons["Continue"].firstMatch.tap()
        let library = app.buttons["\(libraryName), Books"]
        if !library.waitForExistence(timeout: 30) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Silo libraries did not appear after browser sign-in")
        }
        library.tap()
        app.buttons["Done"].firstMatch.tap()
        app.terminate()
        app.launch()
        let settingsAgain = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsAgain.waitForExistence(timeout: 30))
        settingsAgain.tap()
        let connection = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Silo SSO Verification")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 15))
        connection.tap()
        XCTAssertTrue(app.staticTexts["Signed in through your identity provider."].waitForExistence(timeout: 10))
    }
}
