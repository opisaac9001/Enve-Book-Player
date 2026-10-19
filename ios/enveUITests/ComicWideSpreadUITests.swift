import XCTest

final class ComicWideSpreadUITests: XCTestCase {
    @MainActor
    func testWideSourcePageStaysSingleInLandscape() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let addSource = app.buttons["Add a source"].firstMatch
        if addSource.waitForExistence(timeout: 5) {
            addSource.tap()
            let manualSetup = app.buttons["Set up manually"].firstMatch
            XCTAssertTrue(manualSetup.waitForExistence(timeout: 10))
            manualSetup.tap()
            let files = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Files")).firstMatch
            for _ in 0..<4 where !files.exists { app.swipeUp() }
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            files.tap()
            let singleFile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A single file")).firstMatch
            XCTAssertTrue(singleFile.waitForExistence(timeout: 10))
            singleFile.tap()
            let ebooksFolder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Ebooks,")).firstMatch
            XCTAssertTrue(ebooksFolder.waitForExistence(timeout: 10))
            ebooksFolder.tap()
            let fixture = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Enve-Wide-Spread-Synthetic.cbz")).firstMatch
            XCTAssertTrue(fixture.waitForExistence(timeout: 10))
            XCTAssertTrue(fixture.isEnabled)
            fixture.tap()
            XCTAssertTrue(app.staticTexts["1 book brought in."].waitForExistence(timeout: 30))
        }
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Enve-Wide-Spread-Synthetic,")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        book.tap()
        let read = app.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        let opened = XCTAttachment(screenshot: app.screenshot())
        opened.name = "Comic opened"
        opened.lifetime = .keepAlways
        add(opened)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let scrubber = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Page scrubber")).firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        let widePage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page 3 of 6")).firstMatch
        XCTAssertTrue(widePage.waitForExistence(timeout: 10))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Wide source page in landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
    }
}
