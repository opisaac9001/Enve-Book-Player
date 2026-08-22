import XCTest

final class enveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStoryAlignPickerShowsSelectableContentOrEmptyState() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        let settingsTab =
            app.buttons["tab_settings"].exists
            ? app.buttons["tab_settings"]
            : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Settings")).firstMatch
        guard settingsTab.waitForExistence(timeout: 15) else {
            throw XCTSkip("Settings tab not reachable (first-run onboarding state)")
        }
        settingsTab.tap()

        let storyAlignQuery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "StoryAlign"))
        var attempts = 0
        while !storyAlignQuery.firstMatch.waitForExistence(timeout: 2), attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        let storyAlign = storyAlignQuery.firstMatch
        guard storyAlign.exists else {
            throw XCTSkip("StoryAlign entry not present in this configuration")
        }
        storyAlign.tap()

        if app.staticTexts["StoryAlign Unavailable"].waitForExistence(timeout: 2) {
            return
        }

        XCTAssertTrue(app.staticTexts["StoryAlign"].waitForExistence(timeout: 10))
        let ebookButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ebook")).firstMatch
        XCTAssertTrue(ebookButton.waitForExistence(timeout: 10))
        ebookButton.tap()

        XCTAssertTrue(app.staticTexts["Choose the ebook"].waitForExistence(timeout: 10))
        let pickerLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.staticTexts["Nothing of this kind in the library yet."].exists || app.staticTexts["Nothing matches that search."].exists
                    || app.buttons["Load More"].exists || app.scrollViews.buttons.count > 0
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pickerLoaded], timeout: 10), .completed)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

final class enveUISmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndLibraryNavigation() {
        let app = launch(route: "browse")

        let libraryTab = app.buttons["tab_library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        app.buttons["tab_hearth"].tap()
        libraryTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPlayerPresentation() {
        let app = launch(route: "player")

        XCTAssertTrue(app.descendants(matching: .any)["player-screen"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Close player"].exists)
    }

    @MainActor
    func testReaderPresentation() {
        let app = launch(route: "reader")

        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 20))
    }

    @MainActor
    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", route]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        return app
    }
}
