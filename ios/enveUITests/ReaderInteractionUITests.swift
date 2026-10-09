import XCTest

final class ReaderInteractionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNarrationControlsSurviveHighlightAndBackgroundReturn() throws {
        let app = try launchReader(startNarration: true)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        XCTAssertTrue(pause.waitForNonExistence(timeout: 10), "Playing controls should auto-hide")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        let highlight = app.buttons["Yellow highlight"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        XCTAssertTrue(pause.isHittable, "Selection must restore hidden narration controls")
        assertRemainsVisible(pause, for: 5)
        highlight.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let play = app.buttons["Play Read Aloud"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        assertRemainsVisible(play, for: 5)

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1)
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(play.isHittable, "Dismissing a selection must preserve playback controls")
        attachScreenshot(app, name: "narration-after-highlight-and-background")
    }

    @MainActor
    func testNarrationControlsHideAndRestoreWhilePlayingPausedAndSelecting() throws {
        let app = try launchReader(startNarration: true)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        let play = app.buttons["Play Read Aloud"].firstMatch
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        XCTAssertTrue(pause.waitForNonExistence(timeout: 10))
        showNarrationControls(app)
        center.tap()
        XCTAssertTrue(pause.waitForNonExistence(timeout: 5), "Playing controls must support tap dismissal")
        showNarrationControls(app)
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        assertRemainsVisible(play, for: 5)
        center.tap()
        XCTAssertTrue(play.waitForNonExistence(timeout: 5), "Paused controls must support tap dismissal")
        showNarrationControls(app)
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(pause.waitForNonExistence(timeout: 10))

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        let highlight = app.buttons["Yellow highlight"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        assertRemainsVisible(pause, for: 5)
        center.tap()
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5))
        XCTAssertTrue(pause.exists, "Selection dismissal must briefly restore controls")
        XCTAssertTrue(pause.waitForNonExistence(timeout: 10), "Auto-hide must resume after selection dismissal")
        showNarrationControls(app)
        attachScreenshot(app, name: "narration-restored-after-normal-hide-cycle")
    }

    @MainActor
    func testMultilineSelectionSurvivesSamePageNarrationSegments() throws {
        let app = try launchReader(startNarration: true)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        let highlight = app.buttons["Yellow highlight"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        let endHandle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.464, dy: 0.18))
        let endOfPassage = window.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.29))
        endHandle.press(forDuration: 0.5, thenDragTo: endOfPassage)
        attachScreenshot(app, name: "multiline-selection-before-same-page-segments")
        assertRemainsVisible(highlight, for: 45)
        XCTAssertTrue(pause.isHittable)
        attachScreenshot(app, name: "multiline-selection-after-same-page-segments")
        app.buttons["Note"].firstMatch.tap()
        let excerpt = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Edge selection remains on this page")
        ).firstMatch
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5), "The native handle drag must retain a multiline passage, not just the initially selected word")
        attachScreenshot(app, name: "multiline-passage-in-note-draft")
    }

    @MainActor
    func testActiveSelectionSurvivesNaturalNarrationPageFollow() throws {
        let app = try launchReader(startNarration: true, fixtureName: "reader-selection-follow")
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        let highlight = app.buttons["Yellow highlight"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "selection-before-natural-narration-transitions")
        // Each ten-second clip is in a different EPUB chapter. Natural playback
        // must keep the current page while the selection is unfinished.
        assertRemainsVisible(highlight, for: 15)
        XCTAssertTrue(pause.isHittable)
        attachScreenshot(app, name: "selection-after-natural-narration-transitions")
        highlight.tap()
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(app.buttons["Play Read Aloud"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEPUBSelectionStartsAtBothEdgesAndPageTapsStillWork() throws {
        let app = try launchReader(startNarration: false)
        let window = app.windows.firstMatch
        let progress = app.descendants(matching: .any)["reader-progress-slider"].firstMatch
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        // The first tap cancels the initial auto-hide timer. Then explicitly show
        // chrome regardless of whether that tap began with it visible or hidden.
        center.tap()
        if !progress.waitForExistence(timeout: 2) { center.tap() }
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let initialPosition = progress.value as? String
        XCTAssertNotNil(initialPosition)
        center.tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForNonExistence(timeout: 5))

        let highlight = app.buttons["Yellow highlight"].firstMatch
        for x in [0.055, 0.92] {
            // Both edge coordinates lie on the fixture's first text line.
            attachScreenshot(app, name: "before-edge-selection-\(x)")
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.09))
            start.press(forDuration: 1)
            XCTAssertTrue(highlight.waitForExistence(timeout: 5), "Selection failed at the \(x) page edge")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            XCTAssertTrue(highlight.waitForNonExistence(timeout: 5))
            if !progress.exists {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            }
            XCTAssertTrue(progress.waitForExistence(timeout: 5))
            XCTAssertEqual(progress.value as? String, initialPosition, "Edge selection unexpectedly turned the page")
            if x == 0.055 {
                center.tap()
                XCTAssertTrue(app.buttons["Close"].firstMatch.waitForNonExistence(timeout: 5))
            }
        }

        // Keep the position visible and let navigation finish before the next input.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.45)).tap()
        let pageChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value != %@", try XCTUnwrap(initialPosition)),
            object: progress
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 10), .completed,
                       "Intentional edge taps must still turn pages")
        attachScreenshot(app, name: "reader-after-edge-selection-and-page-turn")
    }

    @MainActor
    func testNarrationControlsCanBeExpandedDismissedAndRestarted() throws {
        let app = try launchReader(startNarration: true)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        for _ in 0..<3 {
            showNarrationControls(app)
            app.buttons["Show Read Aloud controls"].firstMatch.tap()
            let next = app.buttons["Next Read Aloud segment"].firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
            app.buttons["Previous Read Aloud segment"].firstMatch.tap()
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            XCTAssertTrue(pause.waitForNonExistence(timeout: 5), "Dismissing expanded controls should hide them")
            showNarrationControls(app)
            pause.tap()
            let play = app.buttons["Play Read Aloud"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            play.tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 5))
        }
        showNarrationControls(app)
        app.buttons["Show Read Aloud controls"].firstMatch.tap()
        let stop = app.buttons["Stop Read Aloud"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertFalse(pause.exists)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["reader-screen"].exists)
    }

    @MainActor
    func testBottomSelectionKeepsAnnotationAndPlaybackControlsSeparate() throws {
        let app = try launchReader(startNarration: true)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        pause.tap()
        let play = app.buttons["Play Read Aloud"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let highlight = app.buttons["Yellow highlight"].firstMatch
        // The text ends on a slightly different line with different reader fonts.
        // Stay outside the pill's horizontal bounds while selecting a bottom line.
        for y in [0.925, 0.90, 0.875] {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: y)).press(forDuration: 1)
            if highlight.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(highlight.exists, "The fixture must have selectable text near the page bottom")
        let annotations = app.descendants(matching: .any)["reader-annotation-toolbar"].firstMatch
        let narration = app.descendants(matching: .any)["reader-narration-controls"].firstMatch
        XCTAssertTrue(annotations.waitForExistence(timeout: 5))
        XCTAssertTrue(narration.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(annotations.frame.minY, window.frame.height * 0.65)
        XCTAssertFalse(annotations.frame.intersects(narration.frame), "Annotation controls covered narration controls")
        XCTAssertLessThanOrEqual(annotations.frame.maxY + 8, narration.frame.minY)
        for label in ["Play Read Aloud", "Rewind Read Aloud 15 seconds", "Skip Read Aloud 30 seconds", "Show Read Aloud controls"] {
            XCTAssertTrue(app.buttons[label].firstMatch.isHittable, "\(label) was covered by the bottom selection toolbar")
        }
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(highlight.exists, "Playback actions must preserve the user's selection")
        XCTAssertTrue(highlight.isHittable)
        attachScreenshot(app, name: "bottom-selection-with-both-toolbars")
        highlight.tap()
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
    }

    @MainActor
    private func launchReader(startNarration: Bool, fixtureName: String = "reader-interaction") throws -> XCUIApplication {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixtureName, withExtension: "epub"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = [
            "-imagineScreen", "footnotefixture",
            "-imagineFixture", "reader-interaction-\(UUID().uuidString).epub",
        ] + (startNarration ? ["--exercise-read-aloud"] : [])
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 30))
        let passage = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Edge selection remains on this page")
        ).firstMatch
        XCTAssertTrue(passage.waitForExistence(timeout: 30))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: passage)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed, "Wait for book text, not just reader chrome")
        if startNarration { showNarrationControls(app) }
        return app
    }

    @MainActor
    private func showNarrationControls(_ app: XCUIApplication) {
        let more = app.buttons["Show Read Aloud controls"].firstMatch
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        // Refresh the four-second window instead of racing a nearly expired timer.
        if more.exists {
            center.tap()
            XCTAssertTrue(more.waitForNonExistence(timeout: 5))
        }
        center.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertRemainsVisible(_ element: XCUIElement, for seconds: TimeInterval) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        disappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: seconds), .completed)
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
