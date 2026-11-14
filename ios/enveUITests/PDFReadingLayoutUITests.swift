import UIKit
import XCTest

final class PDFReadingLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTwoPageViewWithSeparateCoverTurnsSpreadsAndIsRememberedPerBook() throws {
        let fixtureName = "pdf-layout-\(UUID().uuidString).pdf"
        let pdf = Self.makeSixPagePDF()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        var app = try launchPDFReader(fixtureName, pdf: pdf)
        XCTAssertTrue(waitForStatus(app, "Page 1 of 6"))

        openAppearance(app)
        let twoPage = app.switches["reader-pdf-two-page"].firstMatch
        let cover = app.switches["reader-pdf-cover-separately"].firstMatch
        revealInAppearanceSheet(app, twoPage)
        XCTAssertEqual(twoPage.value as? String, "0")
        XCTAssertEqual(cover.value as? String, "0")
        XCTAssertFalse(cover.isEnabled, "The cover option waits for the two-page view")
        twoPage.tap()
        XCTAssertTrue(waitForValue(twoPage, "1"))
        XCTAssertTrue(cover.isEnabled)
        cover.tap()
        XCTAssertTrue(waitForValue(cover, "1"))
        dismissAppearance(app)
        XCTAssertTrue(waitForStatus(app, "Page 1 of 6"))
        attachScreenshot(app, name: "pdf-cover-alone")

        turnPage(app, forward: true)
        XCTAssertTrue(waitForStatus(app, "Pages 2-3 of 6"))
        attachScreenshot(app, name: "pdf-first-pair")
        turnPage(app, forward: true)
        XCTAssertTrue(waitForStatus(app, "Pages 4-5 of 6"))
        turnPage(app, forward: false)
        XCTAssertTrue(waitForStatus(app, "Pages 2-3 of 6"))

        // Switching the cover off re-pairs around the same page, so page 2 stays on screen.
        openAppearance(app)
        revealInAppearanceSheet(app, cover)
        cover.tap()
        XCTAssertTrue(waitForValue(cover, "0"))
        dismissAppearance(app)
        XCTAssertTrue(waitForStatus(app, "Pages 1-2 of 6"))
        openAppearance(app)
        revealInAppearanceSheet(app, cover)
        cover.tap()
        XCTAssertTrue(waitForValue(cover, "1"))
        let scrolled = app.buttons["Scrolled"].firstMatch
        revealInAppearanceSheet(app, scrolled)
        scrolled.tap()
        dismissAppearance(app)
        XCTAssertTrue(waitForStatus(app, "Pages 2-3 of 6"))
        attachScreenshot(app, name: "pdf-scrolled-pair")
        openAppearance(app)
        let paged = app.buttons["Paged"].firstMatch
        revealInAppearanceSheet(app, paged)
        paged.tap()
        dismissAppearance(app)
        XCTAssertTrue(waitForStatus(app, "Pages 2-3 of 6"))

        turnPage(app, forward: false)
        XCTAssertTrue(waitForStatus(app, "Page 1 of 6"))
        app.terminate()

        app = try launchPDFReader(fixtureName, pdf: pdf)
        turnPage(app, forward: true)
        XCTAssertTrue(waitForStatus(app, "Pages 2-3 of 6"), "The two-page view and cover choice must survive reopening")
        openAppearance(app)
        revealInAppearanceSheet(app, twoPage)
        XCTAssertEqual(twoPage.value as? String, "1")
        XCTAssertEqual(cover.value as? String, "1")
        dismissAppearance(app)
        app.terminate()

        app = try launchPDFReader("pdf-layout-other-\(UUID().uuidString).pdf", pdf: pdf)
        turnPage(app, forward: true)
        XCTAssertTrue(waitForStatus(app, "Page 2 of 6"), "Another PDF must keep the single-page default")
        openAppearance(app)
        revealInAppearanceSheet(app, twoPage)
        XCTAssertEqual(twoPage.value as? String, "0")
        XCTAssertEqual(cover.value as? String, "0")
        app.terminate()
    }

    @MainActor
    func testPageAdjustIsRememberedPerBookAndACroppedPagePansInsteadOfTurning() throws {
        let fixtureName = "pdf-adjust-\(UUID().uuidString).pdf"
        let pdf = Self.makeSixPagePDF()
        XCUIDevice.shared.orientation = .portrait

        var app = try launchPDFReader(fixtureName, pdf: pdf)
        XCTAssertTrue(waitForStatus(app, "Page 1 of 6"))
        openAppearance(app)
        let fit = app.buttons["reader-pdf-page-adjust-fit"].firstMatch
        let crop = app.buttons["reader-pdf-page-adjust-crop"].firstMatch
        revealInAppearanceSheet(app, fit)
        XCTAssertEqual(fit.value as? String, "Selected", "Fit is the default page adjust")
        for adjust in ["crop", "fillHeight", "fillWidth"] {
            let chip = app.buttons["reader-pdf-page-adjust-\(adjust)"].firstMatch
            XCTAssertTrue(chip.isHittable, "\(adjust) must be on screen with the other page adjust options")
            XCTAssertEqual(chip.value as? String, "Not selected")
        }
        attachScreenshot(app, name: "pdf-page-adjust-options")
        crop.tap()
        XCTAssertTrue(waitForValue(crop, "Selected"))
        XCTAssertEqual(fit.value as? String, "Not selected")
        dismissAppearance(app)
        attachScreenshot(app, name: "pdf-crop")

        // A portrait page cropped to a portrait screen is wider than it, so a swipe pans the page.
        turnPage(app, forward: true)
        XCTAssertTrue(waitForStatus(app, "Page 1 of 6"))
        tapEdge(app, trailing: true)
        XCTAssertTrue(waitForStatus(app, "Page 2 of 6"), "Edge taps still turn a cropped page")
        app.terminate()

        app = try launchPDFReader(fixtureName, pdf: pdf)
        openAppearance(app)
        revealInAppearanceSheet(app, crop)
        XCTAssertEqual(crop.value as? String, "Selected", "The page adjust must survive reopening")
        fit.tap()
        XCTAssertTrue(waitForValue(fit, "Selected"))
        dismissAppearance(app)
        showChrome(app)
        let pageStatus = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Page [1-6] of 6 .*")).firstMatch
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 5))
        let currentPage = try XCTUnwrap(Int(pageStatus.label.split(separator: " ")[1]))
        XCTAssertLessThan(currentPage, 6)
        turnPage(app, forward: true)
        XCTAssertTrue(waitForStatus(app, "Page \(currentPage + 1) of 6"), "A fitted page turns with a swipe again")
        app.terminate()

        app = try launchPDFReader("pdf-adjust-other-\(UUID().uuidString).pdf", pdf: pdf)
        openAppearance(app)
        revealInAppearanceSheet(app, fit)
        XCTAssertEqual(fit.value as? String, "Selected", "Another PDF keeps the Fit default")
        app.terminate()
    }

    @MainActor
    func testKeyboardPageTurnerKeysTurnPagesUntilTheSettingIsOff() throws {
        let pdf = Self.makeSixPagePDF()
        XCUIDevice.shared.orientation = .portrait
        let app = try launchPDFReader("pdf-keys-\(UUID().uuidString).pdf", pdf: pdf)
        XCTAssertTrue(waitForStatus(app, "Page 1 of 6"))

        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 2 of 6"))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 3 of 6"))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 4 of 6"))
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 3 of 6"))
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 2 of 6"))

        let keyboard = app.switches["reader-keyboard-page-turns"].firstMatch
        let controllers = app.switches["reader-game-controller-page-turns"].firstMatch
        openAppearance(app)
        revealInAppearanceSheet(app, keyboard)
        XCTAssertEqual(keyboard.value as? String, "1")
        XCTAssertEqual(controllers.value as? String, "1")
        // Keys typed while the sheet is up belong to the sheet.
        app.typeKey(.rightArrow, modifierFlags: [])
        keyboard.tap()
        XCTAssertTrue(waitForValue(keyboard, "0"))
        dismissAppearance(app)
        XCTAssertTrue(waitForStatus(app, "Page 2 of 6"))

        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 2 of 6"), "Keys must not turn pages once the setting is off")

        openAppearance(app)
        revealInAppearanceSheet(app, keyboard)
        keyboard.tap()
        XCTAssertTrue(waitForValue(keyboard, "1"))
        dismissAppearance(app)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForStatus(app, "Page 3 of 6"))
        app.terminate()
    }

    @MainActor
    private func launchPDFReader(_ fixtureName: String, pdf: Data) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = pdf.base64EncodedString()
        app.launchArguments = ["-imagineScreen", "pdffixture", "-imagineFixture", fixtureName]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].waitForExistence(timeout: 30))
        // The opening chrome fades on its own; a tap while it fades would race the auto-hide.
        let progress = app.descendants(matching: .any)["reader-progress-slider"].firstMatch
        if progress.waitForExistence(timeout: 5) {
            _ = progress.waitForNonExistence(timeout: 15)
        }
        return app
    }

    @MainActor
    private func showChrome(_ app: XCUIApplication) {
        let appearance = app.buttons["Appearance"].firstMatch
        if appearance.exists { return }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitForStatus(_ app: XCUIApplication, _ pages: String) -> Bool {
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "\(pages) ")).firstMatch
        if status.waitForExistence(timeout: 3) { return true }
        showChrome(app)
        return status.waitForExistence(timeout: 5)
    }

    @MainActor
    private func openAppearance(_ app: XCUIApplication) {
        showChrome(app)
        app.buttons["Appearance"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Paged"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func revealInAppearanceSheet(_ app: XCUIApplication, _ element: XCUIElement) {
        let sheet = app.scrollViews.containing(.button, identifier: "Paged").firstMatch
        for _ in 0..<10 {
            if element.exists, element.isHittable { break }
            sheet.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func dismissAppearance(_ app: XCUIApplication) {
        app.buttons["reader-pdf-appearance-done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Paged"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func turnPage(_ app: XCUIApplication, forward: Bool) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.75 : 0.25, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.25 : 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func tapEdge(_ app: XCUIApplication, trailing: Bool) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: trailing ? 0.95 : 0.05, dy: 0.5)).tap()
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [matched], timeout: 5) == .completed
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Six portrait pages with alternating backgrounds and a large page number, so spreads read at a glance.
    private static func makeSixPagePDF() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 0..<6 {
                context.beginPage()
                let dark = page.isMultiple(of: 2)
                (dark ? UIColor.darkGray : UIColor.white).setFill()
                context.fill(bounds)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 220),
                    .foregroundColor: dark ? UIColor.white : UIColor.black,
                ]
                let label = "\(page + 1)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
        }
    }
}
