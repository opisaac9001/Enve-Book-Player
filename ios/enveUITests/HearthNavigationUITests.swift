import XCTest

final class HearthNavigationUITests: XCTestCase {
    @MainActor
    func testBookDetailSupportsCancelledAndCompletedBackSwipes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let libraryTab = app.buttons["tab_library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 30))
        libraryTab.tap()
        let library = app.scrollViews["library-screen"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        let books = library.buttons.matching(NSPredicate(format:
            "label CONTAINS ', ' AND NOT label BEGINSWITH 'SOURCE,' AND NOT label BEGINSWITH 'LIBRARY,' AND NOT label BEGINSWITH 'Everything,' AND NOT label BEGINSWITH 'In progress,' AND NOT label BEGINSWITH 'Reading,' AND NOT label BEGINSWITH 'Downloaded,'"
        ))
        XCTAssertTrue(books.firstMatch.waitForExistence(timeout: 10))
        let windowFrame = app.windows.firstMatch.frame
        let contentFrame = windowFrame.insetBy(dx: 0, dy: 180)
        var visibleBook: XCUIElement?
        for _ in 0..<4 {
            visibleBook = books.allElementsBoundByIndex.first {
                contentFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.isHittable
            }
            if visibleBook != nil { break }
            library.swipeUp()
        }
        guard let book = visibleBook else {
            throw XCTSkip("A library book is required to check detail navigation")
        }
        book.tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
        let partial = window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        edge.press(forDuration: 0.1, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(back.isHittable)
        edge.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertTrue(book.isHittable)
    }

    @MainActor
    func testInteractiveBackCanCancelPopRepeatedlyAndStaySafeAtRoot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let experience = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playback & experience")).firstMatch
        XCTAssertTrue(experience.waitForExistence(timeout: 10))
        experience.tap()
        let comic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Comic reader")).firstMatch
        XCTAssertTrue(comic.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
        let partial = window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        edge.press(forDuration: 0.1, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(comic.isHittable, "A cancelled swipe must retain the current screen")
        edge.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(experience.waitForExistence(timeout: 5))
        experience.tap()
        XCTAssertTrue(comic.waitForExistence(timeout: 5))
        edge.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(experience.waitForExistence(timeout: 5))
        edge.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        edge.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(settings.isHittable, "Swiping at the navigation root must keep the library usable")
    }
}
