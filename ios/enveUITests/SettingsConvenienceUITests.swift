import XCTest

final class SettingsConvenienceUITests: XCTestCase {
    @MainActor
    func testShelfDragPreservesVisibilityAndOrderAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "settings"]
        app.launch()
        let screen = openHomePreferences(app)
        let shelves = [
            ("continueReading", "Continue Reading"),
            ("continueListening", "Continue Listening"),
            ("recentlyAdded", "Recently Added"),
            ("downloaded", "On this device"),
            ("doorways", "Doorways"),
        ]
        let ordered = shelves.sorted { lhs, rhs in
            screen.descendants(matching: .any)["home-shelf-\(lhs.0)"].firstMatch.frame.minY <
                screen.descendants(matching: .any)["home-shelf-\(rhs.0)"].firstMatch.frame.minY
        }
        let first = ordered[0]
        let second = ordered[1]
        let firstRow = screen.descendants(matching: .any)["home-shelf-\(first.0)"].firstMatch
        let secondRow = screen.descendants(matching: .any)["home-shelf-\(second.0)"].firstMatch
        let visibilityLabel = screen.buttons["Hide \(first.1)"].exists ? "Hide \(first.1)" : "Show \(first.1)"
        let visibility = screen.buttons[visibilityLabel]
        for _ in 0..<4 where !secondRow.isHittable { screen.swipeUp() }
        XCTAssertTrue(firstRow.isHittable)
        XCTAssertTrue(secondRow.isHittable)
        XCTAssertGreaterThanOrEqual(visibility.frame.width, 44)
        XCTAssertGreaterThanOrEqual(visibility.frame.height, 44)

        defer {
            let currentScreen = app.descendants(matching: .any)["home-preferences-screen"].firstMatch
            let up = currentScreen.buttons["Move \(first.1) up"]
            if up.exists && up.isEnabled { up.tap() }
        }
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).press(
            forDuration: 1,
            thenDragTo: secondRow.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7))
        )
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            secondRow.frame.minY < firstRow.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        XCTAssertTrue(screen.buttons[visibilityLabel].exists)

        app.terminate()
        app.launch()
        let restored = openHomePreferences(app)
        XCTAssertLessThan(
            restored.descendants(matching: .any)["home-shelf-\(second.0)"].firstMatch.frame.minY,
            restored.descendants(matching: .any)["home-shelf-\(first.0)"].firstMatch.frame.minY
        )
        XCTAssertTrue(restored.buttons[visibilityLabel].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "home-shelves-reordered"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNarratorModelsOpenFromSettingsSearch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "hearth"]
        app.launch()
        let settings = app.buttons["gearshape"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let search = app.buttons["Search settings"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let query = app.textFields["Search settings"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("kokoro")
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "kokoro"), object: query)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Narrator models")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.staticTexts["Narrator models"].firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "narrator-models-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "kokoro")
    }

    @MainActor
    private func openHomePreferences(_ app: XCUIApplication) -> XCUIElement {
        let experience = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playback & experience")).firstMatch
        XCTAssertTrue(experience.waitForExistence(timeout: 15))
        let settings = app.scrollViews["settings-screen"].firstMatch
        for _ in 0..<4 where !experience.isHittable { settings.swipeUp() }
        experience.tap()
        let home = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home & startup")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        let screen = app.descendants(matching: .any)["home-preferences-screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        return screen
    }
}
