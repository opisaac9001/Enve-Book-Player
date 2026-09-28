import Foundation
import Testing

@testable import enve

struct NarratedSentenceSyncTests {
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 1_010)

    private func locator(_ fragment: String) -> String {
        ##"{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["\##(fragment)"]}}"##
    }

    private func androidLocator(_ id: String) -> String {
        ##"{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"domRange":{"start":{"cssSelector":"#\##(id)","textNodeIndex":0,"charOffset":0}}}}"##
    }

    @Test func newerServerSentenceWinsInsideThePercentageTolerance() {
        let direction = ProgressConflictResolver.resolve(
            localPosition: 0.090, localDate: older, serverPosition: 0.093, serverDate: newer,
            localLocator: locator("s116"), serverLocator: androidLocator("s141")
        )
        #expect(direction == .pull)
    }

    @Test func newerLocalSentenceIsPushed() {
        let direction = ProgressConflictResolver.resolve(
            localPosition: 0.093, localDate: newer, serverPosition: 0.090, serverDate: older,
            localLocator: locator("s141"), serverLocator: locator("s116")
        )
        #expect(direction == .push)
    }

    @Test func sameSentenceStaysPut() {
        let direction = ProgressConflictResolver.resolve(
            localPosition: 0.090, localDate: older, serverPosition: 0.091, serverDate: newer,
            localLocator: locator("s141"), serverLocator: androidLocator("s141")
        )
        #expect(direction == .none)
    }

    @Test func backwardSentenceStillAsksWhenProtected() {
        let direction = ProgressConflictResolver.resolve(
            localPosition: 0.30, localDate: older, serverPosition: 0.10, serverDate: newer,
            protectsAgainstBackwardProgress: true,
            localLocator: locator("s900"), serverLocator: locator("s10")
        )
        #expect(direction == .conflict)
    }
}
