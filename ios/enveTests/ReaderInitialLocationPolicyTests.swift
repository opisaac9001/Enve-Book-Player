import Foundation
import ReadiumShared
import Testing

@testable import enve

@MainActor
struct ReaderInitialLocationPolicyTests {
    private static let highlight = "a memorable sentence"

    private func locator(href: String, progression: Double = 0.25) throws -> Locator {
        try Locator(
            jsonString: """
                {"href":"\(href)","type":"application/xhtml+xml","locations":{"progression":\(progression),"totalProgression":\(progression)}}
                """
        )
    }

    @Test func anExplicitSelectionLocatorWinsAndKeepsItsOwnJSON() throws {
        let json = """
            {"href":"chapter-3.xhtml","type":"application/xhtml+xml","locations":{"progression":0.4,"totalProgression":0.4}}
            """
        let selection = EbookReaderInitialSelection(
            chapterID: "chapter-3",
            chapterIndex: 2,
            chapterTitle: "Three",
            locatorJSON: json
        )

        let selected = try #require(ReaderInitialLocationResolver.selectedLocation(from: selection))

        #expect(selected.locator?.href.string == "chapter-3.xhtml")
        #expect(selected.locatorJSON == json)
    }

    @Test func aSelectionWithoutAUsableLocatorFallsBackToChapterResolution() {
        let missing = EbookReaderInitialSelection(
            chapterID: "chapter-3",
            chapterIndex: 2,
            chapterTitle: "Three",
            locatorJSON: nil
        )
        let malformed = EbookReaderInitialSelection(
            chapterID: "chapter-3",
            chapterIndex: 2,
            chapterTitle: "Three",
            locatorJSON: "{"
        )

        #expect(ReaderInitialLocationResolver.selectedLocation(from: missing) == nil)
        #expect(ReaderInitialLocationResolver.selectedLocation(from: malformed) == nil)
    }

    @Test func aBridgeCheckpointAllowsOneSecondOfClockSkewBeforeTheBookRecord() {
        let lastUpdate = Date(timeIntervalSince1970: 1_000_000)

        #expect(ReaderInitialLocationPolicy.bridgeCheckpointIsCurrent(observedAt: lastUpdate, bookLastUpdate: lastUpdate))
        #expect(
            ReaderInitialLocationPolicy.bridgeCheckpointIsCurrent(
                observedAt: lastUpdate.addingTimeInterval(-1),
                bookLastUpdate: lastUpdate
            )
        )
        #expect(
            !ReaderInitialLocationPolicy.bridgeCheckpointIsCurrent(
                observedAt: lastUpdate.addingTimeInterval(-1.5),
                bookLastUpdate: lastUpdate
            )
        )
        #expect(!ReaderInitialLocationPolicy.bridgeCheckpointIsCurrent(observedAt: nil, bookLastUpdate: lastUpdate))
    }

    @Test func theRawEngineLocatorIsAcceptedOnlyWithinTheTolerance() {
        let raw = 0.5

        #expect(ReaderInitialLocationPolicy.acceptsRawEngineLocator(canonicalProgress: raw, rawProgress: raw))
        #expect(ReaderInitialLocationPolicy.acceptsRawEngineLocator(canonicalProgress: raw + 0.02, rawProgress: raw))
        #expect(ReaderInitialLocationPolicy.acceptsRawEngineLocator(canonicalProgress: 0.1, rawProgress: raw))
        #expect(!ReaderInitialLocationPolicy.acceptsRawEngineLocator(canonicalProgress: 0.521, rawProgress: raw))
    }

    @Test func syncedProgressBeyondTheToleranceSkipsTheStoredLocatorEntirely() {
        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: false,
                syncedProgress: 0.5,
                hasProgressLocator: true,
                storedProgress: 0.4,
                highlight: Self.highlight
            ) == [.progressLocator]
        )

        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: false,
                syncedProgress: 0.41,
                hasProgressLocator: true,
                storedProgress: 0.4,
                highlight: Self.highlight
            ) == [.snippetSearch, .progressLocator, .storedLocator]
        )
    }

    @Test func syncedProgressMustAlsoClearTheFloor() {
        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: false,
                syncedProgress: 0.001,
                hasProgressLocator: true,
                storedProgress: -0.05,
                highlight: Self.highlight
            ) == [.snippetSearch, .progressLocator, .storedLocator]
        )

        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: false,
                syncedProgress: 0.0011,
                hasProgressLocator: true,
                storedProgress: -0.05,
                highlight: Self.highlight
            ) == [.progressLocator]
        )
    }

    @Test func aMediaOverlayBookRestoresOnlyThroughTheOverlayTimeline() {
        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: true,
                syncedProgress: 0.5,
                hasProgressLocator: true,
                storedProgress: 0.1,
                highlight: Self.highlight
            ) == [.overlayRestore]
        )
    }

    @Test func withoutAStoredLocatorOnlyTheProgressLocatorRemains() {
        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: false,
                syncedProgress: 0.3,
                hasProgressLocator: true,
                storedProgress: nil,
                highlight: nil
            ) == [.progressLocator]
        )

        #expect(
            ReaderInitialLocationPolicy.storedRanking(
                isReadAloudLike: false,
                syncedProgress: 0.3,
                hasProgressLocator: false,
                storedProgress: nil,
                highlight: nil
            ).isEmpty
        )
    }

    @Test func snippetSearchNeedsAHighlightLongEnoughToBeDistinctive() {
        #expect(ReaderInitialLocationPolicy.isSnippetSearchable("eight ch"))
        #expect(!ReaderInitialLocationPolicy.isSnippetSearchable("seven c"))
        #expect(!ReaderInitialLocationPolicy.isSnippetSearchable(""))
        #expect(!ReaderInitialLocationPolicy.isSnippetSearchable(nil))
    }

    @Test func aStaleInitialHrefIsRejectedAlongWithItsLocatorJSON() throws {
        let json = """
            {"href":"removed.xhtml","type":"application/xhtml+xml","locations":{"progression":0.25,"totalProgression":0.25}}
            """
        let candidate = ReaderInitialLocation(locator: try Locator(jsonString: json), locatorJSON: json)

        let rejected = ReaderInitialLocationResolver.validating(
            candidate,
            readingOrderHrefs: ["chapter-1.xhtml", "chapter-2.xhtml"]
        )

        #expect(rejected.locator == nil)
        #expect(rejected.locatorJSON == nil)
    }

    @Test func aLiveInitialHrefSurvivesAndBackfillsMissingLocatorJSON() throws {
        let locator = try locator(href: "chapter%202.xhtml")

        let kept = ReaderInitialLocationResolver.validating(
            ReaderInitialLocation(locator: locator, locatorJSON: nil),
            readingOrderHrefs: ["chapter 2.xhtml#anchor"]
        )

        #expect(kept.locator == locator)
        #expect(kept.locatorJSON != nil)
    }
}
