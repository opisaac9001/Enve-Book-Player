import XCTest
import UIKit

final class ReaderVisualInteractionUITests: XCTestCase {
    private let passageText = "The lantern waits beside the quiet gate."
    private let imageAlt = "Four colored panels around a pale cross and dark ring"
    private let caption = "Original geometric lantern study."

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testReadiumIllustrationZoomAndReturn() throws { try verifyIllustration(engine: "readium") }
    @MainActor func testFoliateIllustrationZoomAndReturn() throws { try verifyIllustration(engine: "foliate") }
    @MainActor func testReadiumPinchChangesTextSize() throws { try verifyTextResize(engine: "readium") }
    @MainActor func testFoliatePinchChangesTextSize() throws { try verifyTextResize(engine: "foliate") }

    @MainActor
    private func launch(engine: String) throws -> XCUIApplication {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reader-visual-interactions", withExtension: "epub"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = ["-imagineScreen", "footnotefixture", "-imagineFixture",
            "reader-visual-\(UUID().uuidString).epub", "--reader-engine=\(engine)"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-screen"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(passage(in: app).waitForExistence(timeout: 30))
        wait("Initial passage is rendered") { self.passage(in: app).isHittable }
        hideChrome(app, waitForAutoHide: true)
        let sheet = openAppearance(app)
        for _ in 0..<26 {
            let size = try textSize(in: sheet)
            if size == 100 { break }
            app.buttons[size > 100 ? "Smaller text" : "Larger text"].firstMatch.tap()
        }
        XCTAssertEqual(try textSize(in: sheet), 100)
        dismissAppearance(sheet, app: app)
        hideChrome(app)
        wait("Passage remains on screen after normalizing text size") { self.passage(in: app).isHittable }
        return app
    }

    @MainActor
    private func verifyIllustration(engine: String) throws {
        let app = try launch(engine: engine)
        defer { app.terminate() }
        let anchor = passage(in: app)
        let originalFrame = anchor.frame
        let illustration = app.webViews.images.matching(NSPredicate(format: "label == %@", imageAlt)).firstMatch
        XCTAssertTrue(illustration.waitForExistence(timeout: 10))
        wait("The illustration can be tapped") { illustration.isHittable }
        attach(app, "\(engine)-illustration-before")
        illustration.tap()
        let viewer = app.descendants(matching: .any)["reader-image-viewer"].firstMatch
        let close = app.buttons["reader-image-viewer-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[caption].firstMatch.exists)
        XCTAssertTrue(app.images.matching(NSPredicate(format: "label == %@", imageAlt)).firstMatch.exists)
        let fit = try pixels(viewer.screenshot())
        attach(app, "\(engine)-illustration-fit")
        viewer.doubleTap()
        wait("Double tap changes the displayed image scale") {
            guard let current = try? self.pixels(viewer.screenshot()) else { return false }
            return self.changedFraction(fit, current) > 0.12
        }
        XCTAssertTrue(close.exists)
        let doubleTapped = try pixels(viewer.screenshot())
        attach(app, "\(engine)-illustration-double-tap")
        viewer.pinch(withScale: 1.5, velocity: 1)
        wait("Pinch further changes the displayed image scale") {
            guard let current = try? self.pixels(viewer.screenshot()) else { return false }
            return self.changedFraction(doubleTapped, current) > 0.08
        }
        XCTAssertTrue(close.exists)
        wait("The close glyph and caption remain visible over the zoomed image") {
            guard let closeContrast = try? self.contrast(close.screenshot()),
                let captionContrast = try? self.contrast(app.staticTexts[self.caption].firstMatch.screenshot())
            else { return false }
            return closeContrast > 60 && captionContrast > 60
        }
        attach(app, "\(engine)-illustration-pinch")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        wait("Closing returns to the same passage") { anchor.isHittable }
        XCTAssertEqual(anchor.label, passageText)
        XCTAssertEqual(anchor.frame.minY, originalFrame.minY, accuracy: 3)
        XCTAssertEqual(anchor.frame.height, originalFrame.height, accuracy: 3)
        attach(app, "\(engine)-illustration-returned")
        let sheet = openAppearance(app)
        XCTAssertEqual(try textSize(in: sheet), 100, "Image zoom must not resize the reader text")
        dismissAppearance(sheet, app: app)
    }

    @MainActor
    private func verifyTextResize(engine: String) throws {
        let app = try launch(engine: engine)
        defer { app.terminate() }
        let anchor = passage(in: app)
        let originalHeight = anchor.frame.height
        let content = app.webViews.containing(.staticText, identifier: passageText).firstMatch
        XCTAssertTrue(content.exists)
        attach(app, "\(engine)-text-before-pinch")
        content.pinch(withScale: 1.45, velocity: 1)
        let badge = app.descendants(matching: .any)["reader-pinch-resize-badge"].firstMatch
        if badge.exists {
            XCTAssertTrue(badge.label.hasPrefix("Text size "))
            attach(app, "\(engine)-text-resize-badge")
        }
        XCTAssertFalse(app.buttons["reader-image-viewer-close"].firstMatch.exists)
        wait("Reader pinch increases the rendered passage height") {
            anchor.isHittable && anchor.frame.height > originalHeight + 2
        }
        attach(app, "\(engine)-text-after-pinch")
        var sheet = openAppearance(app)
        let enlarged = try textSize(in: sheet)
        XCTAssertGreaterThan(enlarged, 100)
        XCTAssertLessThanOrEqual(enlarged, 300)
        attach(app, "\(engine)-text-size-setting-enlarged")
        dismissAppearance(sheet, app: app)
        hideChrome(app)
        content.pinch(withScale: 0.72, velocity: -1)
        wait("Pinching inward reduces the rendered passage") {
            anchor.isHittable && anchor.frame.height < originalHeight * 1.3
        }
        sheet = openAppearance(app)
        XCTAssertLessThan(try textSize(in: sheet), enlarged)
        attach(app, "\(engine)-text-size-setting-reduced")
        dismissAppearance(sheet, app: app)
        XCTAssertTrue(anchor.isHittable)
    }

    @MainActor
    private func passage(in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", passageText)).firstMatch
    }

    @MainActor
    private func openAppearance(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["Appearance"].firstMatch
        if !button.isHittable {
            passage(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        wait("Appearance control is available") { button.isHittable }
        button.tap()
        let sheet = app.scrollViews.containing(.button, identifier: "Smaller text").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        return sheet
    }

    @MainActor
    private func textSize(in sheet: XCUIElement) throws -> Int {
        let value = sheet.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2,3}%")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        return try XCTUnwrap(Int(value.label.dropLast()))
    }

    @MainActor
    private func dismissAppearance(_ sheet: XCUIElement, app: XCUIApplication) {
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).press(forDuration: 0.1,
            thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        XCTAssertTrue(app.buttons["Smaller text"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func hideChrome(_ app: XCUIApplication, waitForAutoHide: Bool = false) {
        let controls = app.descendants(matching: .any)["reader-progress-slider"].firstMatch
        guard controls.exists else { return }
        if !waitForAutoHide { passage(in: app).tap() }
        XCTAssertTrue(controls.waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func wait(_ message: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    @MainActor
    private func pixels(_ screenshot: XCUIScreenshot) throws -> [UInt8] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let area = CGRect(x: Double(image.width) * 0.2, y: Double(image.height) * 0.2,
            width: Double(image.width) * 0.6, height: Double(image.height) * 0.6)
        let cropped = try XCTUnwrap(image.cropping(to: area))
        var data = [UInt8](repeating: 0, count: 32 * 32 * 4)
        try data.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return data
    }

    @MainActor
    private func contrast(_ screenshot: XCUIScreenshot) throws -> Int {
        let data = try pixels(screenshot)
        let brightness = stride(from: 0, to: data.count, by: 4).map {
            (Int(data[$0]) + Int(data[$0 + 1]) + Int(data[$0 + 2])) / 3
        }
        return (brightness.max() ?? 0) - (brightness.min() ?? 0)
    }

    private func changedFraction(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count else { return 1 }
        var changed = 0
        for offset in stride(from: 0, to: first.count, by: 4) {
            let distance = (0..<3).reduce(0) { $0 + abs(Int(first[offset + $1]) - Int(second[offset + $1])) }
            if distance > 90 { changed += 1 }
        }
        return Double(changed) / Double(first.count / 4)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
