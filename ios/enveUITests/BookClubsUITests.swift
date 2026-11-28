import XCTest

final class BookClubsUITests: XCTestCase {
    @MainActor
    func testMemberDownloadsAndOpensHostedEbook() async throws {
        try await exerciseHostedCopy(sourceVariable: "ENVE_CLUBS_UI_TEST_HOSTED_SOURCE", format: "ebook")
    }

    @MainActor
    func testMemberDownloadsHostedAudiobook() async throws {
        try await exerciseHostedCopy(sourceVariable: "ENVE_CLUBS_UI_TEST_AUDIO_SOURCE", format: "audiobook")
    }

    @MainActor
    private func exerciseHostedCopy(sourceVariable: String, format: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["ENVE_CLUBS_UI_TEST_URL"], endpoint == "http://127.0.0.1:8794",
              let source = environment[sourceVariable] else {
            throw XCTSkip("Requires the local Book Clubs server with a hosted copy fixture")
        }
        continueAfterFailure = false
        let host = try await send(endpoint, "accounts", method: "POST", body: ["name": "Fixture Host"])
        let token = try XCTUnwrap(host["token"] as? String)
        let name = "Hosted Readers " + UUID().uuidString.prefix(6)
        let created = try await send(endpoint, "clubs", method: "POST", token: token, body: [
            "name": name,
            "read": ["title": "Hosted Club Fixture", "checkpoints": []],
        ])
        let club = "clubs/" + (try XCTUnwrap(created["id"] as? String))
        let details = try await send(endpoint, club, token: token)
        let reads = try XCTUnwrap(details["reads"] as? [[String: Any]])
        let read = club + "/reads/" + (try XCTUnwrap(reads.first?["id"] as? String))
        let catalog = try await send(endpoint, club + "/catalog/" + source, token: token)
        let publications = try XCTUnwrap(catalog["publications"] as? [[String: Any]])
        let publication = try XCTUnwrap(publications.first?["id"] as? String)
        _ = try await send(endpoint, read + "/copy", method: "POST", token: token, body: [
            "sourceID": source, "publicationID": publication, "format": format,
        ])
        var copy: [String: Any]?
        for _ in 0..<80 {
            let status = try await send(endpoint, read + "/copy", token: token)
            copy = status["copy"] as? [String: Any]
            if copy != nil { break }
            XCTAssertNil(status["error"] as? String)
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertNotNil(copy)
        let invitation = try await send(endpoint, club + "/invite", method: "POST", token: token)
        let code = try XCTUnwrap(invitation["code"] as? String)

        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launchEnvironment["ENVE_CLUBS_SERVICE_URL"] = endpoint
        app.launch()
        let more = app.buttons["library-more-menu"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        app.buttons["Book Clubs"].tap()
        let profileName = app.textFields["clubs-display-name"]
        if profileName.waitForExistence(timeout: 5) {
            profileName.tap()
            profileName.typeText("Hosted Reader")
            app.buttons["Create Clubs Profile"].tap()
        }
        XCTAssertTrue(app.buttons["clubs-join"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        app.open(try XCTUnwrap(URL(string: "enve-book://club/join?code=" + code)))
        let join = app.buttons["clubs-join-confirm"]
        if !join.waitForExistence(timeout: 3) {
            let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
            if open.exists { open.tap() }
        }
        XCTAssertTrue(join.waitForExistence(timeout: 12))
        join.tap()
        let download = app.buttons["clubs-download-copy"]
        XCTAssertTrue(download.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Choose My Copy"].exists)
        download.tap()
        let continueBook = app.buttons[format == "ebook" ? "Continue Reading" : "Continue Listening"]
        XCTAssertTrue(continueBook.waitForExistence(timeout: 40), app.debugDescription)
        if format == "ebook" {
            continueBook.tap()
            XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].firstMatch.waitForExistence(timeout: 25))
        }
        _ = try await send(endpoint, club, method: "DELETE", token: token)
        _ = try await send(endpoint, "me", method: "DELETE", token: token)
    }

    @MainActor
    func testMemberJoinsChecksInAndDiscussesWithAnotherAccount() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_CLUBS_UI_TEST_URL"],
              endpoint == "http://127.0.0.1:8794" else { throw XCTSkip("Requires the local Book Clubs worker") }
        continueAfterFailure = false
        let host = try await send(endpoint, "accounts", method: "POST", body: ["name": "Club Host"])
        let token = try XCTUnwrap(host["token"] as? String)
        let clubName = "Evening Readers " + UUID().uuidString.prefix(6)
        let created = try await send(endpoint, "clubs", method: "POST", token: token, body: [
            "name": clubName,
            "read": ["title": "Hyperion", "author": "Dan Simmons", "checkpoints": [["label": "Chapter 3", "trackPosition": 0.4]]],
        ])
        let club = "clubs/" + (try XCTUnwrap(created["id"] as? String))
        let details = try await send(endpoint, club, token: token)
        let reads = try XCTUnwrap(details["reads"] as? [[String: Any]])
        let read = club + "/reads/" + (try XCTUnwrap(reads.first?["id"] as? String))
        let plan = try await send(endpoint, read, token: token)
        let checkpoints = try XCTUnwrap(plan["checkpoints"] as? [[String: Any]])
        let checkpoint = try XCTUnwrap(checkpoints.first?["id"] as? String)
        let thread = read + "/threads/" + checkpoint
        _ = try await send(endpoint, thread, method: "POST", token: token, body: ["body": "The host’s chapter thoughts"])
        let invitation = try await send(endpoint, club + "/invite", method: "POST", token: token)
        let code = try XCTUnwrap(invitation["code"] as? String)

        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launchEnvironment["ENVE_CLUBS_SERVICE_URL"] = endpoint
        app.launch()
        XCTAssertTrue(app.buttons["library-more-menu"].waitForExistence(timeout: 30))
        app.buttons["library-more-menu"].tap()
        app.buttons["Book Clubs"].tap()
        let name = app.textFields["clubs-display-name"]
        if name.waitForExistence(timeout: 4) {
            name.tap()
            name.typeText("Guest Reader")
            app.buttons["Create Clubs Profile"].tap()
        }
        let join = app.buttons["clubs-join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        join.tap()
        let input = app.textFields["clubs-invite-code"]
        let displayName = app.textFields["clubs-join-display-name"]
        let confirmJoin = app.buttons["clubs-join-confirm"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let profileName = try XCTUnwrap(displayName.value as? String)
        XCTAssertFalse(profileName.isEmpty)
        XCTAssertNotEqual(profileName, "Display name")
        XCTAssertFalse(confirmJoin.isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        let invitationURL = try XCTUnwrap(URL(string: "enve-book://club/join?code=" + code))
        app.open(invitationURL)
        if !input.waitForExistence(timeout: 3) {
            let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
            if open.exists { open.tap() }
        }
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, code)
        XCTAssertEqual(displayName.value as? String, profileName)
        displayName.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        displayName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: profileName.count))
        XCTAssertFalse(confirmJoin.isEnabled)
        displayName.typeText("Night Owl")
        let keyboardReturn = app.keyboards.buttons["Return"]
        if keyboardReturn.exists { keyboardReturn.tap() }
        let joinScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        joinScreen.name = "Book Clubs join with a display name"
        joinScreen.lifetime = .keepAlways
        add(joinScreen)
        confirmJoin.tap()
        XCTAssertTrue(app.navigationBars[String(clubName)].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Hyperion"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The Track"].waitForExistence(timeout: 10))
        let joinedClub = try await send(endpoint, club, token: token)
        let members = try XCTUnwrap(joinedClub["members"] as? [[String: Any]])
        XCTAssertTrue(members.contains { $0["name"] as? String == "Night Owl" }, "The host should see the member's club display name")

        let discuss = app.buttons["Discuss Chapter 3"]
        for _ in 0..<6 where !discuss.isHittable { app.swipeUp() }
        XCTAssertTrue(discuss.isHittable)
        discuss.tap()
        XCTAssertTrue(app.buttons["clubs-reveal-spoilers"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["The host’s chapter thoughts"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let checkIn = app.buttons["Mark Chapter 3 complete"]
        for _ in 0..<5 where !checkIn.isHittable { app.swipeUp() }
        XCTAssertTrue(checkIn.isHittable)
        checkIn.tap()
        let confirm = app.buttons["Confirm Check-in"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Reached Chapter 3"].firstMatch.waitForExistence(timeout: 12))
        for _ in 0..<5 where !discuss.isHittable { app.swipeUp() }
        discuss.tap()
        XCTAssertTrue(app.staticTexts["The host’s chapter thoughts"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["clubs-reveal-spoilers"].exists)
        app.buttons["clubs-write-post"].tap()
        let post = app.textViews["clubs-post-body"].firstMatch
        let field = post.exists ? post : app.textFields["clubs-post-body"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("Looking forward to the next chapter")
        app.buttons["clubs-post-confirm"].tap()
        XCTAssertTrue(app.staticTexts["Looking forward to the next chapter"].waitForExistence(timeout: 12))
        let returned = try await send(endpoint, thread, token: token)
        let posts = try XCTUnwrap(returned["posts"] as? [[String: Any]])
        XCTAssertTrue(posts.contains { $0["body"] as? String == "Looking forward to the next chapter" && $0["authorName"] as? String == "Night Owl" })
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "Book Clubs checkpoint thread with posts from two accounts"
        shown.lifetime = .keepAlways
        add(shown)
        _ = try await send(endpoint, club, method: "DELETE", token: token)
        _ = try await send(endpoint, "me", method: "DELETE", token: token)
    }

    @MainActor
    func testHearthShowsBothJoinedClubsAndOpensTheirDiscussion() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ENVE_CLUBS_UI_TEST_URL"],
              endpoint == "http://127.0.0.1:8794" else { throw XCTSkip("Requires the local Book Clubs server") }
        continueAfterFailure = false
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }

        let host = try await send(endpoint, "accounts", method: "POST", body: ["name": "Hearth Host"])
        let token = try XCTUnwrap(host["token"] as? String)
        let prompt = "What drew you into this story?"
        let spoiler = "The last letter is from the narrator."
        var clubs: [(id: String, name: String, code: String, title: String)] = []
        var spoilerID = ""
        var firstRead = ""
        var chapterPostID = ""
        let chapter = "Chapter 6"
        let chapterSpoiler = "The hidden door opens at sunrise."
        let dueAt = Int(Date.now.addingTimeInterval(3 * 86_400).timeIntervalSince1970 * 1000)
        for (name, title) in [("Morning Readers", "The Left Hand of Darkness"), ("Evening Readers", "The Dispossessed")] {
            let created = try await send(endpoint, "clubs", method: "POST", token: token, body: [
                "name": name, "read": ["title": title, "author": "Ursula K. Le Guin",
                                      "checkpoints": clubs.isEmpty ? [] : [["label": chapter, "dueAt": dueAt]]],
            ])
            let id = try XCTUnwrap(created["id"] as? String)
            let base = "clubs/" + id
            let invitation = try await send(endpoint, base + "/invite", method: "POST", token: token)
            let code = try XCTUnwrap(invitation["code"] as? String)
            let details = try await send(endpoint, base, token: token)
            let reads = try XCTUnwrap(details["reads"] as? [[String: Any]])
            let reading = base + "/reads/" + (try XCTUnwrap(reads.first?["id"] as? String))
            if clubs.isEmpty {
                firstRead = reading
                let thread = firstRead + "/threads/general"
                _ = try await send(endpoint, thread + "/prompt", method: "PUT", token: token, body: ["body": prompt])
                let post = try await send(endpoint, thread, method: "POST", token: token, body: ["body": spoiler, "isSpoiler": true])
                spoilerID = try XCTUnwrap(post["id"] as? String)
            } else {
                let plan = try await send(endpoint, reading, token: token)
                let checkpoints = try XCTUnwrap(plan["checkpoints"] as? [[String: Any]])
                let checkpointID = try XCTUnwrap(checkpoints.first?["id"] as? String)
                let post = try await send(endpoint, reading + "/threads/" + checkpointID, method: "POST", token: token,
                                          body: ["body": chapterSpoiler, "isSpoiler": true])
                chapterPostID = try XCTUnwrap(post["id"] as? String)
            }
            clubs.append((id, name, code, title))
        }

        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "library"]
        app.launchEnvironment["ENVE_CLUBS_SERVICE_URL"] = endpoint
        app.launch()
        let more = app.buttons["library-more-menu"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        app.buttons["Book Clubs"].tap()
        let name = app.textFields["clubs-display-name"]
        if name.waitForExistence(timeout: 5) {
            name.tap()
            name.typeText("Hearth Reader")
            app.buttons["Create Clubs Profile"].tap()
        }
        XCTAssertTrue(app.buttons["clubs-join"].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        for club in clubs {
            app.open(try XCTUnwrap(URL(string: "enve-book://club/join?code=" + club.code)))
            let confirm = app.buttons["clubs-join-confirm"]
            if !confirm.waitForExistence(timeout: 3) {
                let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
                if open.exists { open.tap() }
            }
            XCTAssertTrue(confirm.waitForExistence(timeout: 12))
            confirm.tap()
            let navigation = app.navigationBars[club.name]
            XCTAssertTrue(navigation.waitForExistence(timeout: 15))
            navigation.buttons["Book Clubs"].tap()
            app.buttons["Done"].tap()
        }
        app.buttons["tab_hearth"].tap()

        func scrollToHearthItem(_ item: XCUIElement) {
            let visibleArea = app.frame.insetBy(dx: 0, dy: 90)
            for _ in 0..<6 {
                let frame = item.frame
                if item.isHittable, visibleArea.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
                let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.4))
                let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.72))
                if !frame.isEmpty, frame.midY < visibleArea.minY {
                    upper.press(forDuration: 0.08, thenDragTo: lower)
                } else {
                    lower.press(forDuration: 0.08, thenDragTo: upper)
                }
            }
            XCTFail("Hearth item did not scroll into view.")
        }

        let morning = app.buttons["clubs-hearth-book-" + clubs[0].id]
        let evening = app.buttons["clubs-hearth-book-" + clubs[1].id]
        XCTAssertTrue(morning.waitForExistence(timeout: 15))
        XCTAssertTrue(evening.exists)
        XCTAssertTrue(morning.label.contains(clubs[0].title) && morning.label.contains(clubs[0].name))
        XCTAssertTrue(evening.label.contains(clubs[1].title) && evening.label.contains(clubs[1].name))
        XCTAssertTrue(evening.label.contains(chapter) && evening.label.contains("Due"))
        scrollToHearthItem(morning)
        capture("Enve Hearth with current books from two clubs")
        morning.tap()

        XCTAssertTrue(app.navigationBars[clubs[0].name].waitForExistence(timeout: 12))
        let discussion = app.buttons["General Discussion"]
        for _ in 0..<6 where !discussion.isHittable { app.swipeUp() }
        XCTAssertTrue(discussion.isHittable)
        capture("Club reading plan from the Hearth")
        discussion.tap()
        XCTAssertTrue(app.staticTexts[prompt].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts[spoiler].exists)
        app.buttons["clubs-reveal-post-" + spoilerID].tap()
        XCTAssertTrue(app.staticTexts[spoiler].waitForExistence(timeout: 12))
        capture("Club discussion with pinned prompt and a revealed spoiler")
        app.buttons["clubs-hide-post-" + spoilerID].tap()
        XCTAssertFalse(app.staticTexts[spoiler].exists)

        app.navigationBars["General Discussion"].buttons.firstMatch.tap()
        let notes = app.buttons["clubs-reading-notes"]
        for _ in 0..<6 where !notes.isHittable { app.swipeUp() }
        XCTAssertTrue(notes.isHittable)
        notes.tap()
        let addNote = app.buttons["clubs-add-note"]
        XCTAssertTrue(addNote.waitForExistence(timeout: 8))
        addNote.tap()
        XCTAssertTrue(app.staticTexts["Only you can see this note."].waitForExistence(timeout: 8))
        let note = app.textFields["clubs-note-body"]
        let draft = "The opening is worth a reread."
        note.tap()
        note.typeText(draft)
        app.buttons["clubs-note-save"].tap()
        XCTAssertTrue(app.staticTexts[draft].waitForExistence(timeout: 8))
        let hostNotes = try await send(endpoint, firstRead + "/notes", token: token)
        XCTAssertTrue(try XCTUnwrap(hostNotes["notes"] as? [[String: Any]]).isEmpty)
        capture("Private reading note in the club")

        app.navigationBars["Reading Notes"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        let allClubs = app.buttons["All clubs"]
        scrollToHearthItem(allClubs)
        allClubs.tap()
        let feed = app.buttons["clubs-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 12))
        feed.tap()
        let morningActivity = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "started " + clubs[0].title)).firstMatch
        let eveningActivity = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "started " + clubs[1].title)).firstMatch
        XCTAssertTrue(morningActivity.waitForExistence(timeout: 12))
        XCTAssertTrue(eveningActivity.exists)
        XCTAssertFalse(app.staticTexts[draft].exists)
        capture("Club feed with both memberships")
        let chapterEvent = app.buttons["clubs-feed-event-" + chapterPostID]
        XCTAssertTrue(chapterEvent.waitForExistence(timeout: 8))
        chapterEvent.tap()
        XCTAssertTrue(app.navigationBars[chapter].waitForExistence(timeout: 12))
        let revealThread = app.buttons["clubs-reveal-spoilers"]
        XCTAssertTrue(revealThread.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts[chapterSpoiler].exists)
        revealThread.tap()
        XCTAssertTrue(app.staticTexts["From Club Feed"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts[chapterSpoiler].exists)
        let revealPost = app.buttons["clubs-reveal-post-" + chapterPostID]
        XCTAssertTrue(revealPost.waitForExistence(timeout: 8))
        revealPost.tap()
        XCTAssertTrue(app.staticTexts[chapterSpoiler].waitForExistence(timeout: 12))
        capture("Checkpoint discussion opened from the Club Feed")
        app.navigationBars[chapter].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[clubs[1].name].waitForExistence(timeout: 12))

        for club in clubs {
            _ = try await send(endpoint, "clubs/" + club.id, method: "DELETE", token: token)
        }
        _ = try await send(endpoint, "me", method: "DELETE", token: token)
    }

    private func send(_ endpoint: String, _ path: String, method: String = "GET", token: String? = nil,
                      body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: endpoint + "/v1/" + path)),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertTrue((200..<300).contains(status), "\(method) returned \(status)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
