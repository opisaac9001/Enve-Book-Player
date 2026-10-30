import XCTest

final class ListeningPositionUITests: XCTestCase {
    @MainActor
    func testReadingFormatsOfferLocationSharingFromBookDetails() {
        continueAfterFailure = false
        for format in ["epub", "mobi", "azw3", "pdf", "cbz"] {
            let app = XCUIApplication()
            app.launchArguments = ["-imagineScreen", "positiondetail", "-imaginePositionFormat", format]
            app.launch()
            let skip = app.buttons["Skip"]
            if skip.waitForExistence(timeout: 2) { skip.tap() }
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 30), format)
            more.tap()
            let share = app.buttons["Share book location"].firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 5), format)
            share.tap()
            XCTAssertTrue(app.buttons["Share image"].waitForExistence(timeout: 5), format)
            let position = format == "pdf" || format == "cbz" ? "Page 8 of 32" : "25.0%"
            XCTAssertTrue(app.images.matching(NSPredicate(format: "label CONTAINS %@", position)).firstMatch.exists, format)
            XCTAssertTrue(app.buttons["Update position"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testShareCodeAndOpenImageScanner() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "splitdetail"]
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let share = app.buttons["Share book location"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(app.buttons["Share image"].waitForExistence(timeout: 5))
        let code = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Book-position code")).firstMatch
        XCTAssertTrue(code.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Listening position QR"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let libraryMore = app.buttons["library-more-menu"]
        XCTAssertTrue(libraryMore.waitForExistence(timeout: 30))
        libraryMore.tap()
        app.buttons["Scan book position"].tap()
        let choose = app.buttons["Choose an image"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
    }
}
