import XCTest

final class ReaderBookOpeningUITests: XCTestCase {
    @MainActor
    func testBooksOpenAndReaderControlsRemainUsable() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reader-interaction", withExtension: "epub"))
        let app = XCUIApplication()
        app.launchEnvironment["ENVE_READER_FIXTURE_BASE64"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launchArguments = [
            "-imagineScreen", "footnotefixture", "-imagineFixture", "book-open-check.epub",
            "-ebookTTS.engine", "apple",
        ]
        for _ in 0..<3 {
            app.launch()
            let reader = app.descendants(matching: .any)["reader-screen"].firstMatch
            XCTAssertTrue(reader.waitForExistence(timeout: 30))
            let contents = app.buttons["Contents"].firstMatch
            if !contents.isHittable {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            }
            XCTAssertTrue(contents.waitForExistence(timeout: 5))
            contents.tap()
            let chapters = app.otherElements["reader-contents-tray"].firstMatch
            XCTAssertTrue(chapters.waitForExistence(timeout: 5))
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "book-open-and-reader-controls"
            image.lifetime = .keepAlways
            add(image)
            app.terminate()
        }
    }

}
