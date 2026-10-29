import XCTest

final class HearthCatalogRefreshUITests: XCTestCase {
    private struct FixtureState: Decodable {
        struct Request: Decodable {
            let path: String
            let query: [String: [String]]
        }
        let requests: [Request]
    }

    private func setMode(_ mode: String, baseURL: String) async throws {
        var request = URLRequest(url: URL(string: baseURL + "/__fixture/mode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func state(baseURL: String) async throws -> FixtureState {
        let (data, _) = try await URLSession.shared.data(from: URL(string: baseURL + "/__fixture/state")!)
        return try JSONDecoder().decode(FixtureState.self, from: data)
    }

    @MainActor
    func testHearthDiscoversAdditionsAndPreservesThemAfterRefreshFailure() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_HEARTH_FIXTURE_URL"] else {
            throw XCTSkip("Requires the local Hearth catalog fixture")
        }
        continueAfterFailure = false
        try await setMode("initial", baseURL: endpoint)
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "hearth", "-imagineSourceType", "grimmory",
            "-imagineSourceURL", endpoint, "-imagineSourceUser", "fixture",
            "-imagineSourcePassword", "fixture-password"]
        app.launch()
        XCTAssertTrue(app.buttons["tab_hearth"].waitForExistence(timeout: 30))
        app.buttons["tab_hearth"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["hearth-screen"].waitForExistence(timeout: 20))
        try await Task.sleep(for: .seconds(6))

        try await setMode("added", baseURL: endpoint)
        app.buttons["tab_journal"].tap()
        app.buttons["tab_hearth"].tap()
        try await Task.sleep(for: .seconds(1))
        let beforePull = try await state(baseURL: endpoint)
        XCTAssertFalse(beforePull.requests.contains { $0.path == "/api/v1/app/books" && $0.query["size"] == ["50"] })
        let scroll = app.scrollViews.firstMatch
        let pullStart = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2))
        let pullEnd = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd, withVelocity: .slow, thenHoldForDuration: 0.2)
        var requests: [FixtureState.Request] = []
        for _ in 0..<40 {
            requests = try await state(baseURL: endpoint).requests
            if requests.contains(where: { $0.query["size"] == ["50"] && $0.query["page"] == ["2"] }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let catalogPages = requests.filter { $0.path == "/api/v1/app/books" && $0.query["size"] == ["50"] }
        XCTAssertEqual(catalogPages.compactMap { $0.query["page"]?.first }, ["0", "1", "2"])
        XCTAssertFalse(requests.contains { $0.path == "/api/v1/libraries/1/book" || $0.query["size"] == ["500"] })
        let added = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hearth Fixture Added")).firstMatch
        for _ in 0..<3 where !added.isHittable { scroll.swipeUp() }
        XCTAssertTrue(added.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "hearth-discovers-additions"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        for _ in 0..<4 { scroll.swipeDown() }
        try await setMode("failure", baseURL: endpoint)
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.staticTexts["hearth-catalog-refresh-failure"].waitForExistence(timeout: 20))
        for _ in 0..<3 where !added.isHittable { scroll.swipeUp() }
        XCTAssertTrue(added.exists)
    }
}
