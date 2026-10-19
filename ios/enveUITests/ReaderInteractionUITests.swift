import XCTest

final class ReaderInteractionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLibraryReaderBookmarksAndNotesPersistAfterRestart() throws {
        guard ProcessInfo.processInfo.environment["ENVE_LIBRARY_READER_UI"] == "1" else {
            throw XCTSkip("Requires a dedicated simulator with the imported reader-interaction fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.enve.enve")
        let contentsTray = app.otherElements["reader-contents-tray"].firstMatch
        let suffix = UUID().uuidString.prefix(8)
        let noteText = "Compatibility note \(suffix)"
        let bookmarkTitle = "Compatibility bookmark \(suffix)"
        let bookmarkNote = "Bookmark note \(suffix)"

        openLibraryBook(app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Note"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Note"].firstMatch.tap()
        let noteField = noteInput(in: app, placeholder: "Write something…")
        XCTAssertTrue(noteField.waitForExistence(timeout: 5))
        noteField.tap()
        noteField.typeText(noteText)
        app.buttons["Keep it"].tap()
        XCTAssertTrue(noteField.waitForNonExistence(timeout: 5))
        openContents(app)
        _ = findNote(app, text: noteText)
        clearArtifactSearch(app, text: noteText)
        app.buttons["Bookmarks"].firstMatch.tap()
        app.buttons["Mark this page"].firstMatch.tap()
        let titleField = app.textFields["Title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(bookmarkTitle)
        let bookmarkNoteField = noteInput(in: app, placeholder: "Note")
        XCTAssertTrue(bookmarkNoteField.waitForExistence(timeout: 5))
        bookmarkNoteField.tap()
        bookmarkNoteField.typeText(bookmarkNote)
        app.buttons["Save Bookmark"].firstMatch.tap()
        let bookmarkRow = contentsTray.buttons.matching(NSPredicate(format: "label CONTAINS %@", bookmarkTitle)).firstMatch
        scrollToRow(bookmarkRow, in: contentsTray)
        XCTAssertTrue(contentsTray.staticTexts[bookmarkTitle].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(contentsTray.staticTexts[bookmarkNote].firstMatch.exists)
        app.terminate()

        openLibraryBook(app)
        openContents(app)
        app.buttons["Bookmarks"].firstMatch.tap()
        scrollToRow(bookmarkRow, in: contentsTray)
        XCTAssertTrue(contentsTray.staticTexts[bookmarkTitle].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(contentsTray.staticTexts[bookmarkNote].firstMatch.exists)
        bookmarkRow.tap()
        let trayDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !contentsTray.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [trayDismissed], timeout: 5), .completed)
        closeAndReopenLibraryReader(app)
        openContents(app)
        let savedNote = findNote(app, text: noteText)
        assertRemainsVisible(savedNote, for: 10)
        attachScreenshot(app, name: "library-reader-bookmark-and-note-after-restart")
        clearArtifactSearch(app, text: noteText)
        app.buttons["Bookmarks"].firstMatch.tap()
        scrollToRow(bookmarkRow, in: contentsTray)
        bookmarkRow.swipeLeft()
        contentsTray.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(contentsTray.staticTexts[bookmarkTitle].firstMatch.waitForNonExistence(timeout: 5))
        _ = findNote(app, text: noteText)
        let noteRow = contentsTray.buttons.matching(NSPredicate(format: "label CONTAINS %@", noteText)).firstMatch
        noteRow.swipeLeft()
        contentsTray.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(savedNote.waitForNonExistence(timeout: 5))
        app.terminate()

        openLibraryBook(app)
        openContents(app)
        app.buttons["Bookmarks"].firstMatch.tap()
        let bookmarkSearch = app.textFields["Search bookmarks…"].firstMatch
        bookmarkSearch.tap()
        bookmarkSearch.typeText(bookmarkTitle)
        XCTAssertFalse(contentsTray.staticTexts[bookmarkTitle].firstMatch.exists,
                       "A removed bookmark must stay removed after restarting")
        clearArtifactSearch(app, text: bookmarkTitle)
        app.buttons["Notes"].firstMatch.tap()
        let noteSearch = app.textFields["Search notes…"].firstMatch
        noteSearch.tap()
        noteSearch.typeText(noteText)
        XCTAssertFalse(contentsTray.staticTexts[noteText].firstMatch.exists,
                       "A removed note must stay removed after restarting")
        attachScreenshot(app, name: "reader-deletions-persist-after-restart")
        app.terminate()
    }

    @MainActor
    func testLibraryReaderArtifactEditorsPersistAfterRestart() throws {
        guard ProcessInfo.processInfo.environment["ENVE_LIBRARY_READER_UI"] == "1" else {
            throw XCTSkip("Requires a dedicated simulator with the imported reader-interaction fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.enve.enve")
        let tray = app.otherElements["reader-contents-tray"].firstMatch
        let suffix = UUID().uuidString.prefix(8)
        let note = "Editor note \(suffix)"
        let updatedNote = "\(note) updated"
        let title = "Edit \(suffix)"
        let updatedTitle = "\(title) updated"
        let bookmarkNote = "Edited bookmark note \(suffix)"

        openLibraryBook(app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Note"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Note"].firstMatch.tap()
        let newNote = noteInput(in: app, placeholder: "Write something…")
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        newNote.tap()
        newNote.typeText(note)
        app.buttons["Keep it"].tap()
        XCTAssertTrue(newNote.waitForNonExistence(timeout: 5))
        openContents(app)
        app.buttons["Bookmarks"].firstMatch.tap()
        app.buttons["Mark this page"].firstMatch.tap()
        let titleField = app.textFields["Title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["Save Bookmark"].firstMatch.tap()
        let originalRow = tray.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        scrollToRow(originalRow, in: tray)
        originalRow.tap()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        closeAndReopenLibraryReader(app)
        openContents(app)
        app.buttons["Bookmarks"].firstMatch.tap()
        scrollToRow(originalRow, in: tray)
        originalRow.swipeRight()
        tray.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Update Bookmark"].firstMatch.waitForExistence(timeout: 5))
        appendText(" updated", to: titleField)
        XCTAssertEqual(titleField.value as? String, updatedTitle)
        let bookmarkNoteField = noteInput(in: app, placeholder: "Note")
        bookmarkNoteField.tap()
        bookmarkNoteField.typeText(bookmarkNote)
        app.buttons["Update Bookmark"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Update Bookmark"].firstMatch.waitForNonExistence(timeout: 5))
        let updatedRow = tray.buttons.matching(NSPredicate(format: "label CONTAINS %@", updatedTitle)).firstMatch
        scrollToRow(updatedRow, in: tray)
        XCTAssertTrue(tray.staticTexts[updatedTitle].firstMatch.exists)
        XCTAssertTrue(tray.staticTexts[bookmarkNote].firstMatch.exists)

        _ = findNote(app, text: note)
        let originalNoteRow = tray.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        originalNoteRow.swipeRight()
        tray.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Update Note"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Underline"].firstMatch.tap()
        let editor = app.scrollViews.containing(.button, identifier: "Update Note").firstMatch
        let existingNote = editor.textFields.firstMatch.exists ? editor.textFields.firstMatch : editor.textViews.firstMatch
        appendText(" updated", to: existingNote)
        XCTAssertEqual(existingNote.value as? String, updatedNote)
        let update = app.buttons["Update Note"].firstMatch
        if !update.isHittable { editor.swipeUp() }
        XCTAssertTrue(update.isHittable)
        update.tap()
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tray.staticTexts[updatedNote].firstMatch.waitForExistence(timeout: 5))
        app.terminate()

        openLibraryBook(app)
        openContents(app)
        _ = findNote(app, text: updatedNote)
        let updatedNoteRow = tray.buttons.matching(NSPredicate(format: "label CONTAINS %@", updatedNote)).firstMatch
        XCTAssertTrue(updatedNoteRow.label.contains("Underline"), "The changed annotation style must survive a restart")
        updatedNoteRow.swipeRight()
        tray.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        let remove = app.buttons["Remove"].firstMatch
        if !remove.isHittable { editor.swipeUp() }
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tray.exists, "Removing from the editor must leave Contents open")
        XCTAssertTrue(tray.staticTexts[updatedNote].firstMatch.waitForNonExistence(timeout: 5))
        clearArtifactSearch(app, text: updatedNote)
        app.buttons["Bookmarks"].firstMatch.tap()
        scrollToRow(updatedRow, in: tray)
        XCTAssertTrue(tray.staticTexts[updatedTitle].firstMatch.exists)
        XCTAssertTrue(tray.staticTexts[bookmarkNote].firstMatch.exists)
        updatedRow.swipeLeft()
        tray.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(tray.staticTexts[updatedTitle].firstMatch.waitForNonExistence(timeout: 5))
        assertRemainsVisible(tray, for: 5)
        attachScreenshot(app, name: "reader-editors-updated-and-removed")
        app.terminate()
    }

    @MainActor
    func testLibraryReaderNoteEditorsSurviveBackgroundReturn() throws {
        guard ProcessInfo.processInfo.environment["ENVE_LIBRARY_READER_UI"] == "1" else {
            throw XCTSkip("Requires a dedicated simulator with the imported reader-interaction fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.enve.enve")
        let tray = app.otherElements["reader-contents-tray"].firstMatch
        let suffix = UUID().uuidString.prefix(8)
        let query = "Background note \(suffix)"
        let text = "\(query)\nFirst paragraph wraps across the editor while the keyboard is open.\nSecond paragraph keeps its text when Enve returns from the background.\nLast paragraph remains editable."
        let title = "Background bookmark \(suffix)"

        openLibraryBook(app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Note"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Note"].firstMatch.tap()
        let draft = noteInput(in: app, placeholder: "Write something…")
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText(text)
        backgroundAndResumeEditor(app, text: text)
        app.buttons["Keep it"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Keep it"].firstMatch.waitForNonExistence(timeout: 5))

        openContents(app)
        app.buttons["Notes"].firstMatch.tap()
        let search = app.textFields["Search notes…"].firstMatch
        search.tap()
        search.typeText(query)
        let noteRow = tray.buttons.matching(NSPredicate(format: "label CONTAINS %@", query)).firstMatch
        XCTAssertTrue(noteRow.waitForExistence(timeout: 5))
        noteRow.swipeRight()
        tray.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Update Note"].firstMatch.waitForExistence(timeout: 5))
        let editor = app.scrollViews.containing(.button, identifier: "Update Note").firstMatch
        let saved = editor.textFields.firstMatch.exists ? editor.textFields.firstMatch : editor.textViews.firstMatch
        saved.tap()
        backgroundAndResumeEditor(app, text: "\(text) resumed")
        let removeNote = app.buttons["Remove"].firstMatch
        if !removeNote.isHittable { editor.swipeUp() }
        removeNote.tap()
        XCTAssertTrue(app.buttons["Update Note"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tray.exists)
        XCTAssertTrue(noteRow.waitForNonExistence(timeout: 5))
        clearArtifactSearch(app, text: query)

        app.buttons["Bookmarks"].firstMatch.tap()
        app.buttons["Mark this page"].firstMatch.tap()
        let titleField = app.textFields["Title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let bookmarkNote = noteInput(in: app, placeholder: "Note")
        XCTAssertTrue(bookmarkNote.waitForExistence(timeout: 5))
        bookmarkNote.tap()
        bookmarkNote.typeText(text)
        backgroundAndResumeEditor(app, text: text)
        app.buttons["Save Bookmark"].firstMatch.tap()
        let bookmarkRow = tray.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        scrollToRow(bookmarkRow, in: tray)
        XCTAssertTrue(tray.staticTexts[title].firstMatch.exists)
        bookmarkRow.swipeLeft()
        tray.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(bookmarkRow.waitForNonExistence(timeout: 5))
        assertRemainsVisible(tray, for: 5)
        attachScreenshot(app, name: "reader-note-editors-after-background-and-removal")
        app.terminate()
    }

    @MainActor
    func testLibraryReaderBookmarkDeletion() throws {
        guard ProcessInfo.processInfo.environment["ENVE_LIBRARY_READER_UI"] == "1" else {
            throw XCTSkip("Requires a dedicated simulator with the imported reader-interaction fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.enve.enve")
        let contentsTray = app.otherElements["reader-contents-tray"].firstMatch
        let title = "Deletion check \(UUID().uuidString.prefix(8))"
        openLibraryBook(app)
        openContents(app)
        app.buttons["Bookmarks"].firstMatch.tap()
        app.buttons["Mark this page"].firstMatch.tap()
        let titleField = app.textFields["Title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["Save Bookmark"].firstMatch.tap()
        let row = contentsTray.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        scrollToRow(row, in: contentsTray)
        XCTAssertTrue(contentsTray.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        openLibraryBook(app)
        openContents(app)
        app.buttons["Bookmarks"].firstMatch.tap()
        scrollToRow(row, in: contentsTray)
        row.tap()
        let trayDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !contentsTray.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [trayDismissed], timeout: 5), .completed)
        closeAndReopenLibraryReader(app)
        openContents(app)
        let note = "Compatibility note survives restart."
        _ = findNote(app, text: note)
        clearArtifactSearch(app, text: note)
        app.buttons["Bookmarks"].firstMatch.tap()
        scrollToRow(row, in: contentsTray)
        row.swipeLeft()
        let remove = contentsTray.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(contentsTray.staticTexts[title].firstMatch.waitForNonExistence(timeout: 5))
        attachScreenshot(app, name: "reader-bookmark-removed")
        app.terminate()
    }

    @MainActor
    func testScrolledReadAloudCentersTheNextOffscreenPassage() throws {
        let app = try launchReader(startNarration: false, fixtureName: "reader-centering")
        let window = app.windows.firstMatch
        let appearance = app.buttons["Appearance"].firstMatch
        // Checking `exists` while the opening chrome is fading out races its auto-hide.
        waitForInitialChromeToHide(app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let scrolled = app.buttons["Scrolled"].firstMatch
        for _ in 0..<10 {
            if scrolled.isHittable { break }
            app.scrollViews.containing(.button, identifier: "Paged").firstMatch.swipeUp()
        }
        XCTAssertTrue(scrolled.isHittable)
        scrolled.tap()
        let sheet = app.scrollViews.containing(.button, identifier: "Paged").firstMatch
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(
            forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        XCTAssertTrue(scrolled.waitForNonExistence(timeout: 5))
        let passage = app.webViews.staticTexts["This is the narrated passage that should appear in the middle of the screen."].firstMatch
        // `isHittable` raises "activation point invalid" while the web view is still scrolling under load.
        let passageOnScreen = NSPredicate { _, _ in
            passage.exists && window.frame.contains(CGPoint(x: passage.frame.midX, y: passage.frame.midY))
        }
        XCTAssertFalse(passageOnScreen.evaluate(with: nil))
        let more = app.buttons["More"].firstMatch
        if !more.exists { window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap() }
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let start = app.buttons["Read Aloud"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let followed = XCTNSPredicateExpectation(predicate: passageOnScreen, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 15), .completed)
        XCTAssertEqual(passage.frame.midY, window.frame.midY, accuracy: window.frame.height * 0.15)
        attachScreenshot(app, name: "read-along-followed-passage-centered")
        let stop = app.buttons["Stop Read Aloud"].firstMatch
        if !stop.exists {
            // A center tap hides the pill if its auto-hide window is still open, so open it deterministically.
            showNarrationControls(app)
            app.buttons["Show Read Aloud controls"].firstMatch.tap()
        }
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        if !appearance.exists { window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let paged = app.buttons["Paged"].firstMatch
        for _ in 0..<10 {
            if paged.isHittable { break }
            app.scrollViews.containing(.button, identifier: "Paged").firstMatch.swipeUp()
        }
        XCTAssertTrue(paged.isHittable)
        paged.tap()
        app.terminate()
    }

    @MainActor
    func testScrolledReaderSideTapsMoveOneScreenAndSwipesStayInPlace() throws {
        let app = try launchReader(startNarration: false, fixtureName: "reader-scrolling")
        let window = app.windows.firstMatch
        let appearance = app.buttons["Appearance"].firstMatch
        XCTAssertTrue(app.buttons["Contents"].firstMatch.waitForNonExistence(timeout: 10))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let scrolled = app.buttons["Scrolled"].firstMatch
        for _ in 0..<10 {
            if scrolled.isHittable { break }
            app.scrollViews.containing(.button, identifier: "Paged").firstMatch.swipeUp()
        }
        XCTAssertTrue(scrolled.isHittable)
        scrolled.tap()
        let edgeTaps = app.switches["Tap the edges"].firstMatch
        for _ in 0..<10 {
            if edgeTaps.isHittable { break }
            app.scrollViews.containing(.button, identifier: "Paged").firstMatch.swipeUp()
        }
        XCTAssertTrue(edgeTaps.isHittable)
        let originalEdgeTaps = try XCTUnwrap(edgeTaps.value as? String)
        if originalEdgeTaps == "0" { edgeTaps.tap() }
        let sheet = app.scrollViews.containing(.button, identifier: "Paged").firstMatch
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(
            forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        XCTAssertTrue(scrolled.waitForNonExistence(timeout: 5))
        let first = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Unique first paragraph.")
        ).firstMatch
        XCTAssertTrue(first.isHittable)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)).tap()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45)).tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        let before = first.frame
        app.webViews.firstMatch.swipeLeft()
        app.webViews.firstMatch.swipeRight()
        XCTAssertTrue(first.isHittable)
        XCTAssertEqual(first.frame.minY, before.minY, accuracy: 4)
        attachScreenshot(app, name: "scrolled-reader-side-taps-and-swipes")
        if !appearance.exists { window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let paged = app.buttons["Paged"].firstMatch
        for _ in 0..<10 {
            if paged.isHittable { break }
            app.scrollViews.containing(.button, identifier: "Paged").firstMatch.swipeUp()
        }
        XCTAssertTrue(paged.isHittable)
        paged.tap()
        if originalEdgeTaps == "0" {
            for _ in 0..<10 {
                if edgeTaps.isHittable { break }
                app.scrollViews.containing(.button, identifier: "Paged").firstMatch.swipeUp()
            }
            edgeTaps.tap()
        }
        app.terminate()
    }

    @MainActor
    func testDisabledAudioSkippingDuringPagedNavigation() throws {
        try verifyIndependentReadingNavigation(scrolled: false)
    }

    @MainActor
    func testDisabledAudioSkippingDuringScrolledNavigation() throws {
        try verifyIndependentReadingNavigation(scrolled: true)
    }

    @MainActor
    private func verifyIndependentReadingNavigation(scrolled: Bool) throws {
        // The elapsed-time bound assumes 1x; speed persists across launches and other tests change it.
        let app = try launchReader(startNarration: false, fixtureName: "reader-navigation", arguments: ["-readAloud.speed", "1"])
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["Contents"].firstMatch.waitForNonExistence(timeout: 10))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        app.buttons["Appearance"].firstMatch.tap()
        let mode = app.buttons[scrolled ? "Scrolled" : "Paged"].firstMatch
        let appearanceSheet = app.scrollViews.containing(.button, identifier: "Paged").firstMatch
        for _ in 0..<10 {
            if mode.isHittable { break }
            appearanceSheet.swipeUp()
        }
        XCTAssertTrue(mode.isHittable)
        mode.tap()
        dismissReaderSheet(appearanceSheet, app: app)
        app.buttons["More"].firstMatch.tap()
        app.buttons["Read Aloud settings"].firstMatch.tap()
        let skip = app.switches["Skip audio on page turn"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        let originalSkip = try XCTUnwrap(skip.value as? String)
        if originalSkip == "1" { skip.tap() }
        XCTAssertEqual(skip.value as? String, "0")
        dismissReaderSheet(app.scrollViews.containing(.switch, identifier: "Skip audio on page turn").firstMatch, app: app)
        app.buttons["More"].firstMatch.tap()
        app.buttons["Read Aloud"].firstMatch.tap()
        expandNarration(app)
        let pause = app.buttons["Pause Read Aloud"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        pause.tap()
        XCTAssertTrue(app.buttons["Play Read Aloud"].firstMatch.waitForExistence(timeout: 5))
        let pausedAt = try narrationTime(app)
        for playing in [false, true] {
            if playing {
                app.buttons["Play Read Aloud"].firstMatch.tap()
                XCTAssertTrue(pause.waitForExistence(timeout: 5))
            }
            let started = Date()
            let before = try narrationTime(app)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            let web = app.webViews.firstMatch
            if scrolled { web.swipeUp(); web.swipeDown() }
            else { web.swipeLeft(); web.swipeRight() }
            expandNarration(app)
            openContents(app)
            let two = app.buttons["Two"].firstMatch
            XCTAssertTrue(two.waitForExistence(timeout: 5))
            two.tap()
            XCTAssertTrue(app.otherElements["reader-contents-tray"].firstMatch.waitForNonExistence(timeout: 5))
            let chapter = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chapter two, paragraph 1.")).firstMatch
            XCTAssertTrue(chapter.waitForExistence(timeout: 5))
            expandNarration(app)
            let after = try narrationTime(app)
            if playing {
                XCTAssertGreaterThanOrEqual(after, before - 1)
                XCTAssertLessThanOrEqual(after - before, Date().timeIntervalSince(started) + 3,
                    "Manual chapter navigation must not seek narration to the chapter's 60-second start")
                XCTAssertTrue(pause.exists)
            } else { XCTAssertEqual(after, pausedAt, accuracy: 1) }
            openContents(app)
            app.buttons["One"].firstMatch.tap()
            XCTAssertTrue(app.otherElements["reader-contents-tray"].firstMatch.waitForNonExistence(timeout: 5))
            expandNarration(app)
            if !playing { XCTAssertEqual(try narrationTime(app), pausedAt, accuracy: 1) }
        }
        app.buttons["Read Aloud settings"].firstMatch.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertEqual(skip.value as? String, "1")
        dismissReaderSheet(app.scrollViews.containing(.switch, identifier: "Skip audio on page turn").firstMatch, app: app)
        openContents(app)
        app.buttons["Two"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["reader-contents-tray"].firstMatch.waitForNonExistence(timeout: 5))
        expandNarration(app)
        let audioFollowed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((try? self.narrationTime(app)) ?? 0) >= 60
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [audioFollowed], timeout: 10), .completed)
        pause.tap()
        app.buttons["Read Aloud settings"].firstMatch.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        if (skip.value as? String) != originalSkip { skip.tap() }
        dismissReaderSheet(app.scrollViews.containing(.switch, identifier: "Skip audio on page turn").firstMatch, app: app)
        app.buttons["Stop Read Aloud"].firstMatch.tap()
        attachScreenshot(app, name: "independent-reading-\(scrolled ? "scrolled" : "paged")")
        if scrolled {
            app.buttons["Appearance"].firstMatch.tap()
            for _ in 0..<10 {
                if app.buttons["Paged"].firstMatch.isHittable { break }
                appearanceSheet.swipeUp()
            }
            app.buttons["Paged"].firstMatch.tap()
        }
        app.terminate()
    }

    @MainActor
    private func expandNarration(_ app: XCUIApplication) {
        if app.descendants(matching: .any)["Read Aloud position"].firstMatch.exists { return }
        let expand = app.buttons["Show Read Aloud controls"].firstMatch
        if !expand.exists { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap() }
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Read Aloud position"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func narrationTime(_ app: XCUIApplication) throws -> TimeInterval {
        let position = app.descendants(matching: .any)["Read Aloud position"].firstMatch
        let value = try XCTUnwrap(position.value as? String)
        let parts = value.components(separatedBy: " elapsed")[0].split(separator: ":")
        return try parts.reduce(0) { try $0 * 60 + XCTUnwrap(Double($1)) }
    }

    @MainActor
    private func dismissReaderSheet(_ sheet: XCUIElement, app: XCUIApplication) {
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(
            forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
    }

    @MainActor
    func testReadAloudPageTurnPreferencePersistsAfterReopening() throws {
        let app = try launchReader(startNarration: false)
        XCTAssertTrue(app.buttons["Contents"].firstMatch.waitForNonExistence(timeout: 10))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let settings = app.buttons["Read Aloud settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let skip = app.switches["Skip audio on page turn"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(skip.value as? String)
        skip.tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", original), object: skip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "A normal tap must change the page-turn audio preference")
        let updated = try XCTUnwrap(skip.value as? String)
        let sheet = app.scrollViews.containing(.switch, identifier: "Skip audio on page turn").firstMatch
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(
            forDuration: 0.1,
            thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96))
        )
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        XCTAssertEqual(skip.value as? String, updated)
        skip.tap()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", original), object: skip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        attachScreenshot(app, name: "reader-page-turn-audio-preference-restored")
        app.terminate()
    }

    @MainActor
    func testContentsOpensAfterSavingANote() throws {
        let app = try launchReader(startNarration: false)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        let note = app.buttons["Note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        let field = noteInput(in: app, placeholder: "Write something…")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Compatibility note survives restart.")
        app.buttons["Keep it"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        openContents(app)
        app.buttons["Notes"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Compatibility note survives restart."].firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "reader-saved-note-in-contents")
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

        let passage = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Edge selection remains on this page")
        ).firstMatch
        passage.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1)
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
    func testPausedTextToSpeechControlsStayAvailable() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reader-interaction", withExtension: "epub"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = [
            "-imagineScreen", "footnotefixture",
            "-imagineFixture", "reader-tts-\(UUID().uuidString).epub",
            "--exercise-tts-play",
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 30))

        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let pause = app.buttons["Pause reading aloud"].firstMatch
        if !pause.waitForExistence(timeout: 20) {
            center.tap()
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()

        let resume = app.buttons["Resume reading aloud"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        assertRemainsVisible(resume, for: 5)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
    }

    @MainActor
    func testRapidReadAloudSpeedChangesKeepReaderOpen() throws {
        let app = try launchReader(startNarration: true)
        showNarrationControls(app)
        app.buttons["Show Read Aloud controls"].firstMatch.tap()

        let speed = app.buttons["Read Aloud speed"].firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        for rate in ["1.25x", "2x", "0.75x", "1.5x", "1x"] {
            speed.tap()
            let choice = app.buttons[rate].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].exists)
        }

        XCTAssertTrue(app.buttons["Pause Read Aloud"].firstMatch.waitForExistence(timeout: 5))
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
        let app = try launchReader(startNarration: false, fixtureName: "reader-selection-follow")
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
    func testAnnotationToolbarControlsMeetMinimumTouchTarget() throws {
        let app = try launchReader(startNarration: false)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        let toolbar = app.descendants(matching: .any)["reader-annotation-toolbar"].firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        let labels = ["Yellow highlight", "Highlight colors", "Note", "Copy", "Define", "More annotation styles"]
        var frames: [CGRect] = []
        for label in labels {
            let control = toolbar.descendants(matching: .any)[label].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(label) is missing")
            // Accessibility frames carry sub-point rounding error from the pill's centered position.
            XCTAssertGreaterThanOrEqual(control.frame.width.rounded(), 44, "\(label) is narrower than 44 pt")
            XCTAssertGreaterThanOrEqual(control.frame.height.rounded(), 44, "\(label) is shorter than 44 pt")
            frames.append(control.frame)
        }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "Annotation controls overlap")
            }
        }
    }

    @MainActor
    func testReadiumNoteReferencesOpenTheFootnoteSheet() throws {
        let app = try launchReader(startNarration: false, fixtureName: "reader-footnotes")
        waitForInitialChromeToHide(app)

        for (reference, body) in [("[1]", "Role footnote body text."), ("[2]", "Endnote body text.")] {
            let link = app.webViews.links[reference].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 10), "\(reference) link is missing")
            link.tap()
            let note = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", body)).firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 10), "\(reference) did not open as a footnote")
            attachScreenshot(app, name: "readium-footnote-\(reference)")
            app.navigationBars.buttons.matching(NSPredicate(format: "label ==[c] %@", "close")).firstMatch.tap()
            XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        }
        XCTAssertFalse(app.buttons["Back to reading"].exists, "A footnote must not leave the reading position")
    }

    @MainActor
    func testReadiumInternalLinkOffersBackToReading() throws {
        try verifyInternalLinkReturn(arguments: [])
    }

    @MainActor
    func testFoliateNoteReferenceAndInternalLinkKeepAWayBack() throws {
        let app = try launchReader(startNarration: false, fixtureName: "reader-footnotes", arguments: ["--reader-engine=foliate"])
        waitForInitialChromeToHide(app)
        let link = app.webViews.links["[1]"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let close = app.webViews.buttons["Close footnote"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The note popup needs an accessible close button")
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertFalse(
            app.descendants(matching: .any)["reader-progress-slider"].waitForExistence(timeout: 1.5),
            "Tapping a note reference must not also toggle the reader chrome"
        )
        attachScreenshot(app, name: "foliate-footnote")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.terminate()
        try verifyInternalLinkReturn(arguments: ["--reader-engine=foliate"])
    }

    @MainActor
    func testFoliateOpenDyslexicOverridesPublisherFonts() throws {
        let app = try launchReader(
            startNarration: false,
            fixtureName: "reader-footnotes",
            arguments: ["--reader-engine=foliate", "--probe-reader-font"]
        )
        let probe = app.descendants(matching: .any)["reader-font-probe"].firstMatch
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND NOT (label == %@)", "pending"),
            object: probe
        )
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed)
        let result = probe.label
        let components = result.split(separator: "|", omittingEmptySubsequences: false)
        XCTAssertEqual(components.count, 2, result)
        let family = components.first.map { $0.replacingOccurrences(of: "\"", with: "") }
        XCTAssertTrue(family?.hasPrefix("Enve OpenDyslexic,") == true, "Publisher inline font won: \(result)")
        XCTAssertTrue(components.last?.contains("loaded") == true, "The bundled OpenDyslexic face did not load: \(result)")
    }

    @MainActor
    func testTogglingChromeDoesNotReflowReadiumPage() throws {
        let app = try launchReader(startNarration: false)
        waitForInitialChromeToHide(app)
        let passage = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Edge selection remains on this page")
        ).firstMatch
        let restingTop = passage.frame.minY
        attachScreenshot(app, name: "chrome-hidden-before")
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let progress = app.descendants(matching: .any)["reader-progress-slider"].firstMatch
        center.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(app, name: "chrome-shown")
        XCTAssertEqual(passage.frame.minY, restingTop, accuracy: 1, "Showing chrome reflowed the page")
        center.tap()
        XCTAssertTrue(progress.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(passage.frame.minY, restingTop, accuracy: 1, "Hiding chrome reflowed the page")
    }

    @MainActor
    private func verifyInternalLinkReturn(arguments: [String]) throws {
        let app = try launchReader(startNarration: false, fixtureName: "reader-footnotes", arguments: arguments)
        waitForInitialChromeToHide(app)
        let jump = app.webViews.links["Jump to the appendix"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        jump.tap()
        let destination = app.webViews.staticTexts["Appendix destination text."].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10), "The internal link did not navigate")
        let back = app.buttons["Back to reading"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Internal links need a way back to the reading position")
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        attachScreenshot(app, name: "internal-link-back-to-reading")
        back.tap()
        let passage = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Edge selection remains on this page")
        ).firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: passage)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed, "Back to reading did not return")
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func waitForInitialChromeToHide(_ app: XCUIApplication) {
        let progress = app.descendants(matching: .any)["reader-progress-slider"].firstMatch
        if progress.exists {
            XCTAssertTrue(progress.waitForNonExistence(timeout: 10))
        }
    }

    @MainActor
    private func openLibraryBook(_ app: XCUIApplication) {
        app.launchArguments = ["-imagineScreen", "library"]
        app.launch()
        let libraryTab = app.buttons["tab_library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        libraryTab.tap()
        let library = app.scrollViews["library-screen"].firstMatch
        let book = library.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reader Interaction Regression")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        visibleReadButton(in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 30))
        let passage = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Edge selection remains on this page")
        ).firstMatch
        XCTAssertTrue(passage.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Contents"].firstMatch.waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func scrollToRow(_ row: XCUIElement, in tray: XCUIElement) {
        for _ in 0..<6 {
            if row.exists, !row.frame.isEmpty, row.isHittable { break }
            tray.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "The saved row must be visible before swiping")
    }

    @MainActor
    private func backgroundAndResumeEditor(_ app: XCUIApplication, text: String) {
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", text)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.state == .notRunning }, object: nil
        )
        stopped.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 6), .completed)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, text)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(" resumed")
        let updated = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@", "\(text) resumed")
        ).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
    }

    @MainActor
    private func appendText(_ text: String, to field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(text)
    }

    @MainActor
    private func noteInput(in app: XCUIApplication, placeholder: String) -> XCUIElement {
        let field = app.textFields[placeholder].firstMatch
        if field.waitForExistence(timeout: 1) { return field }
        return app.textViews.firstMatch
    }

    @MainActor
    private func visibleReadButton(in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: "Read")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            buttons.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        return buttons.allElementsBoundByIndex.first { $0.isHittable } ?? buttons.firstMatch
    }

    @MainActor
    private func closeAndReopenLibraryReader(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if !close.isHittable {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        visibleReadButton(in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Contents"].firstMatch.waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func openContents(_ app: XCUIApplication) {
        let contents = app.buttons["Contents"].firstMatch
        if !contents.isHittable {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let shown = contents.waitForExistence(timeout: 5)
        if !shown { attachScreenshot(app, name: "reader-contents-unavailable") }
        XCTAssertTrue(shown)
        contents.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader-contents-tray"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func findNote(_ app: XCUIApplication, text: String) -> XCUIElement {
        app.buttons["Notes"].firstMatch.tap()
        let search = app.textFields["Search notes…"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(text)
        let note = app.otherElements["reader-contents-tray"].firstMatch.staticTexts[text].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        return note
    }

    @MainActor
    private func clearArtifactSearch(_ app: XCUIApplication, text: String) {
        let search = app.otherElements["reader-contents-tray"].firstMatch.textFields.firstMatch
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    @MainActor
    private func launchReader(
        startNarration: Bool,
        fixtureName: String = "reader-interaction",
        arguments: [String] = []
    ) throws -> XCUIApplication {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixtureName, withExtension: "epub"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = [
            "-imagineScreen", "footnotefixture",
            "-imagineFixture", "reader-interaction-\(UUID().uuidString).epub",
        ] + (startNarration ? ["--exercise-read-aloud"] : []) + arguments
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
