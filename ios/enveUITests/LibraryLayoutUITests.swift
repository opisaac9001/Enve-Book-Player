import XCTest

final class LibraryLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBooksAppearInTheUpperHalfWithSecondaryActionsInMore() {
        let app = launchLibrary()
        let more = app.buttons["library-more-menu"].firstMatch
        XCTAssertTrue(more.isHittable)
        XCTAssertTrue(app.buttons["Add books"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["Refresh sources"].firstMatch.isHittable)
        let booksTab = app.buttons["BOOKS"].firstMatch
        XCTAssertTrue(booksTab.waitForExistence(timeout: 10))
        let library = app.scrollViews["library-screen"].firstMatch
        let firstBook = library.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", ")).firstMatch
        XCTAssertTrue(firstBook.waitForExistence(timeout: 10))
        XCTAssertTrue(firstBook.isHittable)
        XCTAssertGreaterThan(firstBook.frame.minY, booksTab.frame.maxY)
        XCTAssertLessThan(firstBook.frame.minY, app.windows.firstMatch.frame.height * 0.5)
        record(app, name: "Library with more room for books")

        more.tap()

        XCTAssertTrue(app.buttons["Refresh sources"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose books"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Settings"].firstMatch.isHittable)
        let display = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@ OR label BEGINSWITH %@",
            "Show grid", "Show as list", "Cover size"
        )).firstMatch
        XCTAssertTrue(display.isHittable)
        app.buttons["Choose books"].firstMatch.tap()
        let done = app.buttons["Done choosing"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testShelvesPreserveShortcutsAndFilterState() {
        let app = launchLibrary()
        let shelves = app.buttons["library-shelves-menu"].firstMatch
        shelves.tap()
        for title in ["Everything", "In progress", "Downloaded", "Favorites", "For Later", "Collections", "Discover"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5), title)
        }
        app.buttons["In progress"].firstMatch.tap()
        let controls = app.buttons["library-controls-button"].firstMatch
        let filtered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Filters 1"), object: controls)
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 10), .completed)

        shelves.tap()
        app.buttons["Everything"].firstMatch.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Filter & Sort"), object: controls)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        shelves.tap()
        app.buttons["Favorites"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Favorites"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Back"].firstMatch.isHittable)
    }

    @MainActor
    func testControlsRemainReachableWithAccessibilityTextInPaperMode() {
        let app = launchLibrary(mode: "paper", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let library = app.scrollViews["library-screen"].firstMatch
        record(app, name: "Library header in Paper with accessibility text")
        for identifier in ["library-more-menu", "library-source-menu", "library-library-menu", "library-shelves-menu", "library-controls-button"] {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(button.exists, identifier)
            for _ in 0..<5 where !button.isHittable { library.swipeUp() }
            XCTAssertTrue(button.isHittable, identifier)
            // Accessibility frames can round by a physical pixel.
            XCTAssertGreaterThanOrEqual(button.frame.width + 0.5, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.5, 44)
        }
        record(app, name: "Library in Paper with accessibility text")
        app.buttons["library-controls-button"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-controls-sheet"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchLibrary(mode: String = "ink", extraArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineScreen", "library", "-imagineSeed", "48", "-imagineScenario", "mixed",
            "-imagine.library.source", "all", "-imagine.library.source.media.all", "all",
            "-imagine.library.status", "all", "-imagine.library.media", "all",
            "-imagine.library.advancedFilters", "", "-imagine.library.sortDescriptors", "",
            "-imagine.library.sort", "recent", "-imagine.library.sortDirection", "descending",
            "-imagine.library.facet", "books", "-imagine.library.layout", "grid", "-hearth.mode", mode,
        ] + extraArguments
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].firstMatch.waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["library-more-menu"].firstMatch.waitForExistence(timeout: 15))
        let count = app.staticTexts.matching(NSPredicate(
            format: "label MATCHES %@", "^[1-9][0-9,]*( books| book| of [0-9,]+ loaded)$"
        )).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func record(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
