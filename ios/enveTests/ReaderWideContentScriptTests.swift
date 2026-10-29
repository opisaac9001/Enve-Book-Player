import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderWideContentScriptTests {
    private let script = ReaderWideContentScript.source

    @Test func answersAreParsed() {
        #expect(ReaderWideContentScript.parse("changed") == .changed)
        #expect(ReaderWideContentScript.parse(" stable ") == .stable)
        #expect(ReaderWideContentScript.parse("blocked") == .blocked)
    }

    @Test func noAnswerIsAFailureNeverASilentSuccess() {
        #expect(ReaderWideContentScript.parse(nil) == .failed)
        #expect(ReaderWideContentScript.parse("") == .failed)
        #expect(ReaderWideContentScript.parse(NSNull()) == .failed)
        #expect(ReaderWideContentScript.parse(true) == .failed)
        #expect(ReaderWideContentScript.parse("whatever") == .failed)
    }

}
