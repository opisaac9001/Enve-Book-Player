import Foundation
import XCTest

final class ProviderFixVerificationUITests: XCTestCase {
    private struct FileProgress: Decodable {
        let percentage: Double
        let cfi: String?
    }

    private struct Configuration: Decodable {
        struct Service: Decodable { let url: String; let port: Int }
        let username: String
        let password: String
        let services: [String: Service]
    }

    private func configuration() throws -> Configuration {
        if let json = ProcessInfo.processInfo.environment["ENVE_PROVIDER_UI_CONFIG_JSON"] {
            return try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        }
        guard let path = ProcessInfo.processInfo.environment["ENVE_PROVIDER_UI_CONFIG"] else {
            throw XCTSkip("Requires the private live-lab forwarding fixture")
        }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func mode(_ value: String, service: Configuration.Service) async throws {
        if ProcessInfo.processInfo.environment["ENVE_PROVIDER_UI_EXTERNAL_CONTROL"] == "1" { return }
        var request = URLRequest(url: URL(string: service.url + "/__enve_test/mode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": value])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func bookOrbitToken(_ config: Configuration, service: Configuration.Service) async throws -> String {
        var request = URLRequest(url: URL(string: service.url + "/api/v1/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": config.username, "password": config.password])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        struct Login: Decodable { let accessToken: String }
        return try JSONDecoder().decode(Login.self, from: data).accessToken
    }

    private func progress(fileID: Int, token: String, service: Configuration.Service) async throws -> FileProgress {
        var request = URLRequest(url: URL(string: service.url + "/api/v1/books/files/\(fileID)/progress")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(FileProgress.self, from: data)
    }

    private func waitForProgress(fileID: Int, token: String, service: Configuration.Service,
        matching predicate: (FileProgress) -> Bool) async throws -> FileProgress {
        for _ in 0..<60 {
            let value = try await progress(fileID: fileID, token: token, service: service)
            if predicate(value) { return value }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("The reader did not deliver the expected progress to BookOrbit")
        throw URLError(.timedOut)
    }

    private func settledProgress(fileID: Int, token: String, service: Configuration.Service) async throws -> FileProgress {
        var last = try await progress(fileID: fileID, token: token, service: service)
        var unchanged = 0
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            let current = try await progress(fileID: fileID, token: token, service: service)
            unchanged = current.percentage == last.percentage && current.cfi == last.cfi ? unchanged + 1 : 0
            if unchanged >= 6 { return current }
            last = current
        }
        XCTFail("BookOrbit progress did not settle")
        throw URLError(.timedOut)
    }

    @MainActor
    private func waitForEPUBText(in app: XCUIApplication) throws {
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        let text = app.webViews.staticTexts
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            text.allElementsBoundByIndex.contains { $0.isHittable && $0.label.count > 40 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed,
            "The EPUB must render readable text: \(app.debugDescription)")
    }

    @MainActor
    private func markUnread(in app: XCUIApplication) throws {
        let wasUnread = app.staticTexts["Unread"].firstMatch.isHittable
        try visibleButton("More", in: app).tap()
        let reset = app.buttons["Mark as unread"].firstMatch
        if !reset.waitForExistence(timeout: 2) {
            XCTAssertTrue(wasUnread)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)).tap()
            return
        }
        reset.tap()
        let confirmation = app.buttons["Mark as unread"].firstMatch
        if confirmation.waitForExistence(timeout: 2) { confirmation.tap() }
        XCTAssertTrue(app.staticTexts["Unread"].firstMatch.waitForExistence(timeout: 20))
    }

    @MainActor
    private func visibleButton(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format: "label == %@", title))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            query.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, title)
        return try XCTUnwrap(query.allElementsBoundByIndex.last { $0.isHittable })
    }

    @MainActor
    private func allowLocalNetworkIfPresented() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 3),
            alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "local network")).firstMatch.exists,
            alert.buttons["Allow"].exists
        else { return false }
        alert.buttons["Allow"].tap()
        return true
    }

    @MainActor
    private func launchLibrary() throws -> XCUIApplication {
        let app = XCUIApplication()
        let external = ProcessInfo.processInfo.environment["ENVE_PROVIDER_UI_EXTERNAL_CONTROL"] == "1"
        app.launchArguments = external ? [] : ["-imagineScreen", "library"]
        app.launch()
        _ = allowLocalNetworkIfPresented()
        let later = app.buttons["Maybe later"].firstMatch
        if later.exists { later.tap() }
        if external { try visibleButton("Library", in: app).tap() }
        return app
    }

    @MainActor
    private func form(_ provider: String, port: Int, username: String, password: String) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = try launchLibrary()
        try visibleButton("Settings", in: app).tap()
        try visibleButton("Add a source", in: app).tap()
        try visibleButton("Set up manually", in: app).tap()
        try visibleButton(provider, in: app).tap()
        let scheme = app.buttons["https://"].firstMatch
        if scheme.waitForExistence(timeout: 3) {
            scheme.tap()
            app.buttons["http://"].firstMatch.tap()
        }
        let fields = app.textFields.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertGreaterThanOrEqual(fields.count, 3, "The visible form needs address, name, and username fields")
        let address = try XCTUnwrap(fields.first)
        address.tap()
        let service = try configuration().services.values.first { $0.port == port }
        let host = service.flatMap { URLComponents(string: $0.url)?.host } ?? "127.0.0.1"
        address.typeText("\(host):\(port)")
        let name = fields[1]
        name.tap()
        name.typeText("UI Verification \(provider)")
        app.swipeUp()
        let user = fields[2]
        XCTAssertTrue(user.exists)
        user.tap()
        user.typeText(username)
        app.swipeUp()
        let secret = app.secureTextFields.firstMatch
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.swipeUp()
        let connect = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Connect")).allElementsBoundByIndex.last)
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        if allowLocalNetworkIfPresented(), connect.exists, connect.isHittable, connect.isEnabled { connect.tap() }
        return app
    }

    @MainActor
    func testKavitaWrongCredentialsThenSuccessfulLogin() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["Kavita"])
        try await mode("healthy", service: service)
        var app = try form("Kavita", port: service.port, username: config.username, password: "ui-wrong-password")
        let invalid = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "unauthorized", "credentials")).firstMatch
        XCTAssertTrue(invalid.waitForExistence(timeout: 20), "Wrong credentials must show an authentication error")
        app.terminate()
        app = try form("Kavita", port: service.port, username: config.username, password: config.password)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForNonExistence(timeout: 30), "Successful authentication must leave the credential form")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "kavita-live-login-recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testKavitaServerFailureIsNotReportedAsBadCredentials() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["Kavita"])
        try await mode("503", service: service)
        let app: XCUIApplication
        do {
            app = try form("Kavita", port: service.port, username: config.username, password: config.password)
        } catch {
            try await mode("healthy", service: service)
            throw error
        }
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "503", "unavailable", "server error")).firstMatch
        let accurate = failure.waitForExistence(timeout: 15)
        try await mode("healthy", service: service)
        XCTAssertTrue(accurate, "HTTP 503 must retain server-failure information")
    }

    @MainActor
    func testKavitaConnectionRefusedHasAConnectionError() throws {
        _ = try configuration()
        let app = try form("Kavita", port: 18789, username: "uifixture", password: "ui-wrong-password")
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "could not connect", "cannot connect", "connection refused")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
    }

    @MainActor
    func testJellyfinLoginAndLibrarySelectionPersist() throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["Jellyfin"])
        let app = try form("Jellyfin", port: service.port, username: config.username, password: config.password)
        let selectAll = app.buttons["Select All"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 30))
        selectAll.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForNonExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["-imagineScreen", "settings"]
        app.launch()
        let source = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "UI Verification Jellyfin")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "jellyfin-live-source-after-restart"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testBookOrbitLoginPersistsAfterRestart() throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        let app = try form("BookOrbit", port: service.port, username: config.username, password: config.password)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForNonExistence(timeout: 30))
        app.terminate()
        app.launchArguments = ["-imagineScreen", "settings"]
        app.launch()
        let source = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "UI Verification BookOrbit")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "bookorbit-live-source-after-restart"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testBookOrbitResetToUnreadFromDetails() async throws {
        let config = try configuration()
        guard ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_RESET_BOOK"] == "Dracula" else {
            throw XCTSkip("Requires an explicitly backed-up Dracula progress record")
        }
        let service = try XCTUnwrap(config.services["BookOrbit"])
        let token = try await bookOrbitToken(config, service: service)
        let app = try libraryFixture(source: "BookOrbit", title: "Dracula")
        try markUnread(in: app)
        _ = try await waitForProgress(fileID: 54, token: token, service: service) { $0.percentage == 0 && $0.cfi == nil }
        let reset = try await settledProgress(fileID: 54, token: token, service: service)
        XCTAssertEqual(reset.percentage, 0)
        XCTAssertNil(reset.cfi)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "bookorbit-unread-after-ui-reset"
        attachment.lifetime = .keepAlways
        add(attachment)
        let result = XCTAttachment(string: "Server after UI reset: percentage=\(reset.percentage), CFI=\(reset.cfi ?? "none")")
        result.name = "bookorbit-unread-server-progress"
        result.lifetime = .keepAlways
        add(result)
        app.terminate()
    }

    @MainActor
    private func jellyfinFixture() throws -> XCUIApplication {
        _ = try configuration()
        guard ProcessInfo.processInfo.environment["ENVE_JELLYFIN_PLAYBACK_FIXTURE"] == "1" else {
            throw XCTSkip("Requires backed-up Jellyfin fixture user data")
        }
        return try libraryFixture(source: "Jellyfin", title: "Chaptered M4B Book")
    }

    @MainActor
    private func libraryFixture(source: String, title: String) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = try launchLibrary()
        let booksTab = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Books"))
        if let books = booksTab.allElementsBoundByIndex.first(where: \.isHittable) { books.tap() }
        app.buttons["library-source-menu"].tap()
        try visibleButton("UI Verification \(source)", in: app).tap()
        if !app.textFields.allElementsBoundByIndex.contains(where: \.isHittable) {
            try visibleButton("Search the library", in: app).tap()
        }
        let searchReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.textFields.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [searchReady], timeout: 10), .completed)
        let field = try XCTUnwrap(app.textFields.allElementsBoundByIndex.last { $0.isHittable })
        field.tap()
        if field.value as? String != title {
            if let value = field.value as? String, value != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            field.typeText(title)
        }
        let submit = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "Search")).firstMatch
        if submit.exists { submit.tap() }
        let books = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title),")
        )
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            books.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        try XCTUnwrap(books.allElementsBoundByIndex.last { $0.isHittable }).tap()
        return app
    }

    @MainActor
    func testJellyfinStreamsFixture() throws {
        var app = try jellyfinFixture()
        let download = app.buttons["detail.downloadButton"].firstMatch
        if download.label.localizedCaseInsensitiveContains("available offline") {
            download.tap()
            let remove = app.buttons["Remove"].firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            remove.tap()
            app.terminate()
            app = try jellyfinFixture()
            XCTAssertFalse(app.buttons["detail.downloadButton"].firstMatch.label.localizedCaseInsensitiveContains("available offline"))
        }
        try visibleButton("Listen", in: app).tap()
        let close = app.buttons["Close player"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        let playing = XCTAttachment(screenshot: app.screenshot())
        playing.name = "jellyfin-fixture-streaming"
        playing.lifetime = .keepAlways
        add(playing)
        pause.tap()
        close.tap()
    }

    @MainActor
    func testJellyfinDownloadsFixture() throws {
        let app = try jellyfinFixture()
        let download = app.buttons["detail.downloadButton"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: download)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed)
        if !download.label.localizedCaseInsensitiveContains("available offline") { download.tap() }
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", "available offline"), object: download
        )
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 45), .completed, "Jellyfin download must finish")
        let downloaded = XCTAttachment(screenshot: app.screenshot())
        downloaded.name = "jellyfin-fixture-download-complete"
        downloaded.lifetime = .keepAlways
        add(downloaded)
    }

    @MainActor
    func testJellyfinDownloadRemovalUpdatesWithoutRestart() throws {
        let app = try jellyfinFixture()
        let download = app.buttons["detail.downloadButton"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        if !download.label.localizedCaseInsensitiveContains("available offline") { download.tap() }
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", "available offline"), object: download
        )
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 45), .completed)
        download.tap()
        try visibleButton("Remove", in: app).tap()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Download for offline"), object: download
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed,
            "Removing the files must update the visible download button without restarting")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "jellyfin-download-removed-without-restart"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testBookOrbitPagedPDFProgressMovesBothWays() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        guard ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_PAGED_PDF_FIXTURE"] == "1" else {
            throw XCTSkip("Requires a backed-up 20-page PDF fixture")
        }
        try await mode("healthy", service: service)
        let token = try await bookOrbitToken(config, service: service)
        let app = try libraryFixture(source: "BookOrbit", title: "We're Civilized!")
        try markUnread(in: app)
        _ = try await waitForProgress(fileID: 64, token: token, service: service) { $0.percentage == 0 && $0.cfi == nil }
        try visibleButton("Read", in: app).tap()
        try setPDFPageFlow("Paged", in: app)
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "WE’RE CIVILIZED!"))
        XCTAssertTrue(content.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let initial = try await progress(fileID: 64, token: token, service: service)
        for _ in 0..<3 { app.swipeLeft() }
        let forward = try await waitForProgress(fileID: 64, token: token, service: service) { $0.percentage >= 300.0 / 19 - 0.01 }
        XCTAssertEqual(forward.percentage, 300.0 / 19, accuracy: 0.01, "Each swipe must turn exactly one PDF page")
        let forwardImage = XCTAttachment(screenshot: app.screenshot())
        forwardImage.name = "bookorbit-pdf-progress-forward"
        forwardImage.lifetime = .keepAlways
        add(forwardImage)
        app.swipeRight()
        let backward = try await waitForProgress(fileID: 64, token: token, service: service) { abs($0.percentage - 200.0 / 19) < 0.01 }
        let backwardImage = XCTAttachment(screenshot: app.screenshot())
        backwardImage.name = "bookorbit-pdf-progress-backward"
        backwardImage.lifetime = .keepAlways
        add(backwardImage)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "bookorbit-pdf-position-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let result = XCTAttachment(string: "PDF progress: \(initial.percentage) → \(forward.percentage) → \(backward.percentage)")
        result.name = "bookorbit-pdf-server-progress"
        result.lifetime = .keepAlways
        add(result)
        app.terminate()
    }

    @MainActor
    func testBookOrbitEPUBProgressMovesBothWays() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        guard ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_EPUB_FIXTURE"] == "1" else {
            throw XCTSkip("Requires a backed-up Dracula progress record")
        }
        try await mode("healthy", service: service)
        let token = try await bookOrbitToken(config, service: service)
        let app = try libraryFixture(source: "BookOrbit", title: "Dracula")
        try visibleButton("Read", in: app).tap()
        try waitForEPUBText(in: app)
        let initial = try await progress(fileID: 54, token: token, service: service)
        for _ in 0..<12 { app.swipeLeft() }
        _ = try await waitForProgress(fileID: 54, token: token, service: service) { $0.percentage > initial.percentage && $0.cfi != initial.cfi }
        let forward = try await settledProgress(fileID: 54, token: token, service: service)
        XCTAssertTrue(forward.cfi?.hasPrefix("epubcfi(") == true)
        for _ in 0..<2 { app.swipeRight() }
        _ = try await waitForProgress(fileID: 54, token: token, service: service) { $0.percentage < forward.percentage && $0.cfi != forward.cfi }
        let backward = try await settledProgress(fileID: 54, token: token, service: service)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "bookorbit-epub-after-forward-and-backward"
        image.lifetime = .keepAlways
        add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "bookorbit-epub-position-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let result = XCTAttachment(string: "EPUB progress: \(initial.percentage) → \(forward.percentage) → \(backward.percentage)\nCFI: \(backward.cfi ?? "missing")")
        result.name = "bookorbit-epub-server-progress"
        result.lifetime = .keepAlways
        add(result)
        app.terminate()
    }

    @MainActor
    func testJellyfinDownloadedFixturePlaysWithServerOffline() throws {
        guard ProcessInfo.processInfo.environment["ENVE_JELLYFIN_OFFLINE_PHASE"] == "1" else {
            throw XCTSkip("Requires the host to make Jellyfin unavailable before launch")
        }
        let app = try jellyfinFixture()
        let download = app.buttons["detail.downloadButton"].firstMatch
        XCTAssertTrue(download.label.localizedCaseInsensitiveContains("available offline"))
        try visibleButton("Listen", in: app).tap()
        let pause = try visibleButton("Pause", in: app)
        let times = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+:[0-9]{2}"))
        let elapsed = try XCTUnwrap(times.allElementsBoundByIndex.first { $0.isHittable })
        let initial = elapsed.label
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in elapsed.label != initial }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "jellyfin-physical-offline-playing"
        attachment.lifetime = .keepAlways
        add(attachment)
        pause.tap()
        app.terminate()
    }

    @MainActor
    func testBookOrbitPDFPhysicalDownloadOrOfflinePhase() throws {
        _ = try configuration()
        guard let phase = ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_PDF_PHASE"],
            ["download", "offline"].contains(phase)
        else { throw XCTSkip("Requires a host-controlled PDF download or offline phase") }
        let app = try libraryFixture(source: "BookOrbit", title: "We're Civilized!")
        let download = app.buttons["detail.downloadButton"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        if phase == "download" {
            if !download.label.localizedCaseInsensitiveContains("available offline") { download.tap() }
            let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", "available offline"), object: download)
            XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 45), .completed)
        } else {
            XCTAssertTrue(download.label.localizedCaseInsensitiveContains("available offline"))
        }
        try visibleButton("Read", in: app).tap()
        let expected = ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_RESUME_TEXT"] ?? "WE’RE CIVILIZED!"
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "bookorbit-physical-pdf-\(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    private func setPDFPageFlow(_ title: String, in app: XCUIApplication) throws {
        if !app.buttons["Appearance"].firstMatch.isHittable { app.tap() }
        try visibleButton("Appearance", in: app).tap()
        let choice = try visibleButton(title, in: app)
        let point = choice.frame
        choice.tap()
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.midX, dy: point.minY - 25))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.midX, dy: app.frame.maxY - 10))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(choice.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testPDFContinuousScrollingAndPagedNavigation() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        guard ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_PAGED_PDF_FIXTURE"] == "1" else {
            throw XCTSkip("Requires a backed-up 20-page PDF fixture")
        }
        try await mode("healthy", service: service)
        let token = try await bookOrbitToken(config, service: service)
        let app = try libraryFixture(source: "BookOrbit", title: "We're Civilized!")
        try visibleButton("Read", in: app).tap()
        try setPDFPageFlow("Scrolled", in: app)
        let initial = try await progress(fileID: 64, token: token, service: service)
        for _ in 0..<3 { app.swipeUp() }
        let forward = try await waitForProgress(fileID: 64, token: token, service: service) { $0.percentage > initial.percentage }
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "pdf-continuous-scrolling-forward"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        for _ in 0..<2 { app.swipeDown() }
        let backward = try await waitForProgress(fileID: 64, token: token, service: service) { $0.percentage < forward.percentage }
        try setPDFPageFlow("Paged", in: app)
        app.swipeLeft()
        _ = try await waitForProgress(fileID: 64, token: token, service: service) { $0.percentage > backward.percentage }
        let paged = XCTAttachment(screenshot: app.screenshot())
        paged.name = "pdf-returned-to-paged-navigation"
        paged.lifetime = .keepAlways
        add(paged)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "bookorbit-final-pdf-position-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        app.terminate()
    }

    @MainActor
    func testBookOrbitSecondClientRestoresPassage() throws {
        _ = try configuration()
        guard let title = ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_RESUME_TITLE"],
            let expected = ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_RESUME_TEXT"]
        else { throw XCTSkip("Requires a passage saved by the first client") }
        let app = try libraryFixture(source: "BookOrbit", title: title)
        try visibleButton("Read", in: app).tap()
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            text.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 30), .completed,
            "The second client must display the passage saved by the first client")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "bookorbit-second-client-resumed-passage"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    func testBookOrbitPDFDownloadedFromLibraryOpensOffline() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        guard ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_PDF_FIXTURE"] == "1" else {
            throw XCTSkip("Requires a backed-up PDF fixture")
        }
        try await mode("healthy", service: service)
        let token = try await bookOrbitToken(config, service: service)
        var app = try libraryFixture(source: "BookOrbit", title: "We're Civilized!")
        try markUnread(in: app)
        _ = try await waitForProgress(fileID: 64, token: token, service: service) { $0.percentage == 0 && $0.cfi == nil }
        let download = app.buttons["detail.downloadButton"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        if !download.label.localizedCaseInsensitiveContains("available offline") { download.tap() }
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", "available offline"), object: download
        )
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 45), .completed)
        try visibleButton("Read", in: app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "WE’RE CIVILIZED!")).firstMatch.waitForExistence(timeout: 30))
        let rendered = XCTAttachment(screenshot: app.screenshot())
        rendered.name = "bookorbit-library-pdf-rendered"
        rendered.lifetime = .keepAlways
        add(rendered)
        app.terminate()
        try await mode("503", service: service)
        app = try libraryFixture(source: "BookOrbit", title: "We're Civilized!")
        try visibleButton("Read", in: app).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "WE’RE CIVILIZED!")).firstMatch.waitForExistence(timeout: 30))
        let offline = XCTAttachment(screenshot: app.screenshot())
        offline.name = "bookorbit-library-pdf-offline-after-restart"
        offline.lifetime = .keepAlways
        add(offline)
        app.terminate()
        try await mode("healthy", service: service)
    }

    @MainActor
    private func verifyBookOrbitOfflineRetry(title: String, fileID: Int, isPDF: Bool) async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        guard ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_EPUB_FIXTURE"] == "1",
            ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_PAGED_PDF_FIXTURE"] == "1"
        else { throw XCTSkip("Requires backed-up live EPUB and PDF fixtures") }
        try await mode("healthy", service: service)
        let token = try await bookOrbitToken(config, service: service)
        var app = try libraryFixture(source: "BookOrbit", title: title)
        continueAfterFailure = true
        if isPDF {
            try markUnread(in: app)
            _ = try await waitForProgress(fileID: fileID, token: token, service: service) { $0.percentage == 0 && $0.cfi == nil }
        }
        let download = app.buttons["detail.downloadButton"].firstMatch
        if !download.label.localizedCaseInsensitiveContains("available offline") { download.tap() }
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", "available offline"), object: download
        )
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 45), .completed)
        try visibleButton("Read", in: app).tap()
        if isPDF {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "WE’RE CIVILIZED!")).firstMatch.waitForExistence(timeout: 30))
            try setPDFPageFlow("Paged", in: app)
            let firstPage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Page 1 of 20")).firstMatch
            XCTAssertTrue(firstPage.waitForExistence(timeout: 10), app.debugDescription)
            app.swipeLeft()
            _ = try await waitForProgress(fileID: fileID, token: token, service: service) { abs($0.percentage - 100.0 / 19) < 0.01 }
        } else {
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
            for _ in 0..<12 { app.swipeLeft() }
            try waitForEPUBText(in: app)
        }
        let before = try await settledProgress(fileID: fileID, token: token, service: service)
        try await mode("503", service: service)
        for _ in 0..<(isPDF ? 2 : 3) { app.swipeLeft() }
        try await Task.sleep(for: .seconds(4))
        let offline = XCTAttachment(screenshot: app.screenshot())
        offline.name = "bookorbit-\(isPDF ? "pdf" : "epub")-offline-reading-before-retry"
        offline.lifetime = .keepAlways
        add(offline)
        app.terminate()
        try await mode("healthy", service: service)
        app = try libraryFixture(source: "BookOrbit", title: title)
        continueAfterFailure = true
        let after = try await waitForProgress(fileID: fileID, token: token, service: service) {
            isPDF ? abs($0.percentage - 300.0 / 19) < 0.01 : $0.percentage > before.percentage && $0.cfi != before.cfi
        }
        XCTAssertGreaterThan(after.percentage, before.percentage)
        try visibleButton("Read", in: app).tap()
        if isPDF {
            if !app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Page 4 of 20")).firstMatch.isHittable { app.tap() }
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Page 4 of 20")).firstMatch.waitForExistence(timeout: 20))
        } else {
            try waitForEPUBText(in: app)
        }
        let resumed = XCTAttachment(screenshot: app.screenshot())
        resumed.name = "bookorbit-\(isPDF ? "pdf" : "epub")-resumed-after-offline-retry"
        resumed.lifetime = .keepAlways
        add(resumed)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "bookorbit-\(isPDF ? "pdf" : "epub")-retry-position-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let result = XCTAttachment(string: "Offline retry: \(before.percentage) → \(after.percentage)\nCFI: \(after.cfi ?? "none")")
        result.name = "bookorbit-\(isPDF ? "pdf" : "epub")-offline-retry-server-position"
        result.lifetime = .keepAlways
        add(result)
        app.terminate()
    }

    @MainActor
    func testBookOrbitEPUBOfflineProgressRetriesAfterReconnect() async throws {
        try await verifyBookOrbitOfflineRetry(title: "Dracula", fileID: 54, isPDF: false)
    }

    @MainActor
    func testBookOrbitPDFOfflineProgressRetriesAfterReconnect() async throws {
        try await verifyBookOrbitOfflineRetry(title: "We're Civilized!", fileID: 64, isPDF: true)
    }

    @MainActor
    func testRemoveTemporaryVerificationSources() throws {
        _ = try configuration()
        guard ProcessInfo.processInfo.environment["ENVE_REMOVE_VERIFICATION_SOURCES"] == "1" else {
            throw XCTSkip("Only removes sources created by this verification session")
        }
        for (source, title) in [("Jellyfin", "Chaptered M4B Book"), ("BookOrbit", "We're Civilized!"), ("BookOrbit", "Dracula")] {
            let fixture = try libraryFixture(source: source, title: title)
            let download = fixture.buttons["detail.downloadButton"].firstMatch
            if download.exists, download.label.localizedCaseInsensitiveContains("available offline") {
                download.tap()
                try visibleButton("Remove", in: fixture).tap()
                let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Download for offline"), object: download)
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
            }
            fixture.terminate()
        }
        let app = try launchLibrary()
        try visibleButton("Settings", in: app).tap()
        for _ in 0..<12 {
            for _ in 0..<4 { app.swipeDown() }
            let sources = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Verification "))
            if !sources.firstMatch.exists { break }
            let source = try XCTUnwrap(sources.allElementsBoundByIndex.first(where: \.isHittable))
            source.tap()
            let remove = app.buttons["Remove this source"].firstMatch
            for _ in 0..<15 {
                if remove.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(remove.isHittable)
            remove.tap()
            try visibleButton("Remove completely", in: app).tap()
            XCTAssertTrue(remove.waitForNonExistence(timeout: 15))
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Verification ")).firstMatch.exists)
        app.terminate()
    }

    @MainActor
    func testBookOrbitPDFOpensAndReopensOffline() async throws {
        let config = try configuration()
        let service = try XCTUnwrap(config.services["BookOrbit"])
        guard let bookID = ProcessInfo.processInfo.environment["ENVE_BOOKORBIT_PDF_BOOK"] else {
            throw XCTSkip("Requires a backed-up PDF fixture and its full app book ID")
        }
        try await mode("healthy", service: service)
        let app = XCUIApplication()
        app.launchArguments = ["-imagineScreen", "reader", "-imagineOpenBook", bookID]
        app.launch()
        let page = app.staticTexts["Enve synthetic PDF - public test fixture"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "damaged")).firstMatch.exists)
        let opened = XCTAttachment(screenshot: app.screenshot())
        opened.name = "bookorbit-pdf-rendered"
        opened.lifetime = .keepAlways
        add(opened)
        app.terminate()
        try await mode("503", service: service)
        do {
            app.launch()
            XCTAssertTrue(page.waitForExistence(timeout: 30), app.debugDescription)
            let offline = XCTAttachment(screenshot: app.screenshot())
            offline.name = "bookorbit-pdf-offline-after-restart"
            offline.lifetime = .keepAlways
            add(offline)
            app.terminate()
        }
        try await mode("healthy", service: service)
    }
}
