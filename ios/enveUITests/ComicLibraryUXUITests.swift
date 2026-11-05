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
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let series = firstComicSeries(in: app)
        series.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read next", "Continue reading", "Read again"])).firstMatch
        let specials = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Specials, ")).firstMatch
        for button in [read, specials] {
            XCTAssertTrue(button.waitForExistence(timeout: 20))
            for _ in 0..<8 where !isClearAboveMantel(button, in: app) { scrollToward(button, in: app) }
            XCTAssertTrue(button.isHittable)
        }
        saveScreenshot(app, name: "Comic series at accessibility text size")
    }

    @MainActor
    private func firstComicSeries(in app: XCUIApplication) -> XCUIElement {
        let series = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "library-series-comic|", "|id:synthetic-run-0"
        )).firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 15))
        for _ in 0..<10 {
            if isClearAboveMantel(series, in: app) { return series }
            scrollToward(series, in: app)
        }
        XCTAssertTrue(isClearAboveMantel(series, in: app))
        return series
    }

    @MainActor
    private func isClearAboveMantel(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let windowFrame = app.windows.firstMatch.frame
        let mantelTop = [app.buttons["mantel-pill"], app.buttons["tab_hearth"]]
            .filter { $0.exists && $0.frame.intersects(windowFrame) }
            .map { $0.frame.minY }.min() ?? windowFrame.maxY
        return element.frame.maxY < mantelTop - 12
    }

    @MainActor
    private func scrollToward(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let mantelTop = [app.buttons["mantel-pill"], app.buttons["tab_hearth"]]
            .filter { $0.exists && $0.frame.intersects(frame) }
            .map { $0.frame.minY }.min() ?? frame.maxY
        if element.exists {
            let target = element.frame
            if target.minY > frame.minY + 120, target.maxY < mantelTop - 12,
                target.maxX > frame.maxX || target.minX < frame.minX {
                let right = target.maxX > frame.maxX
                let y = target.midY - frame.minY
                window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.width * (right ? 0.8 : 0.2), dy: y))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.width * (right ? 0.2 : 0.8), dy: y)))
                return
            }
        }
        let startY = mantelTop - frame.minY - 24
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 2, dy: startY))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.width / 2, dy: max(120, startY - 240))))
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
