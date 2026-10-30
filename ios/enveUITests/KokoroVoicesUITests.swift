import XCTest

final class KokoroVoicesUITests: XCTestCase {
    @MainActor
    func testMaleAndFemaleVoicesPersistAfterRestart() throws {
        guard ProcessInfo.processInfo.environment["ENVE_KOKORO_VOICES_UI"] == "1" else {
            throw XCTSkip("Requires downloaded Kokoro models and a local ebook.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "kokorodownload"]
        app.launch()

        let list = app.collectionViews.firstMatch
        let heart = voice("af_heart", in: app)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 60))
        let deadline = Date().addingTimeInterval(120)
        while !heart.exists, Date() < deadline { list.swipeUp() }
        XCTAssertTrue(heart.exists)
        for (name, identifier) in [
            ("Heart", "af_heart"), ("Bella", "af_bella"),
            ("Michael", "am_michael"), ("Puck", "am_puck"),
        ] {
            let row = voice(identifier, in: app)
            for _ in 0..<6 where !row.isHittable { list.swipeUp() }
            XCTAssertTrue(row.isHittable, "Missing Kokoro voice: \(name)")
            row.tap()
            app.buttons["Back"].tap()
            XCTAssertEqual(app.buttons["Choose a voice"].value as? String, "Kokoro · \(name)")
            app.buttons["Choose a voice"].tap()
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "kokoro-four-voices"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 30))
        app.buttons["Back"].tap()
        XCTAssertEqual(app.buttons["Choose a voice"].value as? String, "Kokoro · Puck")
    }

    @MainActor
    private func voice(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["kokoro-voice-\(identifier)"]
    }
}
