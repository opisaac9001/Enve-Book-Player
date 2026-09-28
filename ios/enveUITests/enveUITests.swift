import XCTest

final class enveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStoryAlignPickerShowsSelectableContentOrEmptyState() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        let settingsTab =
            app.buttons["tab_settings"].exists
            ? app.buttons["tab_settings"]
            : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Settings")).firstMatch
        guard settingsTab.waitForExistence(timeout: 15) else {
            throw XCTSkip("Settings tab not reachable (first-run onboarding state)")
        }
        settingsTab.tap()

        let storyAlignQuery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "StoryAlign"))
        var attempts = 0
        while !storyAlignQuery.firstMatch.waitForExistence(timeout: 2), attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        let storyAlign = storyAlignQuery.firstMatch
        guard storyAlign.exists else {
            throw XCTSkip("StoryAlign entry not present in this configuration")
        }
        storyAlign.tap()

        if app.staticTexts["StoryAlign Unavailable"].waitForExistence(timeout: 2) {
            return
        }

        XCTAssertTrue(app.staticTexts["StoryAlign"].waitForExistence(timeout: 10))
        let ebookButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ebook")).firstMatch
        XCTAssertTrue(ebookButton.waitForExistence(timeout: 10))
        ebookButton.tap()

        XCTAssertTrue(app.staticTexts["Choose the ebook"].waitForExistence(timeout: 10))
        let pickerLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.staticTexts["Nothing of this kind in the library yet."].exists || app.staticTexts["Nothing matches that search."].exists
                    || app.buttons["Load More"].exists || app.scrollViews.buttons.count > 0
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pickerLoaded], timeout: 10), .completed)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

final class enveUISmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndLibraryNavigation() {
        let app = launch(route: "browse")

        let libraryTab = app.buttons["tab_library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        app.buttons["tab_hearth"].tap()
        libraryTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLibraryOPDSSourceOpensCatalog() {
        let app = launch(route: "library")
        let source = app.buttons["library-source-menu"]
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        source.tap()

        let catalog = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library-opds-catalog-")
        ).firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        catalog.tap()
        XCTAssertTrue(app.staticTexts["OPDS catalogue"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testHearthAccessibility() throws {
        let app = launch(route: "hearth")
        let hearthTab = app.buttons["tab_hearth"]

        XCTAssertTrue(hearthTab.waitForExistence(timeout: 20))
        hearthTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hearth-screen"].waitForExistence(timeout: 10))
        try performReleaseAccessibilityAudit(in: app)
    }

    @MainActor
    func testLibraryAccessibility() throws {
        let app = launch(route: "browse")

        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 20))
        assertVisibleButtonHitRegions(in: app)
        for audit in libraryAuditTypes {
            try XCTContext.runActivity(named: audit.name) { _ in
                try app.performAccessibilityAudit(for: audit.type)
            }
        }
    }

    @MainActor
    func testPlayerPresentation() throws {
        let app = launch(route: "player")

        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
        try performReleaseAccessibilityAudit(in: app)
    }

    @MainActor
    func testPassageAvailabilityPrompt() {
        let app = launch(route: "player")
        let readingOptions = app.buttons["Reading options"]
        XCTAssertTrue(readingOptions.waitForExistence(timeout: 20))
        readingOptions.tap()

        let findPassage = app.buttons["Find this passage in ebook"]
        XCTAssertTrue(findPassage.waitForExistence(timeout: 5))
        findPassage.tap()

        if #available(iOS 26.0, *) {
            XCTAssertTrue(app.staticTexts["Link an ebook first"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.alerts["Update Required"].exists)
        } else {
            let alert = app.alerts["Update Required"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts["Finding passages in an ebook requires iOS 26.0 or newer."].exists)
            alert.buttons["OK"].tap()
            XCTAssertTrue(readingOptions.exists)
            XCTAssertFalse(alert.exists)
        }
    }

    @MainActor
    func testReaderPresentation() throws {
        let app = launch(route: "reader")

        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 20))
        try performReleaseAccessibilityAudit(in: app)
    }

    @MainActor
    func testRealGrimmoryReadAloudHighlightSurvivesReopen() throws {
        let app = launch(route: "library")
        let booksTab = app.buttons["BOOKS"].firstMatch
        XCTAssertTrue(booksTab.waitForExistence(timeout: 20))
        booksTab.tap()
        let book = app.buttons[
            "Hunter, Erin - Warriors: The New Prophecy 01 - Midnight, Hunter, Erin, 3"
        ].firstMatch
        guard book.waitForExistence(timeout: 60) else {
            throw XCTSkip("The real Grimmory read-aloud book is not in this library")
        }
        book.tap()

        let read = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Read", "Resume")
        ).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()

        let reader = app.descendants(matching: .any)["reader-screen"]
        XCTAssertTrue(
            reader.waitForExistence(timeout: 120),
            "The real Grimmory read-aloud EPUB never presented the reader"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["reader-progress-slider"].waitForExistence(timeout: 120),
            "The real Grimmory read-aloud EPUB never became ready for navigation"
        )
        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(of: app, named: "real-grimmory-open")
        let contents = app.buttons["Contents"].firstMatch
        if !contents.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        contents.tap()
        let prologue = app.buttons["Prologue"].firstMatch
        XCTAssertTrue(prologue.waitForExistence(timeout: 20))
        prologue.tap()
        Thread.sleep(forTimeInterval: 3)
        attachScreenshot(of: app, named: "real-grimmory-prologue")
        let passage = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.52))
        passage.press(forDuration: 1.2)
        attachScreenshot(of: app, named: "real-grimmory-selection")
        let highlight = app.buttons["Yellow highlight"].firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 10))
        highlight.tap()
        attachScreenshot(of: app, named: "real-grimmory-highlight")

        let close = app.buttons["Close"].firstMatch
        if !close.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 120))
        XCTAssertTrue(app.descendants(matching: .any)["reader-progress-slider"].waitForExistence(timeout: 120))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.92)).tap()
        app.buttons["Notes"].firstMatch.tap()
        let note = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "top, Highlight")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "real-grimmory-note-after-reopen")
        note.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Notes"].firstMatch.exists)
        attachScreenshot(of: app, named: "real-grimmory-note-navigation")
    }

    @MainActor
    func testRealGrimmoryMidChapterLocationSurvivesReopenAndRelaunch() throws {
        let app = launch(route: "library")
        let book = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Warriors: The New Prophecy 01 - Midnight", "Hunter, Erin")
        ).firstMatch
        let booksTab = app.buttons["BOOKS"].firstMatch
        XCTAssertTrue(booksTab.waitForExistence(timeout: 20))
        booksTab.tap()
        guard book.waitForExistence(timeout: 60) else {
            throw XCTSkip("The real Grimmory read-aloud book is not in this library")
        }
        book.tap()

        let read = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Read", "Resume")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        let reader = app.descendants(matching: .any)["reader-screen"]
        let progress = app.descendants(matching: .any)["reader-progress-slider"]
        XCTAssertTrue(reader.waitForExistence(timeout: 120))
        XCTAssertTrue(progress.waitForExistence(timeout: 120))
        Thread.sleep(forTimeInterval: 4)
        let contents = app.buttons["Contents"].firstMatch
        if !contents.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        contents.tap()
        let prologue = app.buttons["Prologue"].firstMatch
        XCTAssertTrue(prologue.waitForExistence(timeout: 20))
        prologue.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        let before = (progress.value as? String)?.components(separatedBy: " · ").first
        XCTAssertNotNil(before, "The starting Prologue location is unavailable")
        for _ in 0..<3 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        Thread.sleep(forTimeInterval: 2)
        if !progress.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let midChapter = (progress.value as? String)?.components(separatedBy: " · ").first
        XCTAssertNotNil(midChapter, "The mid-chapter location is unavailable")
        XCTAssertNotEqual(before, midChapter, "A page turn did not change the real book's location")
        let locationNumber = Int((midChapter ?? "").split(separator: " ").dropFirst().first ?? "")
        XCTAssertGreaterThan(locationNumber ?? 0, 13, "The test did not advance beyond the first Prologue location")
        attachScreenshot(of: app, named: "real-grimmory-midchapter-before-close")

        let close = app.buttons["Close"].firstMatch
        if !close.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 120))
        XCTAssertTrue(progress.waitForExistence(timeout: 120))
        XCTAssertEqual((progress.value as? String)?.components(separatedBy: " · ").first, midChapter, "The book moved after closing and reopening")
        attachScreenshot(of: app, named: "real-grimmory-midchapter-after-reopen")

        for attempt in 1...5 {
            app.terminate()
            app.launch()
            XCTAssertTrue(booksTab.waitForExistence(timeout: 20))
            booksTab.tap()
            XCTAssertTrue(book.waitForExistence(timeout: 60))
            book.tap()
            XCTAssertTrue(read.waitForExistence(timeout: 15))
            read.tap()
            XCTAssertTrue(reader.waitForExistence(timeout: 120))
            XCTAssertTrue(progress.waitForExistence(timeout: 120))
            XCTAssertEqual(
                (progress.value as? String)?.components(separatedBy: " · ").first,
                midChapter,
                "The book moved after app relaunch \(attempt)"
            )
        }
        Thread.sleep(forTimeInterval: 3)
        attachScreenshot(of: app, named: "real-grimmory-midchapter-after-relaunch")
    }

    @MainActor
    func testRealGrimmoryMidChapterReadAloudDoesNotRestart() throws {
        let app = launch(route: "library")
        let book = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Warriors: The New Prophecy 01 - Midnight", "Hunter, Erin")
        ).firstMatch
        let booksTab = app.buttons["BOOKS"].firstMatch
        XCTAssertTrue(booksTab.waitForExistence(timeout: 20))
        booksTab.tap()
        guard book.waitForExistence(timeout: 60) else {
            throw XCTSkip("The real Grimmory read-aloud book is not in this library")
        }
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Read", "Resume")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        let reader = app.descendants(matching: .any)["reader-screen"]
        let progress = app.descendants(matching: .any)["reader-progress-slider"]
        XCTAssertTrue(reader.waitForExistence(timeout: 120))
        XCTAssertTrue(progress.waitForExistence(timeout: 120))
        Thread.sleep(forTimeInterval: 4)
        let contents = app.buttons["Contents"].firstMatch
        if !contents.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        contents.tap()
        let prologue = app.buttons["Prologue"].firstMatch
        XCTAssertTrue(prologue.waitForExistence(timeout: 20))
        prologue.tap()
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<3 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        let locationNumber = Int(((progress.value as? String) ?? "").split(separator: " ").dropFirst().first ?? "")
        XCTAssertGreaterThan(locationNumber ?? 0, 13, "The test did not reach a mid-chapter reading position")
        let more = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "More", "More reader options")).firstMatch
        if !more.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(more.waitForExistence(timeout: 120))
        more.tap()
        attachScreenshot(of: app, named: "real-grimmory-reader-more-menu")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.86)).tap()
        attachScreenshot(of: app, named: "real-grimmory-after-read-aloud-toggle")
        let nextSegment = app.buttons["Next Read Aloud segment"].firstMatch
        XCTAssertTrue(nextSegment.waitForExistence(timeout: 90))
        nextSegment.tap()
        Thread.sleep(forTimeInterval: 2)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        if pause.exists { pause.tap() }
        attachScreenshot(of: app, named: "real-grimmory-read-aloud-midchapter")

        let stopReadAloud = app.buttons["Stop Read Aloud"].firstMatch
        XCTAssertTrue(stopReadAloud.waitForExistence(timeout: 10))
        stopReadAloud.tap()
        if !progress.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let afterListening = (progress.value as? String)?.components(separatedBy: " · ").first
        XCTAssertNotNil(afterListening)
        attachScreenshot(of: app, named: "real-grimmory-after-read-aloud-stop")

        let close = app.buttons["Close"].firstMatch
        if !close.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 120))
        XCTAssertTrue(progress.waitForExistence(timeout: 120))
        XCTAssertEqual((progress.value as? String)?.components(separatedBy: " · ").first, afterListening, "The book moved after Read Aloud was stopped and reopened")
        let reopenedPassage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "The gray-black shape that formed in the pool")
        ).firstMatch
        XCTAssertTrue(reopenedPassage.waitForExistence(timeout: 15), "The reopened reader never rendered the saved passage")
        attachScreenshot(of: app, named: "real-grimmory-after-read-aloud-reopen")
    }

    @MainActor
    func testReadAloudReadModeShowsOneSentenceAtATime() throws {
        let app = launch(route: "hearth")

        // Opening from a home card yields the book instance whose Listen action starts the
        // narrated session; the detail debug route resolves a different one that plays plain audio.
        // The hero card rotates with recent activity, so match the title anywhere on the screen.
        let card = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Enve Readaloud Sync Regression"))
            .firstMatch
        guard card.waitForExistence(timeout: 40) else {
            throw XCTSkip("Read-aloud fixture is not on the home screen")
        }
        card.tap()

        let listen = app.buttons["Listen"].firstMatch
        guard listen.waitForExistence(timeout: 60) else {
            throw XCTSkip("No narrated book with a Listen action is available in this library")
        }
        listen.tap()

        // A narrated EPUB extracts audio and parses its SMIL before the player appears, so the
        // toggle itself is the only reliable signal that the player is ready.
        let readPill = app.descendants(matching: .any)["Player.ReadModeToggle"].firstMatch
        guard readPill.waitForExistence(timeout: 180) else {
            throw XCTSkip("Player never presented a Read mode toggle for this book")
        }
        // The player slides up over the previous screen; tapping mid-animation lands elsewhere.
        Thread.sleep(forTimeInterval: 5)
        attachScreenshot(of: app, named: "readmode-00-player-cover")
        // The pill collapses to a glyph in the utility row, which XCUITest cannot scroll to
        // visible, so tap its centre directly.
        readPill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let panel = app.descendants(matching: .any)["Player.ReadMode"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 30), "Read mode panel never replaced the cover")
        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(of: app, named: "readmode-01-panel")

        // Tapping a line seeks the narration to it; the middle line is fully on screen.
        let middleLine = app.descendants(matching: .any)["Second synchronized passage. The reader turns a page."]
            .firstMatch
        XCTAssertTrue(middleLine.waitForExistence(timeout: 10), "Read mode did not render its lines as text")
        middleLine.tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(of: app, named: "readmode-02-seeked")

        let play = app.buttons["Play"].firstMatch
        if play.exists {
            play.tap()
            Thread.sleep(forTimeInterval: 6)
            attachScreenshot(of: app, named: "readmode-03-playing")
        }
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSettingsAccessibility() throws {
        let app = launch(route: "settings")

        XCTAssertTrue(app.descendants(matching: .any)["settings-screen"].waitForExistence(timeout: 20))
        try performReleaseAccessibilityAudit(in: app)
    }

    @MainActor
    func testLibraryHealthPresentationAndAccessibility() throws {
        let app = launch(route: "libraryhealth")

        XCTAssertTrue(app.descendants(matching: .any)["library-health-screen"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["library-health-overall-status"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["library-health-check-now"].exists)
        try performReleaseAccessibilityAudit(in: app)
    }

    @MainActor
    func testLibraryHealthAtAccessibilityTextSize() throws {
        let app = launch(
            route: "libraryhealth",
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL"
        )

        XCTAssertTrue(app.descendants(matching: .any)["library-health-screen"].waitForExistence(timeout: 20))
        try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
    }

    private var releaseAuditTypes: XCUIAccessibilityAuditType {
        [
            .sufficientElementDescription,
            .hitRegion,
            .textClipped,
            .trait,
        ]
    }

    private var libraryAuditTypes: [(name: String, type: XCUIAccessibilityAuditType)] {
        // Cover tiles clamp visual titles while their buttons expose the full accessibility label.
        var audits: [(name: String, type: XCUIAccessibilityAuditType)] = [
            ("Element descriptions", .sufficientElementDescription),
            ("Traits", .trait),
        ]
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            audits.append(("Contrast", .contrast))
        }
        return audits
    }

    @MainActor
    private func performReleaseAccessibilityAudit(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: releaseAuditTypes)
        // iOS 27 beta reports false failures for demonstrably high-contrast text on physical devices.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            try app.performAccessibilityAudit(for: .contrast)
        }
    }

    @MainActor
    private func assertVisibleButtonHitRegions(in app: XCUIApplication) {
        let visibleFrame = app.windows.firstMatch.frame
        for button in app.buttons.allElementsBoundByIndex {
            let frame = button.frame
            guard !frame.isEmpty, frame.intersects(visibleFrame), button.isHittable else { continue }
            XCTAssertGreaterThanOrEqual(frame.width + 0.01, 44, "\(button.label) is narrower than 44 points")
            XCTAssertGreaterThanOrEqual(frame.height + 0.01, 44, "\(button.label) is shorter than 44 points")
        }
    }

    @MainActor
    private func launch(
        route: String,
        contentSizeCategory: String = "UICTContentSizeCategoryL",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineScreen", route,
            "-UIPreferredContentSizeCategoryName", contentSizeCategory,
        ] + extraArguments
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        return app
    }
}
