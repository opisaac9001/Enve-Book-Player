import XCTest

final class BooklorePlaybackUITests: XCTestCase {
    @MainActor
    func testDownloadedAudiobookReplaysAfterEnd() throws {
        guard ProcessInfo.processInfo.environment["ENVE_LAB_PLAYBACK_UI"] == "1" else {
            throw XCTSkip("Requires the downloaded 60-second Grimmory lab audiobook")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Enve Synthetic EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        let listen = app.buttons["Listen"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10))
        let pause = app.buttons["Pause"].firstMatch
        if pause.exists { pause.tap() }
        let forward = app.buttons["Skip forward 15 seconds"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        let end = app.staticTexts["1:00"].firstMatch
        for _ in 0..<5 where !end.exists { forward.tap() }
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        if pause.exists { pause.tap() }
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(end.waitForNonExistence(timeout: 5), "Replay must leave the completed position")
        let opening = app.staticTexts["CHAPTER 1 · OPENING"].firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 5))
        let advancing = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "0:0[2-9]")).firstMatch
        XCTAssertTrue(advancing.waitForExistence(timeout: 10), "Replayed audio must advance")
        pause.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "grimmory-downloaded-replay"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
