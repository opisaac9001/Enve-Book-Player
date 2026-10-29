import Foundation
import ReadiumShared
import ReadiumZIPFoundation
import Testing

@testable import enve

@MainActor
struct ReaderInitialLocationPolicyTests {
    private static let highlight = "a memorable sentence"

    @Test func foliateCFIOnlyInitialLocationSurvivesWithoutAReadiumLocator() {
        let json = """
            {"href":"","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"cfi":"epubcfi(/6/8!/4/260,/5:18,/5:145)","enveSourceEngine":"foliate"}}
            """
        #expect((try? Locator(jsonString: json)) == nil)
        let candidate = ReaderInitialLocation(locator: nil, locatorJSON: json)
        #expect(ReaderInitialLocationResolver.validating(candidate, readingOrderHrefs: ["chapter.xhtml"]) == candidate)
    }

    @Test func unmarkedCFIOnlyInitialLocationIsRejected() {
        let json = """
            {"href":"","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"cfi":"epubcfi(/6/8!/4/260,/5:18,/5:145)"}}
            """
        let candidate = ReaderInitialLocation(locator: nil, locatorJSON: json)
        #expect(ReaderInitialLocationResolver.validating(candidate, readingOrderHrefs: ["chapter.xhtml"]) == .unresolved)
    }

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

    @Test func aPositionInAnUnnarratedChapterNeverRestoresIntoTheNeighbouringNarratedOne() {
        let readingOrder = ["OEBPS/text/Chapter_1.xhtml", "OEBPS/text/Chapter_2.xhtml"]

        #expect(
            !ReaderReadAloudController.overlayClipKeepsStoredResource(
                clipHref: "../text/Chapter_1.xhtml",
                storedHref: "OEBPS/text/Chapter_2.xhtml",
                readingOrderHrefs: readingOrder
            )
        )
        #expect(
            ReaderReadAloudController.overlayClipKeepsStoredResource(
                clipHref: "../text/Chapter_1.xhtml",
                storedHref: "OEBPS/text/Chapter_1.xhtml",
                readingOrderHrefs: readingOrder
            )
        )
        #expect(
            ReaderReadAloudController.overlayClipKeepsStoredResource(
                clipHref: "../text/Chapter_1.xhtml",
                storedHref: "audiobook://item",
                readingOrderHrefs: readingOrder
            )
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

    @Test func sharedResourceOffsetWinsOverThePercentagePosition() async throws {
        let publication = try sharedPublication()
        let json = #"{"enveSharedPosition":true,"href":"chapter-2.xhtml","type":"application/xhtml+xml","locations":{"progression":0.8,"totalProgression":0.6}}"#
        let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json, syncedProgress: 0.6, in: publication))
        #expect(shared.locator?.href.string == "chapter-2.xhtml")
        #expect(shared.locator?.locations.progression == 0.8)
        #expect(shared.locatorJSON == json)
    }

    @Test func sharedTextAnchorWithoutResourceOffsetIsRetained() async throws {
        let publication = try sharedPublication()
        let json = ##"{"enveSharedPosition":true,"href":"chapter-2.xhtml","type":"application/xhtml+xml","locations":{"cssSelector":"#paragraph","totalProgression":0.75},"text":{"highlight":"Exact passage"}}"##
        let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json, syncedProgress: 0.75, in: publication))
        #expect(shared.locatorJSON == json)
        #expect(shared.locator?.text.highlight == "Exact passage")
    }

    @Test func sharedCFIWithoutResourceKeepsBothCFIAndResolvedPercentage() async throws {
        let publication = try sharedPublication()
        let json = #"{"enveSharedPosition":true,"locations":{"cfi":"epubcfi(/6/4!/4/2/1:7)","enveSourceEngine":"foliate","totalProgression":0.75}}"#
        let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json, syncedProgress: 0.75, in: publication))
        #expect(shared.locator?.href.string == "chapter-2.xhtml")
        #expect(shared.locator?.locations.totalProgression == 0.75)
        #expect(EpubLocationBridge.epubCFI(from: shared.locatorJSON) == "epubcfi(/6/4!/4/2/1:7)")
    }

    @Test func sharedCFIResolvesToTextBeforePercentageFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
            "package.opf": #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata/><manifest><item id="one" href="chapter-1.xhtml" media-type="application/xhtml+xml"/><item id="two" href="chapter-2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#,
            "chapter-1.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p>First chapter.</p></body></html>"#,
            "chapter-2.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p id="target">The exact sentence to restore.</p></body></html>"#,
        ]
        for (path, content) in files { try Data(content.utf8).write(to: contents.appendingPathComponent(path)) }
        let epub = root.appendingPathComponent("fixture.epub")
        try await FileManager.default.zipItem(at: contents, to: epub, shouldKeepParent: false)
        let json = #"{"enveSharedPosition":true,"locations":{"cfi":"epubcfi(/6/4!/4/2[target]/1:4)","enveSourceEngine":"foliate","totalProgression":0.25}}"#
        let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json,
            syncedProgress: 0.25, in: sharedPublication(), epubFileURL: epub))
        #expect(shared.locator?.href.string == "chapter-2.xhtml")
        let restored = try #require(SharedReadingLocator.object(shared.locatorJSON))
        let locations = try #require(restored["locations"] as? [String: Any])
        #expect(locations["cfi"] as? String == "epubcfi(/6/4!/4/2[target]/1:4)")
        #expect(shared.locator?.text.before == "The ")
        #expect(shared.locator?.text.highlight?.hasPrefix("exact sentence to restore.") == true)
    }

    @Test func sharedPercentageResolvesWithoutAResourceEvenForNarratedBooks() async throws {
        let publication = try sharedPublication()
        let json = #"{"enveSharedPosition":true,"locations":{"totalProgression":0.75}}"#
        let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json, syncedProgress: 0.75, in: publication))
        #expect(shared.locator?.href.string == "chapter-2.xhtml")
        #expect(shared.locator?.locations.progression == 0.5)
        #expect(shared.locator?.locations.totalProgression == 0.75)
        #expect(ReaderInitialLocationPolicy.storedRanking(isReadAloudLike: true, syncedProgress: 0.75,
            hasProgressLocator: true, storedProgress: nil, highlight: nil) == [.overlayRestore])
    }

    @Test func sharedStaleResourceFallsBackToTheActualPublicationPercentage() async throws {
        let publication = try sharedPublication()
        let json = #"{"enveSharedPosition":true,"href":"removed.xhtml","type":"application/xhtml+xml","locations":{"progression":0.8,"totalProgression":0.75}}"#
        let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json, syncedProgress: 0.75, in: publication))
        #expect(shared.locator?.href.string == "chapter-2.xhtml")
        #expect(shared.locator?.locations.progression == 0.5)
        #expect(shared.locatorJSON?.contains("removed.xhtml") == false)
    }

    @Test func sharedPercentageIncludesTheBeginningAndEnd() async throws {
        let publication = try sharedPublication()
        for progression in [0.0, 1.0] {
            let json = "{\"enveSharedPosition\":true,\"locations\":{\"totalProgression\":\(progression)}}"
            let shared = try #require(await ReaderInitialLocationResolver.sharedLocation(locatorJSON: json, syncedProgress: progression, in: publication))
            #expect(shared.locator?.href.string == (progression == 0 ? "chapter-1.xhtml" : "chapter-2.xhtml"))
            #expect(shared.locator?.locations.progression == progression)
            #expect(shared.locator?.locations.totalProgression == progression)
        }
    }

    @Test func unmarkedOrObsoleteSharedLocatorsKeepTheOrdinaryRestorePolicy() async throws {
        let publication = try sharedPublication()
        let unmarked = #"{"href":"chapter-1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"totalProgression":0.25}}"#
        let unmarkedLocation = await ReaderInitialLocationResolver.sharedLocation(locatorJSON: unmarked, syncedProgress: 0.25, in: publication)
        #expect(unmarkedLocation == nil)
        let stale = #"{"enveSharedPosition":true,"href":"chapter-1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"totalProgression":0.25}}"#
        let staleLocation = await ReaderInitialLocationResolver.sharedLocation(locatorJSON: stale, syncedProgress: 0.75, in: publication)
        #expect(staleLocation == nil)
    }

    private func sharedPublication() throws -> Publication {
        let positions = try [[locator(href: "chapter-1.xhtml", progression: 0), locator(href: "chapter-1.xhtml", progression: 0.25)],
                             [locator(href: "chapter-2.xhtml", progression: 0.5), locator(href: "chapter-2.xhtml", progression: 0.75)]]
        return Publication(
            manifest: Manifest(metadata: Metadata(title: "Shared location fixture"), readingOrder: [
                Link(href: "chapter-1.xhtml", mediaType: .xhtml),
                Link(href: "chapter-2.xhtml", mediaType: .xhtml),
            ]),
            servicesBuilder: PublicationServicesBuilder(positions: InMemoryPositionsService.makeFactory(positionsByReadingOrder: positions))
        )
    }
}
