import XCTest

final class SiloLiveUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENVE_SILO_UI"] == "1", "Requires isolated Silo lab fixtures")
        continueAfterFailure = false
    }

    @MainActor
    func testPrepareIsolatedProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "profiles"]
        app.launch()
        let useFixture = app.buttons["Use Silo live verification"].firstMatch
        if !useFixture.waitForExistence(timeout: 5) {
            let enable = app.buttons["profiles-enable"]
            XCTAssertTrue(enable.waitForExistence(timeout: 30))
            enable.tap()
            let name = app.textFields["profile-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Adult")
            app.buttons["profile-save"].tap()
            let add = app.buttons["profiles-add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Silo live verification")
            app.switches["profile-setup-server-sync"].tap()
            app.buttons["profile-save"].tap()
        }
        XCTAssertTrue(useFixture.waitForExistence(timeout: 10))
        useFixture.tap()
        let profileID = useFixture.identifier.replacingOccurrences(of: "profile-switch-", with: "")
        XCTAssertTrue(app.staticTexts["profile-current-\(profileID)"].waitForExistence(timeout: 15))
        app.terminate()
    }

    @MainActor
    func testSyncedNoteRemainsVisibleAfterRestart() throws {
        guard let note = ProcessInfo.processInfo.environment["ENVE_SILO_EXPECTED_NOTE"] else {
            throw XCTSkip("Requires a note created in the Silo reader fixture")
        }
        let app = XCUIApplication()
        for _ in 0..<2 {
            app.launchArguments = ["-imagineScreen", "library"]
            app.launch()
            let library = app.buttons["tab_library"]
            XCTAssertTrue(library.waitForExistence(timeout: 15))
            library.tap()
            let book = app.scrollViews["library-screen"].buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Reader Interaction Regression")
            ).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 15))
            book.tap()
            let read = app.buttons.matching(identifier: "Read").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(read)
            read?.tap()
            let contents = app.buttons["Contents"].firstMatch
            XCTAssertTrue(contents.waitForExistence(timeout: 15))
            contents.tap()
            let tray = app.descendants(matching: .any)["reader-contents-tray"].firstMatch
            XCTAssertTrue(tray.waitForExistence(timeout: 10))
            tray.buttons["Notes"].tap()
            let clear = tray.buttons["Clear search"]
            if clear.exists { clear.tap() }
            let search = tray.textFields["Search notes…"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText(note)
            XCTAssertEqual(search.value as? String, note)
            XCTAssertTrue(tray.staticTexts[note].firstMatch.waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor
    func testRestoreOriginalProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "profiles"]
        app.launch()
        let owner = app.buttons["Use Adult"].firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 30))
        owner.tap()
        let ownerID = owner.identifier.replacingOccurrences(of: "profile-switch-", with: "")
        XCTAssertTrue(app.staticTexts["profile-current-\(ownerID)"].waitForExistence(timeout: 15))
        app.buttons["Remove"].firstMatch.tap()
        let remove = app.buttons["profile-save"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.buttons["Use Silo live verification"].firstMatch.waitForNonExistence(timeout: 10))
        app.buttons["Turn off profiles"].tap()
        XCTAssertTrue(app.buttons["profiles-enable"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
