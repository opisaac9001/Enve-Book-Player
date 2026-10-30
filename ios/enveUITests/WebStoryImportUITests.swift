import Network
import XCTest

final class WebStoryImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWholeStoryImportsAndOpensInTheReader() async throws {
        let title = "Web Story \(UUID().uuidString.prefix(8))"
        let server = try WebStoryFixtureServer(title: title)
        let url = try await server.start()
        defer { server.stop() }
        let app = launchImport()
        app.textFields["web-import-url"].tap()
        app.textFields["web-import-url"].typeText(url.absoluteString + "\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 chapters found")).firstMatch.waitForExistence(timeout: 20))
        let confirm = app.buttons["web-import-confirm"].firstMatch
        reveal(confirm, in: app)
        XCTAssertEqual(confirm.label, "Import 2 chapters")
        record(app, name: "Web story preview and chapter selection")
        confirm.tap()
        let success = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 book added to your library.")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 45))
        let done = app.buttons["Done"].firstMatch
        reveal(done, in: app)
        done.tap()

        openBook(named: title, in: app)
        let contents = app.buttons["Contents"].firstMatch
        if !contents.isHittable {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        contents.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "The observatory")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "The atlas")).firstMatch.exists)
        record(app, name: "Imported web story in reader contents")
    }

    @MainActor
    func testBrowserCanPreviewCurrentChapterAndNavigateBack() async throws {
        let server = try WebStoryFixtureServer(title: "Browser Story")
        let url = try await server.start()
        defer { server.stop() }
        let app = launchImport(mode: "paper")
        let field = app.textFields["web-import-url"]
        field.tap()
        field.typeText(url.absoluteString)
        app.buttons["web-import-browser"].tap()
        let link = app.webViews.links["The atlas"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        let back = app.buttons["web-import-browser-back"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        back.tap()
        XCTAssertTrue(app.webViews.links["The atlas"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["web-import-browser-forward"].tap()
        XCTAssertTrue(app.webViews.staticTexts["The atlas"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["web-import-browser-page"].tap()
        let confirm = app.buttons["web-import-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        reveal(confirm, in: app)
        XCTAssertEqual(confirm.label, "Import 1 chapter")
        XCTAssertTrue(app.staticTexts["Starts at “The atlas”"].exists)
        record(app, name: "Browser chapter import preview in Paper")
    }

    @MainActor
    func testLiveRoyalRoadChapterImport() throws {
        guard let address = ProcessInfo.processInfo.environment["ENVE_WEB_IMPORT_LIVE_URL"] else {
            throw XCTSkip("Set ENVE_WEB_IMPORT_LIVE_URL to exercise the live Royal Road example.")
        }
        let app = launchImport()
        let field = app.textFields["web-import-url"]
        field.tap()
        field.typeText(address + "\n")
        let chapterCount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "chapters found")).firstMatch
        XCTAssertTrue(chapterCount.waitForExistence(timeout: 45))
        if let expected = ProcessInfo.processInfo.environment["ENVE_WEB_IMPORT_LIVE_CHAPTER_COUNT"] {
            XCTAssertEqual(chapterCount.label, "\(expected) chapters found")
        }
        let single = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "This chapter")).firstMatch
        reveal(single, in: app)
        single.tap()
        record(app, name: "Live Royal Road preview with all chapter pages")
        let confirm = app.buttons["web-import-confirm"].firstMatch
        reveal(confirm, in: app)
        XCTAssertEqual(confirm.label, "Import 1 chapter")
        confirm.tap()
        let success = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 book added to your library.")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 45))
        app.buttons["Done"].firstMatch.tap()
        openBook(named: "New Life as a Max Level Archmage", in: app)
        let contents = app.buttons["Contents"].firstMatch
        if !contents.isHittable {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        contents.tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1 - Vivisari")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 30))
        chapter.tap()
        XCTAssertTrue(app.webViews.staticTexts["1 - Vivisari"].firstMatch.waitForExistence(timeout: 20))
        record(app, name: "Live Royal Road chapter opened in Enve")
    }

    @MainActor
    func testMissingChapterDoesNotAddAnIncompleteBook() async throws {
        let title = "Unavailable Story \(UUID().uuidString.prefix(8))"
        let server = try WebStoryFixtureServer(title: title, missingChapter: true)
        let url = try await server.start()
        defer { server.stop() }
        let app = launchImport()
        app.textFields["web-import-url"].tap()
        app.textFields["web-import-url"].typeText(url.absoluteString + "\n")
        let confirm = app.buttons["web-import-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        reveal(confirm, in: app)
        confirm.tap()
        let error = app.staticTexts["A chapter is no longer available at this address. The book hasn't been added."].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["1 book added to your library."].exists)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add books"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.exists)
    }

    @MainActor
    func testInvalidLinkAndAccessibilityLayout() {
        let app = launchImport(mode: "paper", arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let field = app.textFields["web-import-url"]
        reveal(field, in: app)
        field.tap()
        field.typeText("javascript:alert(1)\n")
        let error = app.staticTexts["Enter a complete http or https link without a username or password."].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        reveal(error, in: app)
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.buttons["web-import-confirm"].exists)
        record(app, name: "URL validation with accessibility text")
    }

    @MainActor
    private func openBook(named title: String, in app: XCUIApplication) {
        let library = app.scrollViews["library-screen"].firstMatch
        let book = library.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        for _ in 0..<10 where !book.isHittable || book.frame.maxY > app.windows.firstMatch.frame.height * 0.75 {
            library.swipeUp()
        }
        XCTAssertTrue(book.isHittable)
        book.tap()
        let reader = app.descendants(matching: .any)["reader-screen"].firstMatch
        if !reader.waitForExistence(timeout: 5) {
            let read = app.scrollViews.buttons["Read"].firstMatch
            XCTAssertTrue(read.waitForExistence(timeout: 10))
            read.tap()
        }
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
    }

    @MainActor
    private func launchImport(mode: String = "ink", arguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-imagineScreen", "library", "-imagine.library.source", "device",
            "-imagine.library.status", "all", "-imagine.library.media", "all",
            "-imagine.library.source.media.device", "all", "-imagine.library.advancedFilters", "",
            "-imagine.library.facet", "books", "-hearth.mode", mode,
        ] + arguments
        app.launch()
        let add = app.buttons["Add books"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 40))
        add.tap()
        app.buttons["Import from link"].tap()
        XCTAssertTrue(app.textFields["web-import-url"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.scrollViews["web-import-screen"].swipeUp() }
    }

    @MainActor
    private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

nonisolated private final class WebStoryFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "enve.web-story-fixture")

    init(title: String, missingChapter: Bool = false) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let html = Self.page(path: path, title: title)
                let body = Data(html.utf8)
                let status = missingChapter && path == "/chapter/2" ? "404 Not Found" : "200 OK"
                var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func page(path: String, title: String) -> String {
        let head = "<html lang=\"en\"><head><meta name=\"author\" content=\"Enve Fixture Author\"><meta name=\"viewport\" content=\"width=device-width\"></head><body>"
        if path.hasPrefix("/chapter/") {
            let chapter = path.contains("/2") ? "The atlas" : "The observatory"
            return head + """
            <a rel="up" href="/">\(title)</a><article><h1>\(chapter)</h1>
            <p>The traveler reached the observatory before dawn. An atlas waited beside the telescope. Each page described a different constellation, with stories written in the margins.</p>
            <p>She opened the book and traced the path between the stars. The route continued over the mountain and down into a quiet valley, where the next part of her journey would begin.</p>
            <table><tr><th>Skill</th><th>Level</th></tr><tr><td>Navigation</td><td>7</td></tr></table>
            </article></body></html>
            """
        }
        return head + """
        <main><h1>\(title)</h1><p>A short fictional story used to verify offline web imports.</p>
        <table id="chapters"><tr><td><a href="/chapter/1">The observatory</a></td></tr><tr><td><a href="/chapter/2">The atlas</a></td></tr></table>
        </main></body></html>
        """
    }
}
