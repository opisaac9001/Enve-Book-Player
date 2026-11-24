import XCTest

@MainActor
final class BookOrbitFeaturesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testWideLibraryAndScopeDetailsPreserveBrowsing() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_FEATURE_UI"] == "1")
        let app = XCUIApplication()
        app.launch()
        let library = app.buttons["tab_library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let shelves = app.buttons["library-shelves-menu"]
        XCTAssertTrue(shelves.waitForExistence(timeout: 30))
        let apple = visibleBook(in: app, title: "Enve Feature Lab Apple")
        XCTAssertNotNil(apple)
        apple?.tap()
        let pane = app.buttons["book-detail-close"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        XCTAssertTrue(shelves.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "BookOrbit wide library and details"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["book-detail-close"].tap()
        shelves.tap()
        app.buttons["BookOrbit Feature Lab"].tap()
        let scope = app.buttons["bookorbit-scope-1"]
        XCTAssertTrue(scope.waitForExistence(timeout: 15))
        scope.tap()
        let search = app.textFields["bookorbit-scope-search"]
        search.tap()
        search.typeText("Apple")
        let summary = app.staticTexts["bookorbit-scope-summary"]
        let filtered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 book"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 15), .completed)
        visibleBook(in: app, title: "Enve Feature Lab Apple")?.tap()
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Apple")
        XCTAssertTrue(scope.isHittable)
        app.buttons["book-detail-close"].tap()
        XCTAssertEqual(search.value as? String, "Apple")
        XCTAssertNotNil(visibleBook(in: app, title: "Enve Feature Lab Apple"))
    }

    func testHighlightsFilterAndConfirmedDiscard() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_COMPACT_UI"] == "1")
        let discardID = try XCTUnwrap(ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_DISCARD_ID"])
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["tab_journal"].waitForExistence(timeout: 30))
        app.buttons["tab_journal"].tap()
        let hub = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stats Hub")).firstMatch
        reveal(hub, in: app)
        hub.tap()
        XCTAssertTrue(app.buttons["All services"].waitForExistence(timeout: 20))
        app.buttons["All services"].tap()
        app.buttons["BookOrbit"].tap()
        let highlights = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Highlights")).firstMatch
        reveal(highlights, in: app)
        highlights.tap()
        let notes = app.buttons["bookorbit-highlights-notes-only"]
        XCTAssertTrue(notes.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["3 highlights · 1 book · 2 with notes"].waitForExistence(timeout: 15))
        notes.tap()
        XCTAssertTrue(app.staticTexts["2 highlights · 1 book · 2 with notes"].waitForExistence(timeout: 15))
        XCTAssertTrue(notes.isSelected)
        notes.tap()
        XCTAssertTrue(app.staticTexts["3 highlights · 1 book · 2 with notes"].waitForExistence(timeout: 15))
        app.buttons["tab_library"].tap()
        app.buttons["Add books"].tap()
        app.buttons["Send to BookOrbit Feature Lab"].tap()
        let file = app.buttons["bookorbit-drop-file-\(discardID)"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        file.tap()
        let discard = app.buttons["bookorbit-drop-discard"]
        reveal(discard, in: app)
        discard.tap()
        app.buttons["Discard"].tap()
        XCTAssertTrue(file.waitForNonExistence(timeout: 15))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 {
            if element.isHittable && element.frame.midY < app.frame.height * 0.75 { return }
            app.swipeUp()
        }
    }

    private func visibleBook(in app: XCUIApplication, title: String) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .allElementsBoundByIndex.first { $0.isHittable }
    }
}
