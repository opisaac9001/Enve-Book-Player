import XCTest

final class DismissGestureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPlayerPullDownDismissesToMiniPlayer() {
        let app = launch(["-imagineScreen", "player"])
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))

        drag(in: app, from: CGVector(dx: 0.5, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.8))

        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mantel-pill"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlayerLeadingEdgeSwipeDismisses() {
        let app = launch(["-imagineScreen", "player"])
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))

        drag(in: app, from: CGVector(dx: 0.01, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.5))

        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mantel-pill"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlayerShortDragsSpringBack() {
        let app = launch(["-imagineScreen", "player"])
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))

        drag(in: app, from: CGVector(dx: 0.5, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.36), hold: 0.6)
        XCTAssertTrue(close.isHittable, "A short pull must spring back")
        drag(in: app, from: CGVector(dx: 0.01, dy: 0.5), to: CGVector(dx: 0.12, dy: 0.5), hold: 0.6)
        XCTAssertTrue(close.isHittable, "A short edge swipe must spring back")
        drag(in: app, from: CGVector(dx: 0.3, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        XCTAssertTrue(close.isHittable, "Only the leading edge starts a horizontal dismiss")
    }

    @MainActor
    func testPullDownOnScrubberDoesNotDismissPlayer() {
        let app = launch(["-imagineScreen", "player"])
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        let ribbon = app.descendants(matching: .any)["Book position"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 5))

        let start = ribbon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 320))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)

        XCTAssertTrue(close.isHittable, "Dragging down from the scrubber must not dismiss the player")
    }

    @MainActor
    func testSwipeUpOnBottomBarOpensPlayer() {
        let app = launch(["-imagineScreen", "player"])
        let close = app.buttons["Close player"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        close.tap()
        let pill = app.descendants(matching: .any)["mantel-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))

        let pillCenter = pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        pillCenter.press(forDuration: 0.05, thenDragTo: pillCenter.withOffset(CGVector(dx: 120, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertFalse(close.waitForExistence(timeout: 2), "A horizontal drag on the pill does nothing")
        pillCenter.press(forDuration: 0.05, thenDragTo: pillCenter.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertFalse(close.waitForExistence(timeout: 2), "A downward drag on the pill does nothing")
        XCTAssertTrue(pill.exists)

        pillCenter.press(forDuration: 0.05, thenDragTo: pillCenter.withOffset(CGVector(dx: 0, dy: -160)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        let libraryTab = app.buttons["tab_library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
        let tabCenter = libraryTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tabCenter.press(forDuration: 0.05, thenDragTo: tabCenter.withOffset(CGVector(dx: 0, dy: -160)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Swiping up from the tab area opens the player")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        libraryTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 10), "Tab taps still work")
        XCTAssertFalse(close.exists)
        pill.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Tapping the pill still opens the player")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 2), "The pill's play button must not open the player")
    }

    @MainActor
    func testDetailPullDownAtTopDismissesAndScrolledPullDoesNot() {
        let app = launch(["-imagineScreen", "splitdetail"])
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 30))
        let scroll = app.scrollViews.firstMatch
        let title = app.staticTexts["Chapter Grouping Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let topY = title.frame.minY

        drag(in: app, from: CGVector(dx: 0.5, dy: 0.35), to: CGVector(dx: 0.5, dy: 0.42), hold: 0.6)
        XCTAssertTrue(back.isHittable, "A short pull at the top must not dismiss")

        scroll.swipeUp()
        scroll.swipeUp()
        let scrolledY = title.frame.minY
        XCTAssertLessThan(scrolledY, topY - 300, "The detail page should scroll")
        drag(in: app, from: CGVector(dx: 0.5, dy: 0.35), to: CGVector(dx: 0.5, dy: 0.55), hold: 0.6)
        XCTAssertTrue(back.isHittable, "A pull while scrolled down must only scroll")
        XCTAssertGreaterThan(title.frame.minY, scrolledY + 50, "The pull should scroll the page back")

        scroll.swipeDown()
        scroll.swipeDown()
        scroll.swipeDown()
        drag(in: app, from: CGVector(dx: 0.5, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.85))
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPushedDetailPullDownAtTopGoesBack() throws {
        let app = launch(["-imagineSeed", "24", "-imagineScreen", "library"])
        addTeardownBlock {
            let cleanup = XCUIApplication()
            cleanup.launchArguments = ["-imagineTeardownSynthetic", "YES", "-imagineScreen", "library"]
            cleanup.launch()
            _ = cleanup.buttons["tab_library"].waitForExistence(timeout: 30)
            sleep(4)
            cleanup.terminate()
        }
        let library = app.scrollViews["library-screen"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        let books = library.buttons.matching(NSPredicate(format:
            "label CONTAINS ', ' AND NOT label BEGINSWITH 'SOURCE,' AND NOT label BEGINSWITH 'LIBRARY,' AND NOT label BEGINSWITH 'Everything,' AND NOT label BEGINSWITH 'In progress,' AND NOT label BEGINSWITH 'Reading,' AND NOT label BEGINSWITH 'Downloaded,'"
        ))
        XCTAssertTrue(books.firstMatch.waitForExistence(timeout: 20))
        let contentFrame = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 180)
        guard let book = books.allElementsBoundByIndex.first(where: {
            contentFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.isHittable
        }) else {
            throw XCTSkip("A visible library book is required to push book details")
        }
        book.tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        drag(in: app, from: CGVector(dx: 0.005, dy: 0.55), to: CGVector(dx: 0.85, dy: 0.55))
        XCTAssertTrue(back.waitForNonExistence(timeout: 5), "The edge swipe back still works")
        book.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10))

        drag(in: app, from: CGVector(dx: 0.5, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.85))

        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertTrue(library.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        return app
    }

    @MainActor
    private func drag(in app: XCUIApplication, from: CGVector, to: CGVector, hold: TimeInterval = 0.1) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: from).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: to),
            withVelocity: .slow,
            thenHoldForDuration: hold
        )
    }
}
