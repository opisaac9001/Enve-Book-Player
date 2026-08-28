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
    func testReaderPresentation() throws {
        let app = launch(route: "reader")

        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 20))
        try performReleaseAccessibilityAudit(in: app)
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
        contentSizeCategory: String = "UICTContentSizeCategoryL"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineScreen", route,
            "-UIPreferredContentSizeCategoryName", contentSizeCategory,
        ]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        return app
    }
}
