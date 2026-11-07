import XCTest

final class HearthProfileLoadingUITests: XCTestCase {
    private struct FixtureState: Decodable {
        let libraryMode: String
        let blockedLibraryRequests: Int
    }

    private let ownerName = "Hearth Loading Owner"
    private let readerName = "Hearth Loading Reader"

    @MainActor
    func testProfileSwitchRendersCachedHearthWhileLibraryNamesAreBlocked() async throws {
        guard ProcessInfo.processInfo.environment["ENVE_PROFILE_UI"] == "1" else {
            throw XCTSkip("Requires a dedicated compatibility simulator with profiles disabled")
        }
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_HEARTH_FIXTURE_URL"] else {
            throw XCTSkip("Requires the local Hearth catalog fixture")
        }
        continueAfterFailure = false
        let usesPIN = ProcessInfo.processInfo.environment["ENVE_PROFILE_PIN_UI"] == "1"
        try await Self.setMode("initial", path: "/__fixture/mode", endpoint: endpoint)
        try await Self.setMode("ready", path: "/__fixture/libraries", endpoint: endpoint)
        addTeardownBlock {
            try? await Self.setMode("ready", path: "/__fixture/libraries", endpoint: endpoint)
        }

        let app = XCUIApplication()
        let hearth = app.descendants(matching: .any)["hearth-screen"]
        let fixtureBook = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "Hearth Fixture Cached", "Hearth Fixture Added"
        )).firstMatch
        let quote = app.descendants(matching: .any)["hearth-quote"].firstMatch
        let loading = app.descendants(matching: .any)["hearth-loading"].firstMatch
        let emptyHearth = app.staticTexts["Light the fire."]
        let homeProfiles = app.buttons["home-profiles"]
        let reader = app.buttons["Use \(readerName)"].firstMatch
        let owner = app.buttons["Use \(ownerName)"].firstMatch

        app.launchArguments = [
            "-imagineScreen", "hearth", "-imagineSourceType", "grimmory", "-imagineSourceURL", endpoint,
            "-imagineSourceUser", "fixture", "-imagineSourcePassword", "fixture-password",
        ]
        app.launch()
        XCTAssertTrue(hearth.waitForExistence(timeout: 30))
        XCTAssertTrue(fixtureBook.waitForExistence(timeout: 40), "The owner library must cache fixture books before profiles exist")
        app.terminate()

        app.launchArguments = ["-imagineScreen", "profiles"]
        app.launch()
        let enable = app.buttons["profiles-enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 30), "Profiles must be disabled before this test starts")
        enable.tap()
        let name = app.textFields["profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(ownerName)
        if usesPIN {
            app.secureTextFields["profile-pin"].tap()
            app.secureTextFields["profile-pin"].typeText("291746")
            app.secureTextFields["profile-pin-confirm"].tap()
            app.secureTextFields["profile-pin-confirm"].typeText("291746")
        }
        app.buttons["profile-save"].tap()
        let addProfile = app.buttons["profiles-add"]
        XCTAssertTrue(addProfile.waitForExistence(timeout: 10))
        addProfile.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(readerName)
        app.buttons["profile-save"].tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        if usesPIN {
            addProfile.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Hearth Loading Child")
            let childSwitch = app.switches["Child profile"]
            childSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertEqual(childSwitch.value as? String, "1")
            app.buttons["profile-save"].tap()
            XCTAssertTrue(app.buttons["Use Hearth Loading Child"].waitForExistence(timeout: 10))
        }
        let ownerID = owner.identifier.replacingOccurrences(of: "profile-switch-", with: "")
        XCTAssertTrue(app.staticTexts["profile-current-\(ownerID)"].exists)
        app.terminate()

        try await Self.setMode("blocked", path: "/__fixture/libraries", endpoint: endpoint)
        app.launchArguments = ["-imagineScreen", "hearth"]
        let launchStart = ContinuousClock.now
        app.launch()
        if usesPIN {
            let ownerPicker = app.buttons["profile-picker-adult-default"]
            XCTAssertTrue(ownerPicker.waitForExistence(timeout: 15))
            ownerPicker.tap()
            unlockPicker(app)
        }
        XCTAssertTrue(hearth.waitForExistence(timeout: 30))
        XCTAssertTrue(fixtureBook.waitForExistence(timeout: 10), "Cached owner books must render while library names are blocked")
        XCTAssertTrue(quote.waitForExistence(timeout: 10), "Hearth must finish its initial load")
        XCTAssertFalse(loading.exists)
        record("Owner cold launch to cached Hearth", since: launchStart)

        XCTAssertTrue(homeProfiles.waitForExistence(timeout: 10))
        homeProfiles.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let toReader = ContinuousClock.now
        reader.tap()
        XCTAssertTrue(emptyHearth.waitForExistence(timeout: 10), "The new profile's Hearth must finish loading its empty library")
        record("Switch to new profile until empty Hearth", since: toReader)
        XCTAssertTrue(quote.exists)
        XCTAssertFalse(loading.exists)
        XCTAssertFalse(fixtureBook.exists, "The new profile must not show the owner's cached books")
        XCTAssertTrue(homeProfiles.waitForExistence(timeout: 5))
        XCTAssertEqual(homeProfiles.label, "Profiles, \(readerName)")
        attachScreenshot(of: app, named: "hearth-new-profile-empty")

        let toOwner = ContinuousClock.now
        if usesPIN {
            XCUIDevice.shared.press(.home)
            app.activate()
            let ownerPicker = app.buttons["profile-picker-adult-default"]
            XCTAssertTrue(ownerPicker.waitForExistence(timeout: 10))
            ownerPicker.tap()
            unlockPicker(app)
        } else {
            homeProfiles.tap()
            XCTAssertTrue(owner.waitForExistence(timeout: 10))
            owner.tap()
        }
        XCTAssertTrue(fixtureBook.waitForExistence(timeout: 10), "Owner books must return from cache while library names are blocked")
        record("Switch back to owner until cached Hearth", since: toOwner)
        XCTAssertTrue(quote.waitForExistence(timeout: 5), "Hearth must finish its initial load after the switch")
        XCTAssertFalse(loading.exists)
        XCTAssertTrue(homeProfiles.waitForExistence(timeout: 5))
        XCTAssertEqual(homeProfiles.label, "Profiles, \(ownerName)")
        attachScreenshot(of: app, named: "hearth-owner-after-switch-names-blocked")

        app.buttons["tab_library"].tap()
        var fixture = try await Self.state(endpoint: endpoint)
        for _ in 0..<50 where fixture.blockedLibraryRequests == 0 {
            try await Task.sleep(for: .milliseconds(200))
            fixture = try await Self.state(endpoint: endpoint)
        }
        XCTAssertEqual(fixture.libraryMode, "blocked")
        XCTAssertGreaterThan(fixture.blockedLibraryRequests, 0, "The library-name request must still be held by the fixture")
        XCTContext.runActivity(named: "Blocked library-name requests: \(fixture.blockedLibraryRequests)") { _ in }
        app.buttons["tab_hearth"].tap()
        XCTAssertTrue(fixtureBook.waitForExistence(timeout: 10))

        try await Self.setMode("ready", path: "/__fixture/libraries", endpoint: endpoint)
        homeProfiles.tap()
        if usesPIN {
            app.buttons["profiles-unlock"].tap()
            let pin = app.secureTextFields["profile-pin"]
            XCTAssertTrue(pin.waitForExistence(timeout: 5))
            pin.tap()
            pin.typeText("291746")
            app.buttons["profile-save"].tap()
        }
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let confirmRemoval = app.buttons["profile-save"]
        XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 5))
        confirmRemoval.tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: 10))
        if usesPIN {
            remove.tap()
            XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 5))
            confirmRemoval.tap()
            XCTAssertTrue(app.buttons["Use Hearth Loading Child"].waitForNonExistence(timeout: 10))
        }
        let turnOff = app.buttons["Turn off profiles"]
        XCTAssertTrue(turnOff.waitForExistence(timeout: 10))
        turnOff.tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
    }

    @MainActor
    private func unlockPicker(_ app: XCUIApplication) {
        let pin = app.secureTextFields["profile-pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        pin.typeText("291746")
        app.buttons["profile-unlock"].tap()
    }

    @MainActor
    private func record(_ name: String, since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
        XCTContext.runActivity(named: "\(name): \(elapsed)") { _ in }
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private static func setMode(_ mode: String, path: String, endpoint: String) async throws {
        var request = URLRequest(url: URL(string: endpoint + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private static func state(endpoint: String) async throws -> FixtureState {
        let (data, _) = try await URLSession.shared.data(from: URL(string: endpoint + "/__fixture/state")!)
        return try JSONDecoder().decode(FixtureState.self, from: data)
    }
}
