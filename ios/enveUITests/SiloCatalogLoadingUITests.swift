import XCTest

final class SiloCatalogLoadingUITests: XCTestCase {
    @MainActor
    func testRecentPreviewsExpandIntoLiveBrowsingAcrossTabChangesAndRestart() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_SILO_CATALOG_FIXTURE_URL"] else {
            throw XCTSkip("Requires the local Silo catalog fixture")
        }
        continueAfterFailure = false
        try await setMode("ready", endpoint: endpoint)
        let app = XCUIApplication()
        let arguments = [
            "-imagineScreen", "library", "-imagine.library.source", "all",
            "-imagine.library.source.media.all", "all", "-imagine.library.status", "all",
            "-imagine.library.facet", "books", "-imagine.library.layout", "list",
            "-imagine.library.advancedFilters", "", "-imagine.library.sortDescriptors", "",
        ]
        app.launchArguments = arguments + [
            "-imagineSourceType", "silo", "-imagineSourceURL", endpoint,
            "-imagineSourceUser", "fixture", "-imagineSourcePassword", "fixture-password",
        ]
        app.launch()
        let first = app.buttons["Silo Fixture 3 Book 000"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["100 loaded"].waitForExistence(timeout: 15))

        for _ in 0..<3 {
            app.buttons["tab_journal"].tap()
            XCTAssertTrue(first.waitForNonExistence(timeout: 10))
            app.buttons["tab_library"].tap()
            XCTAssertTrue(first.waitForExistence(timeout: 10))
            XCTAssertTrue(first.isHittable)
        }

        let last = app.buttons["Silo Fixture 4 Book 119"].firstMatch
        for _ in 0..<45 {
            if last.exists && last.isHittable { break }
            app.scrollViews["library-screen"].firstMatch.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Silo final catalog page beyond the 24 cached previews"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["100 loaded"].waitForExistence(timeout: 15))
        app.buttons["tab_journal"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        app.buttons["tab_library"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)

        try await setMode("failure", endpoint: endpoint)
        app.buttons["library-more-menu"].tap()
        app.buttons["Refresh sources"].tap()
        XCTAssertTrue(app.staticTexts["Library refresh failed"].waitForExistence(timeout: 15))

        try await setMode("ready", endpoint: endpoint)
        app.buttons["Retry"].firstMatch.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Library refresh failed"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["100 loaded"].waitForExistence(timeout: 15))

        try await setMode("slow", endpoint: endpoint)
        app.buttons["library-more-menu"].tap()
        app.buttons["Refresh sources"].tap()
        app.buttons["tab_journal"].tap()
        app.buttons["tab_library"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["100 loaded"].waitForExistence(timeout: 20))
        try await setMode("ready", endpoint: endpoint)
    }

    private func setMode(_ mode: String, endpoint: String) async throws {
        var request = URLRequest(url: URL(string: endpoint + "/__fixture/mode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
