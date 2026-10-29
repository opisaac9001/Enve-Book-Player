import XCTest

final class ReaderTTSControlsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCenterTapRestoresReaderControlsDuringSpeech() throws {
        let app = try launchSpeakingReader()
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let contents = app.buttons["Contents"].firstMatch
        if contents.exists {
            center.tap()
            XCTAssertTrue(contents.waitForNonExistence(timeout: 5))
        }

        center.tap()

        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Appearance"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Search"].firstMatch.isHittable)
        let pause = app.buttons["Pause reading aloud"].firstMatch
        XCTAssertTrue(pause.isHittable)
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: contents)
        disappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)

        app.buttons["Appearance"].firstMatch.tap()
        let appearance = app.scrollViews.containing(.button, identifier: "Paged").firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        dismissSheet(appearance, in: app)
        XCTAssertTrue(appearance.waitForNonExistence(timeout: 5))
        if !contents.isHittable { center.tap() }
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        XCTAssertTrue(pause.exists)

        contents.tap()
        let chapters = app.otherElements["reader-contents-tray"].firstMatch
        XCTAssertTrue(chapters.waitForExistence(timeout: 5))
        dismissSheet(chapters, in: app)
        XCTAssertTrue(chapters.waitForNonExistence(timeout: 5))
        if !pause.isHittable { center.tap() }
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "tts-reader-controls-without-stopping")
    }

    @MainActor
    func testCompactControlsOpenSpeechSettingsAndExpandReader() throws {
        let app = try launchSpeakingReader()
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let contents = app.buttons["Contents"].firstMatch
        if contents.exists { center.tap() }
        let controls = app.descendants(matching: .any)["reader-tts-controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertTrue(controls.buttons["Previous paragraph"].isHittable)
        XCTAssertTrue(controls.buttons["Next paragraph"].isHittable)
        controls.buttons["Next paragraph"].tap()
        controls.buttons["Previous paragraph"].tap()
        let expand = app.buttons["Show reader controls"].firstMatch
        XCTAssertTrue(expand.isHittable)
        attachScreenshot(app, name: "tts-compact-controls")
        expand.tap()
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause reading aloud"].firstMatch.isHittable)

        app.buttons["Voice and speed"].firstMatch.tap()
        let sheet = app.descendants(matching: .any)["reader-tts-sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Previous paragraph"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Next paragraph"].firstMatch.exists)
        let chooseVoice = app.buttons["Choose a voice"].firstMatch
        for _ in 0..<4 where !chooseVoice.isHittable { sheet.swipeUp() }
        XCTAssertTrue(chooseVoice.isHittable)
        chooseVoice.tap()
        XCTAssertTrue(app.buttons["Back"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tts-engine-apple"].exists)
        XCTAssertTrue(app.buttons["tts-engine-kokoro"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tts-engine-")).count, 2)
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "tts-full-controls-while-playing")
        dismissSheet(sheet, in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        if !app.buttons["Pause reading aloud"].firstMatch.isHittable { center.tap() }
        XCTAssertTrue(app.buttons["Pause reading aloud"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPausedSpeechSettingsKeepTheSessionResumable() throws {
        let app = try launchSpeakingReader()
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        app.buttons["Pause reading aloud"].firstMatch.tap()
        let resume = app.buttons["Resume reading aloud"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))

        app.buttons["Voice and speed"].firstMatch.tap()

        let sheet = app.descendants(matching: .any)["reader-tts-sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Read aloud"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Stop reading"].firstMatch.exists)
        dismissSheet(sheet, in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        if !resume.isHittable { center.tap() }
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.buttons["Pause reading aloud"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchSpeakingReader() throws -> XCUIApplication {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reader-interaction", withExtension: "epub"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = [
            "-imagineScreen", "footnotefixture",
            "-imagineFixture", "reader-tts-controls-\(UUID().uuidString).epub",
            "--exercise-tts-play", "-ebookTTS.engine", "apple", "-ebookTTS.rate", "1",
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 30))
        let pause = app.buttons["Pause reading aloud"].firstMatch
        if !pause.waitForExistence(timeout: 15) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func dismissSheet(_ sheet: XCUIElement, in app: XCUIApplication) {
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(
            forDuration: 0.1,
            thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96))
        )
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
