import Foundation
import XCTest

final class ABSReconnectionUITests: XCTestCase {
    @MainActor
    func testMenusRemainUsableWhileAudiobookshelfRefreshTimesOut() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_ABS_UI_FIXTURE_URL"],
              let baseURL = URL(string: endpoint), baseURL.host == "127.0.0.1" else {
            throw XCTSkip("Requires Tests/Fixtures/abs-reconnect-server.py")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library", "-imagineSourceType", "audiobookshelf",
                               "-imagineSourceURL", endpoint, "-imagineSourceUser", "fixture-user",
                               "-imagineSourcePassword", "fixture-password"]
        app.launch()
        try await waitForRequest("libraries", at: baseURL)
        app.terminate()
        var expire = URLRequest(url: baseURL.appendingPathComponent("fixture/expire"))
        expire.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: expire)
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let refresh = app.buttons["Refresh sources"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 30))
        refresh.tap()
        try await waitForRequest("refresh", at: baseURL)

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let experience = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playback & experience")).firstMatch
        XCTAssertTrue(experience.waitForExistence(timeout: 10))
        for _ in 0..<8 where experience.frame.midY > app.frame.height * 0.75 {
            app.scrollViews["settings-screen"].swipeUp()
        }
        XCTAssertTrue(experience.isHittable)
        experience.tap()
        let comic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Comic reader")).firstMatch
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(experience.waitForExistence(timeout: 10))
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Audiobookshelf", "127.0.0.1")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        for _ in 0..<8 where !fixture.isHittable { app.swipeDown() }
        XCTAssertTrue(fixture.isHittable)
        fixture.tap()
        let address = app.textFields.matching(NSPredicate(format: "value == %@", endpoint)).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["This source needs you to sign in again."].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "abs-reconnection-source-settings"
        attachment.lifetime = .keepAlways
        add(attachment)

        let remove = app.buttons["Remove this source"].firstMatch
        for _ in 0..<8 where !remove.isHittable || remove.frame.midY > app.frame.height * 0.75 { app.swipeUp() }
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        let confirm = app.buttons["Remove completely"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(fixture.waitForNonExistence(timeout: 10))
    }

    private func waitForRequest(_ name: String, at endpoint: URL) async throws {
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("fixture/stats"))
            let counts = try JSONDecoder().decode([String: Int].self, from: data)
            if (counts[name] ?? 0) > 0 { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Expected \(name) request did not start")
    }
}
