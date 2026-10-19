import XCTest

final class ComicLibraryUXUITests: XCTestCase {
    @MainActor
    func testLargeComicLibraryRetainsSeriesContextAfterReadingASpecial() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library", "-imagineSeed", "17400", "-imagineScenario", "comics"]
        app.launch()
        let series = firstComicSeries(in: app)
        series.tap()
        let specials = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Specials, ")).firstMatch
        XCTAssertTrue(specials.waitForExistence(timeout: 20))
        specials.tap()
        let special = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Comic Fixture 0 · Special 700")).firstMatch
        XCTAssertTrue(special.waitForExistence(timeout: 20))
        saveScreenshot(app, name: "Comic series with direct Specials access")
        special.tap()
        let page = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page 1 of 3")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        let close = app.buttons["Close"].firstMatch
        if !close.isHittable { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(specials.waitForExistence(timeout: 15))
        XCTAssertTrue(special.isHittable)
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(series.waitForExistence(timeout: 15))
        XCTAssertTrue(series.isHittable)
        saveScreenshot(app, name: "Large comic library after returning from reader")
    }

    @MainActor
    func testComicSeriesSupportsAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineScreen", "library", "-imagineSeed", "701", "-imagineScenario", "comics",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let series = firstComicSeries(in: app)
        series.tap()
        let read = app.buttons["Read next"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        let specials = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Specials, ")).firstMatch
        XCTAssertTrue(specials.waitForExistence(timeout: 20))
        saveScreenshot(app, name: "Comic series at accessibility text size")
    }

    @MainActor
    private func firstComicSeries(in app: XCUIApplication) -> XCUIElement {
        let series = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "library-series-comic|", "|id:synthetic-run-0"
        )).firstMatch
        if series.waitForExistence(timeout: 15) { return series }
        for _ in 0..<10 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
            if series.exists { return series }
        }
        XCTAssertTrue(series.exists)
        return series
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
