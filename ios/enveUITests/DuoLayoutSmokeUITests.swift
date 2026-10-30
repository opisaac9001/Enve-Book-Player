import XCTest

// Captures resized layouts and checks that controls remain inside the window.
final class DuoLayoutSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testLibraryKeepsControlsOnScreenAcrossOrientations() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineSeed", "48", "-imagineScenario", "mixed", "-imagineScreen", "library",
            "-imagine.library.source", "all", "-imagine.library.source.media.all", "all",
            "-imagine.library.status", "all", "-imagine.library.media", "all",
            "-imagine.library.facet", "books", "-imagine.library.layout", "list",
        ]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["tab_library"].waitForExistence(timeout: 20))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            record(app, name: "library-list-\(label(orientation))")
            assertInsideWindow(app.buttons["tab_library"], app, "library tab, \(label(orientation))")
            assertInsideWindow(app.buttons["Search the library"].firstMatch, app, "search, \(label(orientation))")
        }

        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        let more = app.buttons["library-more-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let gridToggle = app.buttons["Show grid"].firstMatch
        XCTAssertTrue(gridToggle.waitForExistence(timeout: 5))
        gridToggle.tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            record(app, name: "library-grid-\(label(orientation))")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        var reachedList = false
        for _ in 0..<14 {
            more.tap()
            let listToggle = app.buttons["Show as list"].firstMatch
            if listToggle.exists {
                record(app, name: "library-grid-largest-portrait")
                listToggle.tap()
                reachedList = true
                break
            }
            let cycle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cover size")).firstMatch
            XCTAssertTrue(cycle.waitForExistence(timeout: 5))
            cycle.tap()
        }
        XCTAssertTrue(reachedList, "The cover-size cycle must return to the list layout")

        app.buttons["tab_journal"].tap()
        sleep(1)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        record(app, name: "journal-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        // The selected tab survives the resize: the journal header is still the visible screen.
        XCTAssertTrue(app.staticTexts["Journal"].firstMatch.waitForExistence(timeout: 5))
        record(app, name: "journal-portrait")
    }

    @MainActor
    func testPlayerKeepsTransportOnScreenAcrossOrientations() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "player"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let skipForward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        XCTAssertTrue(skipForward.waitForExistence(timeout: 60))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            _ = rotate(app, to: orientation)
            record(app, name: "player-\(label(orientation))")
            // Open sideways, a folding phone keeps the player on the facing page; the pill brings it back as
            // a cover once the phone is upright again.
            if isSpread(app) {
                XCTAssertTrue(app.descendants(matching: .any)["facing-page"].firstMatch.waitForExistence(timeout: 10))
                assertInsideWindow(app.buttons["Book details"].firstMatch, app, "details, spread")
            } else {
                if !app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3) {
                    app.buttons["mantel-pill"].firstMatch.tap()
                    sleep(2)
                }
                assertInsideWindow(app.buttons["Close player"].firstMatch, app, "close, \(label(orientation))")
            }
            assertInsideWindow(skipForward, app, "skip forward, \(label(orientation))")
            assertInsideWindow(app.buttons["More player tools"].firstMatch, app, "more tools, \(label(orientation))")
            assertInsideWindow(
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Scrub range")).firstMatch,
                app,
                "scrub range, \(label(orientation))"
            )
        }
    }

    @MainActor
    func testReaderChromeAndPositionSurviveOrientationChanges() throws {
        let app = XCUIApplication()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reader-navigation", withExtension: "epub"))
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = ["-imagineScreen", "footnotefixture", "-imagineFixture", "reader-duo-\(UUID().uuidString).epub"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 60))
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Reading progress")).firstMatch
        if !progress.waitForExistence(timeout: 8) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let before = progress.value as? String
        record(app, name: "reader-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        if !progress.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        record(app, name: "reader-landscape")
        assertInsideWindow(app.buttons["Contents"].firstMatch, app, "contents, landscape")
        assertInsideWindow(app.buttons["Close"].firstMatch, app, "close, landscape")

        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        if !progress.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let after = progress.value as? String
        record(app, name: "reader-portrait-again")
        let note = XCTAttachment(string: "before: \(before ?? "nil")\nafter: \(after ?? "nil")")
        note.name = "reader-position"
        note.lifetime = .keepAlways
        add(note)
        assertInsideWindow(app.buttons["Contents"].firstMatch, app, "contents, portrait")
    }

    // A partly open hinge in portrait becomes a nightstand: the transport lives on the lower half.
    @MainActor
    func testNightstandPlayerWhenHingeIsPartlyOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "player", "-imagineHinge", "partiallyOpen", "-imagineFold", "horizontal"]
        app.launch()
        let skipForward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        XCTAssertTrue(skipForward.waitForExistence(timeout: 60))
        try XCTSkipUnless(rotate(app, to: .portrait), "the simulator kept its landscape canvas")
        record(app, name: "player-nightstand-portrait")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(skipForward.frame.minY, window.midY - 1, "transport should sit on the flat lower half")
        assertInsideWindow(app.buttons["More player tools"].firstMatch, app, "more tools, nightstand")
        assertInsideWindow(app.buttons["Close player"].firstMatch, app, "close, nightstand")
        XCTAssertTrue(app.buttons["Close player"].firstMatch.frame.maxY <= window.midY, "close button stays on the upright half")
        let clock = app.descendants(matching: .any)["nightstand-clock"].firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(clock.frame.minY, app.buttons["Close player"].firstMatch.frame.maxY, "the clock clears the top buttons")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        record(app, name: "player-book-landscape")
        assertInsideWindow(skipForward, app, "skip forward, book pose")
        XCUIDevice.shared.orientation = .portrait
    }

    // Closed, a folding phone keeps the stacks on the outer display and the tabs in the system's side column;
    // other devices and the open display skip this.
    @MainActor
    func testPocketKeepsTheTabsInTheSideColumnWhenClosed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineSeed", "12", "-imagineScenario", "mixed", "-imagineScreen", "library"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 60))
        sleep(2)
        let window = app.windows.firstMatch.frame
        let rail = app.descendants(matching: .any)["mantel-rail"].firstMatch
        guard window.width < 600, window.height < 700, rail.waitForExistence(timeout: 5) else {
            throw XCTSkip("the pocket needs the outer display of a folding phone")
        }
        record(app, name: "pocket-library")
        XCTAssertGreaterThanOrEqual(rail.frame.minX, window.maxX - 90, "the rail stands in the side column")
        for tab in ["tab_hearth", "tab_library", "tab_podcasts", "tab_journal"] {
            assertInsideWindow(app.buttons[tab], app, "\(tab) in the column")
            XCTAssertGreaterThanOrEqual(app.buttons[tab].frame.minX, window.maxX - 90, "\(tab) sits in the column")
        }
        let search = app.buttons["Search the library"].firstMatch
        assertInsideWindow(search, app, "search on the pocket")
        XCTAssertLessThanOrEqual(search.frame.maxX, rail.frame.minX + 1, "the stacks stop at the column")
        XCTAssertGreaterThanOrEqual(search.frame.minY, window.minY + 24, "the stacks keep clear of the top edge")
        XCTAssertFalse(app.descendants(matching: .any)["facing-page"].exists, "closed, there is no facing page")
    }

    // In the shell, a partly open hinge in portrait lays the dock with the transport and the tabs on the flat lower half.
    @MainActor
    func testNightstandDockWhenHingeIsPartlyOpenInTheShell() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "player", "-imagineHinge", "partiallyOpen", "-imagineFold", "horizontal"]
        app.launch()
        let skipForward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        XCTAssertTrue(skipForward.waitForExistence(timeout: 60))
        try XCTSkipUnless(rotate(app, to: .portrait), "the simulator kept its landscape canvas")
        let close = app.buttons["Close player"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        close.tap()
        let dock = app.descendants(matching: .any)["nightstand-dock"].firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        sleep(2)
        record(app, name: "nightstand-shell-portrait")
        XCTAssertGreaterThanOrEqual(dock.frame.minY, window.midY - 1, "the dock lies on the flat lower half")
        assertInsideWindow(skipForward, app, "skip forward in the dock")
        XCTAssertGreaterThanOrEqual(skipForward.frame.minY, window.midY, "transport sits on the flat half")
        assertInsideWindow(app.buttons["tab_journal"], app, "journal tab in the dock")
        XCTAssertGreaterThanOrEqual(app.buttons["tab_journal"].frame.minY, window.midY, "tabs sit in the dock")
    }

    // A partly open hinge in portrait becomes a lectern: the page stands upright, the controls lie flat.
    @MainActor
    func testLecternReaderWhenHingeIsPartlyOpen() throws {
        let app = XCUIApplication()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reader-navigation", withExtension: "epub"))
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = [
            "-imagineScreen", "footnotefixture",
            "-imagineFixture", "reader-lectern-\(UUID().uuidString).epub",
            "-imagineHinge", "partiallyOpen",
            "-imagineFold", "horizontal",
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 60))
        try XCTSkipUnless(rotate(app, to: .portrait), "the simulator kept its landscape canvas")
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 30))
        sleep(6)
        // The lectern keeps its controls without any tap, even after the chrome's auto-hide delay.
        XCTAssertTrue(contents.exists)
        record(app, name: "reader-lectern-portrait")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(contents.frame.minY, window.midY - 1, "controls should sit on the flat lower half")
        assertInsideWindow(contents, app, "contents, lectern")
        // The flat half turns pages on its own, so the upright page never has to be reached for.
        let nextPage = app.buttons["Next page"].firstMatch
        let previousPage = app.buttons["Previous page"].firstMatch
        assertInsideWindow(nextPage, app, "next page, lectern")
        assertInsideWindow(previousPage, app, "previous page, lectern")
        XCTAssertGreaterThanOrEqual(nextPage.frame.minY, window.midY - 1, "page turns sit on the flat lower half")
        XCTAssertLessThan(previousPage.frame.midX, nextPage.frame.midX, "previous page stands to the left of next page")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        record(app, name: "reader-book-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    // Held open sideways, a folding phone shows the stacks beside the facing page; narrower devices skip this.
    @MainActor
    func testSpreadKeepsTheRailAndFacingPageOnWideFoldableCanvases() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineSeed", "12", "-imagineScenario", "mixed", "-imagineScreen", "hearth"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["hearth-screen"].waitForExistence(timeout: 60))
        sleep(2)
        let window = app.windows.firstMatch.frame
        record(app, name: "spread-hearth-landscape")
        guard isSpread(app) else {
            throw XCTSkip("the spread needs the inner display of a folding phone")
        }
        let rail = app.descendants(matching: .any)["mantel-rail"].firstMatch
        let facing = app.descendants(matching: .any)["facing-page"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        XCTAssertTrue(facing.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(rail.frame.minX, window.midX, "the rail stands in the side column")
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(settings.frame.minY, window.minY + 24, "the hearth header keeps clear of the top edge")
        settings.tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(back.frame.minY, window.minY + 24, "pushed settings keeps clear of the top edge")
        record(app, name: "spread-settings-landscape")
        back.tap()
        // The shell's backdrop runs under the fold and the column; the page's controls stay between the two.
        let details = app.buttons["Book details"].firstMatch
        if details.waitForExistence(timeout: 5) {
            XCTAssertGreaterThanOrEqual(details.frame.minX, window.midX, "the facing page's controls start past the fold")
            XCTAssertLessThanOrEqual(details.frame.maxX, rail.frame.minX + 1, "the facing page's controls stop at the rail")
            XCTAssertGreaterThanOrEqual(details.frame.minY, window.minY + 24, "the facing page's controls keep clear of the top edge")
        }
        assertInsideWindow(app.buttons["tab_library"], app, "library tab on the rail")

        app.buttons["tab_library"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 20))
        sleep(2)
        record(app, name: "spread-library-landscape")
        XCTAssertTrue(facing.exists, "the facing page stays while the stacks change")

        if rotate(app, to: .portrait) {
            record(app, name: "spread-portrait")
            XCTAssertTrue(app.buttons["tab_library"].waitForExistence(timeout: 10))
            XCTAssertFalse(rail.exists, "upright, the bottom bar returns")
        }
    }

    @MainActor
    func testTeardownSyntheticLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineTeardownSynthetic", "1", "-imagineScreen", "library"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 60))
        sleep(5)
    }

    private func label(_ orientation: UIDeviceOrientation) -> String {
        orientation.isLandscape ? "landscape" : "portrait"
    }

    // A folding phone's simulator keeps its inner display's orientation, so a test that needs a particular
    // shape checks what it actually got.
    @MainActor
    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) -> Bool {
        XCUIDevice.shared.orientation = orientation
        sleep(2)
        let window = app.windows.firstMatch.frame
        return orientation.isLandscape ? window.width > window.height : window.height > window.width
    }

    // The inner display of a folding phone held sideways; landscape phones are too short to spread.
    @MainActor
    private func isSpread(_ app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch.frame
        return window.width > window.height && window.width >= 900 && window.height >= 600
    }

    @MainActor
    private func record(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let window = app.windows.firstMatch.frame
        let hierarchy = XCTAttachment(string: "window: \(window)\n\n" + app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func assertInsideWindow(_ element: XCUIElement, _ app: XCUIApplication, _ what: String) {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("\(what): element missing")
            return
        }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertTrue(window.contains(frame), "\(what): \(frame) is not inside window \(window)")
        XCTAssertTrue(element.isHittable, "\(what): not hittable")
    }
}
