import XCTest

/// Opt-in checks against the reader a person already opened on a device: the app is activated as installed, never
/// relaunched, reset or seeded. Attachments hold only Enve's own control labels, counts and durations.
///
/// `TEST_RUNNER_ENVE_READALONG_PHYSICAL=fixture` exercises the seeded public pair on Simulator.
/// `TEST_RUNNER_ENVE_READALONG_PHYSICAL=discover` only reads the visible Listen Along controls.
/// `TEST_RUNNER_ENVE_READALONG_PHYSICAL=exercise` also starts Listen Along, observes its status, pauses and resumes
/// audio that is already playing, and turns Listen Along off again if it started off. Following moves the page to the
/// narrated sentence, as the feature does; play/pause is only used to pause and resume in place, never to start or
/// seek. Stop pauses the linked audiobook like Stop in Read Aloud; the report says when it did.
final class ReadAlongPhysicalUITests: XCTestCase {
    private enum ID {
        static let toggle = "reader.readAlong.toggle"
        static let status = "reader.readAlong.status"
        static let pillStatus = "reader.readAlongPill"
        static let pill = "reader-listen-along-controls"
    }

    private var mode: String? { ProcessInfo.processInfo.environment["ENVE_READALONG_PHYSICAL"] }

    @MainActor
    func testDiscoverReadAlongControls() throws {
        guard mode == "discover" || mode == "exercise" else { throw XCTSkip("Physical Listen Along checks are opt-in") }
        let app = try activateInstalledApp()
        let toggle = app.buttons[ID.toggle]
        let report: [String: Any] = [
            "toggle": toggle.exists,
            "toggleValue": toggle.exists ? (toggle.value as? String ?? "") : "",
            "transport": listenAlongTransport(in: app).exists,
            "transportLabel": listenAlongTransport(in: app).exists ? listenAlongTransport(in: app).label : "",
            "stop": app.buttons["Stop Listen Along"].exists,
            "pill": app.otherElements[ID.pill].exists,
            "hint": app.staticTexts["reader.listenAlong.hint"].exists,
            "status": statusLabel(in: app) ?? "",
        ]
        attach(report, name: "read-along-discovery")
        XCTAssertTrue(
            toggle.exists || app.buttons["Stop Listen Along"].exists || app.otherElements[ID.pill].exists,
            "Open the linked EPUB and show the reader controls first"
        )
    }

    @MainActor
    func testExerciseReadAlongStartPauseAndStatus() throws {
        guard mode == "exercise" else { throw XCTSkip("Physical Listen Along exercise is opt-in") }
        let observeSeconds = min(max(Double(ProcessInfo.processInfo.environment["ENVE_READALONG_OBSERVE_SECONDS"] ?? "") ?? 60, 5), 300)
        let app = try activateInstalledApp()
        let toggle = app.buttons[ID.toggle]
        let stop = app.buttons["Stop Listen Along"]
        revealControls(app, until: toggle)
        guard toggle.exists || stop.exists else { throw XCTSkip("The Listen Along control is not visible; run discover first") }

        let wasOn = !toggle.exists && stop.exists
        var report: [String: Any] = ["initiallyOn": wasOn]
        if !wasOn { toggle.tap() }
        let started = Date()
        var transitions: [[String: Any]] = []
        var last: String?
        while Date().timeIntervalSince(started) < observeSeconds {
            let label = statusLabel(in: app)
            if label != last {
                transitions.append(["at": round(Date().timeIntervalSince(started) * 10) / 10, "status": label ?? ""])
                last = label
            }
            if label == "Listening along" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        report["statusTransitions"] = transitions
        report["listeningAlongAfter"] = last == "Listening along" ? Date().timeIntervalSince(started) : -1

        let transport = listenAlongTransport(in: app)
        revealControls(app, until: transport)
        if transport.exists, transport.label == "Pause Listen Along" {
            let pausedAt = Date()
            transport.tap()
            let paused = waitForLabel(transport, "Play Listen Along", timeout: 10)
            report["pauseSeconds"] = paused ? Date().timeIntervalSince(pausedAt) : -1
            report["statusWhilePaused"] = statusLabel(in: app) ?? ""
            let resumedAt = Date()
            transport.tap()
            let resumed = waitForLabel(transport, "Pause Listen Along", timeout: 10)
            report["resumeSeconds"] = resumed ? Date().timeIntervalSince(resumedAt) : -1
        } else {
            report["pauseSkipped"] = transport.exists ? "audio not playing" : "control hidden"
        }

        if !wasOn {
            revealControls(app, until: stop)
            if stop.exists {
                let wasPlaying = transport.exists && transport.label == "Pause Listen Along"
                stop.tap()
                report["stopPausedAudio"] = wasPlaying
            }
            report["restoredOff"] = toggle.waitForExistence(timeout: 3) && toggle.value as? String == "Off"
        }
        attach(report, name: "read-along-exercise")
    }

    @MainActor
    func testSeededFixtureListenAlongControls() throws {
        let app = try launchSeededFixture()
        let renderer = ProcessInfo.processInfo.environment["ENVE_READER_ENGINE"] ?? "readium"
        let entry = app.buttons[ID.toggle]
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        entry.tap()
        let stop = app.buttons["Stop Listen Along"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Listen Along should expose the shared transport")
        XCTAssertTrue(app.staticTexts["reader.listenAlong.hint"].exists)
        let transport = listenAlongTransport(in: app)
        XCTAssertTrue(transport.exists)
        if transport.label == "Play Listen Along" { transport.tap() }
        XCTAssertTrue(waitForLabel(transport, "Pause Listen Along", timeout: 15))
        let page = app.windows.firstMatch
        let left = page.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.32))
        let right = page.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.32))
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertEqual(transport.label, "Pause Listen Along")
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertEqual(transport.label, "Pause Listen Along")
        transport.tap()
        XCTAssertTrue(waitForLabel(transport, "Play Listen Along", timeout: 5))
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Mira Calloway inherited the lighthouse")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        XCTAssertTrue(paragraph.isHittable)
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.18)).doubleTap()
        XCTAssertTrue(waitForLabel(transport, "Pause Listen Along", timeout: 15))
        transport.tap()
        XCTAssertTrue(waitForLabel(transport, "Play Listen Along", timeout: 5))
        let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Listen Along speed")).firstMatch
        revealControls(app, until: speed)
        XCTAssertTrue(speed.isEnabled)
        speed.tap()
        let faster = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "2x")).firstMatch
        XCTAssertTrue(faster.waitForExistence(timeout: 5))
        faster.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "listen-along-shared-controls-\(renderer)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        speed.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "1x")).firstMatch.tap()
        stop.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(stop.exists)
        app.descendants(matching: .any)["Reader.MoreMenu"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "Read Aloud", "Read Aloud settings")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Read to me")).firstMatch.exists)
        let menuEntry = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Listen Along", ID.toggle)).firstMatch
        XCTAssertTrue(menuEntry.exists)
        menuEntry.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPausedTTSKeepsItsPlaceWhileListenAlongOwnsTheControls() throws {
        let app = try launchSeededFixture()
        app.descendants(matching: .any)["Reader.MoreMenu"].firstMatch.tap()
        app.buttons["Read to me"].firstMatch.tap()
        let sheet = app.descendants(matching: .any)["reader-tts-sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.buttons["Read aloud"].firstMatch.tap()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        pause.tap()
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(
            forDuration: 0.1,
            thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96))
        )
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let resume = app.buttons["Resume reading aloud"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let entry = app.buttons[ID.toggle]
        revealControls(app, until: entry)
        entry.tap()
        let stop = app.buttons["Stop Listen Along"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["reader-tts-controls"].exists)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.descendants(matching: .any)[ID.pill].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["reader-tts-controls"].exists)
        app.buttons["Show Listen Along controls"].firstMatch.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testEmbeddedNarrationUsesSharedControlsWithoutListenAlong() throws {
        guard mode == "fixture" else { throw XCTSkip("Public narrated fixture checks are opt-in") }
        #if !targetEnvironment(simulator)
        throw XCTSkip("The public narrated fixture is for Simulator")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        let renderer = ProcessInfo.processInfo.environment["ENVE_READER_ENGINE"] ?? "readium"
        app.launchArguments = [
            "-imagineScreen", "readerchrome", "-imagineOpenBook", "Enve Narration Controls Fixture",
            "--reader-engine=\(renderer)",
        ]
        app.launch()
        let reader = app.descendants(matching: .any)["reader-screen"]
        if !reader.waitForExistence(timeout: 10) {
            let fixture = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Enve Narration Controls Fixture,")).firstMatch
            XCTAssertTrue(fixture.waitForExistence(timeout: 5))
            fixture.tap()
            let read = app.buttons["Read"].firstMatch
            if !reader.exists, read.waitForExistence(timeout: 5) { read.tap() }
        }
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        let more = app.descendants(matching: .any)["Reader.MoreMenu"].firstMatch
        if !more.waitForExistence(timeout: 2) {
            let expand = app.buttons["Show Read Aloud controls"].firstMatch
            if !expand.exists {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            }
            if expand.waitForExistence(timeout: 3) { expand.tap() }
        }
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let initialStop = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Stop Read Aloud", "Reader.ReadAloud")).firstMatch
        if initialStop.exists {
            initialStop.tap()
            more.tap()
        }
        let start = app.buttons.matching(NSPredicate(format: "label == %@", "Read Aloud")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Read Aloud settings"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Listen Along")).firstMatch.exists)
        start.tap()
        let transport = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Play Read Aloud", "Pause Read Aloud")).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label == "Play Read Aloud" { transport.tap() }
        XCTAssertTrue(waitForLabel(transport, "Pause Read Aloud", timeout: 10))
        transport.tap()
        XCTAssertTrue(waitForLabel(transport, "Play Read Aloud", timeout: 5))
        let expand = app.buttons["Show Read Aloud controls"].firstMatch
        if !expand.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Read Aloud speed")).firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        speed.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "2x")).firstMatch.tap()
        speed.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "1x")).firstMatch.tap()
        app.buttons["Stop Read Aloud"].firstMatch.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(transport.exists)
        #endif
    }

    @MainActor
    private func launchSeededFixture() throws -> XCUIApplication {
        guard mode == "fixture" else { throw XCTSkip("Seeded Listen Along fixture checks are opt-in") }
        #if !targetEnvironment(simulator)
        throw XCTSkip("The seeded public-pair check is for Simulator")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.enve.enve")
        let renderer = ProcessInfo.processInfo.environment["ENVE_READER_ENGINE"] ?? "readium"
        app.launchArguments = [
            "-imagineScreen", "readerchrome",
            "-imagineOpenBook", "The Lantern Keeper (Enve passage fixture)", "--reader-engine=\(renderer)",
        ]
        app.launchArguments += ["-ebookTTS.engine", "apple", "-ebookTTS.rate", "1"]
        app.launch()
        XCTAssertTrue(app.buttons[ID.toggle].waitForExistence(timeout: 30))
        return app
        #endif
    }

    @MainActor
    private func listenAlongTransport(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Play Listen Along", "Pause Listen Along")).firstMatch
    }

    @MainActor
    private func activateInstalledApp() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.enve.enve")
        // Activating a stopped app would launch it fresh, away from the reader under test.
        guard app.state != .notRunning else { throw XCTSkip("Open the linked EPUB in Enve before running this check") }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    /// A centre tap only shows or hides the reader chrome; it is used only when the control is not on screen.
    @MainActor
    private func revealControls(_ app: XCUIApplication, until element: XCUIElement) {
        guard !element.exists || !element.isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = element.waitForExistence(timeout: 3)
    }

    @MainActor
    private func statusLabel(in app: XCUIApplication) -> String? {
        for id in [ID.status, ID.pillStatus] {
            let container = app.otherElements[id]
            if container.exists, let text = container.staticTexts.allElementsBoundByIndex.first?.label { return text }
        }
        return nil
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func attach(_ report: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
