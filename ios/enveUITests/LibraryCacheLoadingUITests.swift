import XCTest

final class LibraryCacheLoadingUITests: XCTestCase {
    private struct FixtureState: Decodable {
        let libraryMode: String
        let blockedLibraryRequests: Int
    }

    @MainActor
    func testCachedBooksRemainUsableWhileSourceNamesAreBlockedOrFail() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_HEARTH_FIXTURE_URL"] else {
            throw XCTSkip("Requires the local Hearth catalog fixture")
        }
        continueAfterFailure = false
        try await setMode("initial", path: "/__fixture/mode", endpoint: endpoint)
        try await setMode("ready", path: "/__fixture/libraries", endpoint: endpoint)

        let app = XCUIApplication()
        let libraryArguments = [
            "-imagineScreen", "library", "-imagine.library.source", "all",
            "-imagine.library.source.media.all", "all", "-imagine.library.status", "all",
            "-imagine.library.media", "all", "-imagine.library.facet", "books",
            "-imagine.library.layout", "list", "-imagine.library.advancedFilters", "",
            "-imagine.library.sortDescriptors", "", "-imagine.library.sort", "recent",
            "-imagine.library.sortDirection", "descending",
        ]
        app.launchArguments = libraryArguments + [
            "-imagineSourceType", "grimmory", "-imagineSourceURL", endpoint,
            "-imagineSourceUser", "fixture", "-imagineSourcePassword", "fixture-password",
        ]
        app.launch()
        let cachedBook = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hearth Fixture Cached")).firstMatch
        XCTAssertTrue(cachedBook.waitForExistence(timeout: 40))
        app.terminate()

        try await setMode("blocked", path: "/__fixture/libraries", endpoint: endpoint)
        app.launchArguments = libraryArguments
        app.launch()
        XCTAssertTrue(app.scrollViews["library-screen"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(cachedBook.waitForExistence(timeout: 10), "Cached books must appear before the server returns library names")

        var fixture = try await state(endpoint: endpoint)
        for _ in 0..<20 where fixture.blockedLibraryRequests == 0 {
            try await Task.sleep(for: .milliseconds(100))
            fixture = try await state(endpoint: endpoint)
        }
        XCTAssertGreaterThan(fixture.blockedLibraryRequests, 0)
        XCTAssertEqual(fixture.libraryMode, "blocked")
        XCTAssertTrue(app.staticTexts["Walking the stacks…"].waitForNonExistence(timeout: 10))

        app.buttons["tab_journal"].tap()
        app.buttons["tab_library"].tap()
        XCTAssertTrue(cachedBook.waitForExistence(timeout: 5))
        XCTAssertTrue(cachedBook.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cached library while server names are blocked"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        try await setMode("failure", path: "/__fixture/libraries", endpoint: endpoint)
        XCTAssertTrue(cachedBook.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(cachedBook.waitForExistence(timeout: 10), "A server failure must not hide the persisted catalog on a fresh launch")
        XCTAssertTrue(app.staticTexts["Walking the stacks…"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(cachedBook.isHittable)
        try await setMode("ready", path: "/__fixture/libraries", endpoint: endpoint)
    }

    private func setMode(_ mode: String, path: String, endpoint: String) async throws {
        var request = URLRequest(url: URL(string: endpoint + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func state(endpoint: String) async throws -> FixtureState {
        let (data, _) = try await URLSession.shared.data(from: URL(string: endpoint + "/__fixture/state")!)
        return try JSONDecoder().decode(FixtureState.self, from: data)
    }
}
