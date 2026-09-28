import Foundation
import Testing

@testable import enve

struct ReaderProgressPolicyTests {
    @Test @MainActor func readAloudSyncUsesTheCommittedPositionNotTheOpeningBook() {
        var openingBook = Book(id: "read-aloud", title: "Fixture", source: .local, libraryId: "test")
        openingBook.ebookProgress = 0.1
        openingBook.epubLocator = "opening-locator"
        let observedAt = Date(timeIntervalSince1970: 1234)
        let commit = ReaderReadAloudPositionCommit(
            progression: 0.6,
            locatorJSON: "spoken-locator",
            audioTime: 60,
            audioDuration: 100,
            observedAt: observedAt,
            isAuthoritative: true,
            schedulesRemoteSync: true
        )

        let payload = commit.applyingEbookPosition(to: openingBook)

        #expect(payload.ebookProgress == 0.6)
        #expect(payload.epubLocator == "spoken-locator")
        #expect(payload.lastUpdate == observedAt)
        #expect(payload.uniqueId == openingBook.uniqueId)
        #expect(openingBook.ebookProgress == 0.1)
    }

    @Test func bridgeWritesStayDisarmedUntilAUserInteractionIsRendered() {
        var gate = ReaderBridgeWriteGate()

        gate.armIfUserInteractionPending()
        #expect(!gate.isWriteArmed)

        gate.noteUserInteraction()
        #expect(!gate.isWriteArmed)

        gate.armIfUserInteractionPending()
        #expect(gate.isWriteArmed)
        #expect(!gate.isUserInteractionPending)
    }

    @Test func armingIsConsumedByASingleCommit() {
        var gate = ReaderBridgeWriteGate()
        gate.noteUserInteraction()
        gate.armIfUserInteractionPending()

        gate.noteCommittedWrite()

        #expect(!gate.isWriteArmed)
        #expect(gate.hasCommittedUserPosition)

        gate.armIfUserInteractionPending()
        #expect(!gate.isWriteArmed)
    }

    @Test func restartingTheBridgeSessionForgetsPriorArmingAndCommits() {
        var gate = ReaderBridgeWriteGate()
        gate.noteUserInteraction()
        gate.armIfUserInteractionPending()
        gate.noteCommittedWrite()
        gate.noteUserInteraction()

        gate.reset()

        #expect(gate == ReaderBridgeWriteGate())
        #expect(!gate.hasCommittedUserPosition)
        #expect(!gate.isUserInteractionPending)
    }

    private static let chapter = "OEBPS/text/chapter1.xhtml"

    private static func pageLocator(progression: Double, total: Double, highlight: String? = nil) -> String {
        let text = highlight.map { #","text":{"highlight":"\#($0)"}"# } ?? ""
        return #"{"href":"\#(chapter)","type":"application/xhtml+xml","locations":{"progression":\#(progression),"totalProgression":\#(total)}\#(text)}"#
    }

    private static func sentenceLocator(_ fragment: String, total: Double) -> String {
        #"{"href":"\#(chapter)","type":"application/xhtml+xml","locations":{"fragments":["\#(fragment)"],"progression":0.96,"totalProgression":\#(total)}}"#
    }

    @Test @MainActor func openedPositionMatchesItsRenderedPageButNotAPageTurn() {
        var baseline = ReaderPositionBaseline(
            progression: 0.1255,
            locatorJSON: Self.sentenceLocator("Chapter_1-sentence320", total: 0.1255)
        )
        baseline.include(progression: 0.1240, locatorJSON: Self.pageLocator(progression: 0.95, total: 0.1240))

        #expect(baseline.contains(progression: 0.1240, locatorJSON: Self.pageLocator(progression: 0.95, total: 0.1240)))
        #expect(
            baseline.contains(
                progression: 0.1240,
                locatorJSON: Self.pageLocator(progression: 0.95, total: 0.1240, highlight: "A warm feeling crept")
            )
        )
        #expect(!baseline.contains(progression: 0.1262, locatorJSON: Self.pageLocator(progression: 0.97, total: 0.1262)))
    }

    @Test @MainActor func narratedSentenceStaysTheSamePositionAcrossProgressionRounding() {
        let baseline = ReaderPositionBaseline(
            progression: 0.1255,
            locatorJSON: Self.sentenceLocator("Chapter_1-sentence320", total: 0.1255)
        )

        #expect(baseline.contains(progression: 0.1240, locatorJSON: Self.sentenceLocator("Chapter_1-sentence320", total: 0.1240)))
        #expect(!baseline.contains(progression: 0.1240, locatorJSON: Self.sentenceLocator("Chapter_1-sentence321", total: 0.1240)))
    }

    @Test @MainActor func pagedAndUnanchoredPositionsCompareExactly() {
        let comic = ReaderPositionBaseline(progression: 0.3, locatorJSON: "cbz-page:3")
        #expect(comic.contains(progression: 0.3057, locatorJSON: "cbz-page:3"))
        #expect(!comic.contains(progression: 0.4, locatorJSON: "cbz-page:4"))

        let unanchored = ReaderPositionBaseline(progression: 0.42, locatorJSON: nil)
        #expect(unanchored.contains(progression: 0.42, locatorJSON: nil))
        #expect(!unanchored.contains(progression: 0.4201, locatorJSON: nil))
        #expect(!unanchored.contains(progression: 0.42, locatorJSON: Self.pageLocator(progression: 0.2, total: 0.42)))
    }
}
