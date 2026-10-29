import XCTest

final class LibraryFilterControlsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRemovingTheLastSortRuleAndAddingANewPrimarySort() {
        let app = launchLibrary(showFilters: true)
        let removeRecent = app.buttons["Remove Recently Added"].firstMatch
        XCTAssertTrue(removeRecent.waitForExistence(timeout: 15))
        XCTAssertTrue(removeRecent.isEnabled)

        removeRecent.tap()

        XCTAssertTrue(removeRecent.waitForNonExistence(timeout: 5))
        let defaultOrder = app.staticTexts["Default order: recently added, newest first."].firstMatch
        XCTAssertTrue(defaultOrder.waitForExistence(timeout: 5))
        app.buttons["Title"].firstMatch.tap()
        let removeTitle = app.buttons["Remove Title"].firstMatch
        XCTAssertTrue(removeTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(removeTitle.isEnabled)
        removeTitle.tap()
        XCTAssertTrue(removeTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(defaultOrder.exists)
        app.buttons["Done"].firstMatch.tap()
        let controls = app.buttons["library-controls-button"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        XCTAssertTrue(defaultOrder.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Last sort removed with default ordering"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testChoosingASourceDoesNotActivateTheFilterBadge() {
        let app = launchLibrary(showFilters: false)
        let source = app.buttons["library-source-menu"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        source.tap()
        let device = app.buttons["This device"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5))

        device.tap()

        let controls = app.buttons["library-controls-button"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertEqual(controls.label, "Filter & Sort")
        XCTAssertEqual(source.value as? String, "This device")
    }

    @MainActor
    private func launchLibrary(showFilters: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineScreen", showFilters ? "libraryfilters" : "library",
            "-imagine.library.source", "all",
            "-imagine.library.source.media.all", "all",
            "-imagine.library.source.media.device", "all",
            "-imagine.library.status", "all",
            "-imagine.library.media", "all",
            "-imagine.library.advancedFilters", "",
            "-imagine.library.sortDescriptors", "",
            "-imagine.library.sort", "recent",
            "-imagine.library.sortDirection", "descending",
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].firstMatch.waitForExistence(timeout: 30))
        return app
    }
}
