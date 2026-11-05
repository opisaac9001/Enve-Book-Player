import XCTest

final class ComicWideSpreadUITests: XCTestCase {
    @MainActor
    func testWideSourcePageStaysSingleInLandscape() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "comic-wide-spread", withExtension: "cbz"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = ["-imagineScreen", "comicfixture", "-imagineFixture", "comic-wide-\(UUID().uuidString).cbz"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].firstMatch.waitForExistence(timeout: 30))
        let opened = XCTAttachment(screenshot: app.screenshot())
        opened.name = "Comic opened"
        opened.lifetime = .keepAlways
        add(opened)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let scrubber = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Page scrubber")).firstMatch
        if !scrubber.exists { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
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
