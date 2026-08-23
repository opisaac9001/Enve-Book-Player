import Foundation
import ReadiumShared
import Testing

@testable import enve

@MainActor
struct ReaderTOCIndexTests {
    @Test func flattenAssignsDepthAndFallsBackToTheFileName() {
        let entries = ReaderTOCIndex.flatten([
            Link(href: "OPS/ch1.xhtml", title: "  Chapter One  ", children: [
                Link(href: "OPS/ch1.xhtml#s1", title: "Section")
            ]),
            Link(href: "OPS/ch2.xhtml", title: "   "),
        ])

        #expect(entries.map(\.displayTitle) == ["Chapter One", "Section", "ch2.xhtml"])
        #expect(entries.map(\.depth) == [0, 1, 0])
        #expect(entries[1].id == "1-OPS/ch1.xhtml#s1")
    }

    @Test func hrefNormalizationDropsFragmentsCaseAndRelativePrefixes() {
        #expect(ReaderTOCIndex.normalizedResourcePath("OPS/ch1.xhtml#anchor") == "OPS/ch1.xhtml")
        #expect(ReaderTOCIndex.normalizedChapterHref("./OPS/Chapter%201.xhtml") == "ops/chapter 1.xhtml")
        #expect(ReaderTOCIndex.hrefFromChapterID("ebook-chapter-3-OPS/ch3.xhtml") == "OPS/ch3.xhtml")
        #expect(ReaderTOCIndex.hrefFromChapterID("ebook-chapter-3") == nil)
        #expect(ReaderTOCIndex.hrefFromChapterID("chapter-3-OPS/ch3.xhtml") == nil)
    }

    @Test func buildProgressionsAnchorsEachTOCFileToItsFirstPosition() throws {
        let index = ReaderTOCIndex()
        index.entries = [
            entry(id: "a", title: "One", href: "OPS/ch1.xhtml"),
            entry(id: "b", title: "Two", href: "OPS/ch2.xhtml#part2"),
            entry(id: "c", title: "Orphan", href: "OPS/ch9.xhtml"),
        ]

        let built = try #require(
            index.buildProgressions(
                readingOrder: [Link(href: "OPS/ch1.xhtml"), Link(href: "OPS/ch2.xhtml")],
                readingOrderPositions: [
                    [try locator(totalProgression: 0), try locator(totalProgression: 0.4)],
                    [try locator(totalProgression: 0.5), try locator(totalProgression: 0.9)],
                ]
            )
        )

        #expect(built.map(\.entry.id) == ["a", "b"])
        #expect(built.map(\.progression) == [0, 0.5])
        #expect(index.tickProgressions == [0, 0.5])
    }

    @Test func buildProgressionsSpreadsSiblingEntriesAcrossTheResourceSpan() throws {
        let index = ReaderTOCIndex()
        index.entries = [
            entry(id: "a", title: "One", href: "ch.xhtml#a"),
            entry(id: "b", title: "Two", href: "ch.xhtml#b"),
        ]

        let built = try #require(
            index.buildProgressions(
                readingOrder: [Link(href: "ch.xhtml")],
                readingOrderPositions: [[try locator(totalProgression: 0.2), try locator(totalProgression: 0.6)]]
            )
        )

        #expect(built[0].progression == 0.2)
        #expect(abs(built[1].progression - 0.4) < 1e-9)
    }

    @Test func buildProgressionsReportsNotIndexedWhenThereIsNoTOC() {
        let index = ReaderTOCIndex()

        #expect(index.buildProgressions(readingOrder: [Link(href: "ch.xhtml")], readingOrderPositions: []) == nil)
        #expect(index.progressions.isEmpty)
    }

    @Test func chapterLookupsUseTheProgressionTolerance() throws {
        let index = try indexed()

        #expect(index.chapterIndex(for: nil) == nil)
        #expect(index.chapterIndex(for: 0) == 0)
        #expect(index.chapterIndex(for: 0.298) == 0)
        #expect(index.chapterIndex(for: 0.2999) == 1)
        #expect(index.chapterIndex(for: 0.9) == 2)
        #expect(ReaderTOCIndex().chapterIndex(for: 0.5) == nil)
    }

    @Test func chapterEndProgressionClosesTheFinalChapterAtOne() throws {
        let index = try indexed()

        #expect(index.chapterEndProgression(atChapter: 0) == 0.3)
        #expect(index.chapterEndProgression(atChapter: 2) == 1)
        #expect(index.chapterEndProgression(atChapter: 3) == nil)
    }

    @Test func nextChapterProgressionSkipsTheCurrentBoundary() throws {
        let index = try indexed()

        #expect(index.nextChapterProgression(after: 0) == 0.3)
        #expect(index.nextChapterProgression(after: 0.3) == 0.6)
        #expect(index.nextChapterProgression(after: 0.6) == nil)
        #expect(ReaderTOCIndex().nextChapterProgression(after: 0) == nil)
    }

    @Test func entryLookupPrefersHrefThenResourcePathThenProgression() throws {
        let index = try indexed()

        #expect(index.entry(for: try locator(href: "OPS/Ch2.xhtml"))?.id == "b")
        #expect(index.entry(for: try locator(href: "OPS/ch2.xhtml#other"))?.id == "b")
        #expect(index.entry(for: try locator(href: "OPS/unknown.xhtml", totalProgression: 0.7))?.id == "c")
        #expect(index.entry(for: try locator(href: "ch3.xhtml"))?.id == "c")
        #expect(index.entry(for: try locator(href: "OPS/absent.xhtml")) == nil)
    }

    @Test func fallbackSectionTitleUsesTheProgressionTableThenTheLocatorTitle() throws {
        let index = try indexed()

        #expect(index.fallbackSectionTitle(from: try locator(totalProgression: 0.45)) == "Two")
        #expect(index.fallbackSectionTitle(from: try locator(title: "  Raw Title  ")) == "Raw Title")
        #expect(index.fallbackSectionTitle(from: try locator()) == nil)
    }

    @Test func matchingEntryFallsBackFromChapterIDToIndexToTitle() throws {
        let index = try indexed()

        #expect(index.matchingEntry(for: selection(id: "ebook-chapter-0-OPS/ch3.xhtml", index: 0))?.id == "c")
        #expect(index.matchingEntry(for: selection(id: "unknown", index: 1))?.id == "b")
        #expect(index.matchingEntry(for: selection(id: "unknown", index: 9, title: " two "))?.id == "b")
        #expect(index.matchingEntry(for: selection(id: "unknown", index: 9, title: "")) == nil)
    }

    @Test func fragmentCandidatesOnlyCoverAnchorsInTheVisibleResource() throws {
        let index = ReaderTOCIndex()
        index.entries = [
            entry(id: "a", title: "Whole", href: "OPS/ch1.xhtml"),
            entry(id: "b", title: "Anchored", href: "OPS/ch1.xhtml#s1"),
            entry(id: "c", title: "Empty anchor", href: "OPS/ch1.xhtml#"),
            entry(id: "d", title: "Elsewhere", href: "OPS/ch2.xhtml#s2"),
        ]

        let candidates = index.fragmentTitleCandidates(for: try locator(href: "OPS/ch1.xhtml#current"))

        #expect(candidates.map(\.fragment) == ["s1"])
        #expect(candidates.map(\.title) == ["Anchored"])
    }

    @Test func locatorAtOrBeforeIgnoresTheVeryStartAndClampsToTheFirstPosition() throws {
        let index = ReaderTOCIndex()
        index.loadPositions([[
            try locator(href: "p0", totalProgression: 0.1),
            try locator(href: "p1", totalProgression: 0.5),
            try locator(href: "p2", totalProgression: 0.8),
        ]])

        #expect(index.locatorAtOrBefore(progression: 0.001) == nil)
        #expect(index.locatorAtOrBefore(progression: 0.05)?.href.string == "p0")
        #expect(index.locatorAtOrBefore(progression: 0.6)?.href.string == "p1")
        #expect(index.locatorAtOrBefore(progression: 1)?.href.string == "p2")
        #expect(index.positionLocator(atChapter: 2)?.href.string == "p2")
        #expect(index.positionLocator(atChapter: 3) == nil)
    }

    @Test func pageCountPrefersMarkersAndClearingResetsBothTables() throws {
        let index = ReaderTOCIndex()
        let positions = [[try locator(href: "p0"), try locator(href: "p1"), try locator(href: "p2")]]

        index.loadPositions(positions)
        #expect(index.pageCount == 3)
        #expect(!index.hasPageMarkers)

        index.loadPageMarkers([
            ReaderTOCIndex.PageMarker(label: "i", progression: 0),
            ReaderTOCIndex.PageMarker(label: "ii", progression: 0.5),
        ])
        #expect(index.pageCount == 2)

        index.clearPositions()
        #expect(index.pageCount == 0)
        #expect(!index.hasPageMarkers)
        #expect(index.positionLocators.isEmpty)
    }

    @Test func pageMarkerLookupsAreOneBased() {
        let index = ReaderTOCIndex()
        index.loadPageMarkers([
            ReaderTOCIndex.PageMarker(label: "i", progression: 0),
            ReaderTOCIndex.PageMarker(label: "ii", progression: 0.5),
        ])

        #expect(index.pageNumber(forProgression: 0) == 1)
        #expect(index.pageNumber(forProgression: 0.49) == 1)
        #expect(index.pageNumber(forProgression: 0.5) == 2)
        #expect(index.pageLabel(atPage: 2) == "ii")
        #expect(index.pageLabel(atPage: 3) == nil)
        #expect(index.lastPageLabel == "ii")
        #expect(ReaderTOCIndex().pageNumber(forProgression: 0.5) == nil)
    }

    @Test func everyEntriesAssignmentNotifies() {
        let index = ReaderTOCIndex()
        var notifications = 0
        index.onEntriesChange = { notifications += 1 }

        let loaded = [entry(id: "a", title: "One", href: "ch1.xhtml")]
        index.entries = loaded
        index.entries = loaded
        index.entries = []

        #expect(notifications == 3)
    }

    private func indexed() throws -> ReaderTOCIndex {
        let index = ReaderTOCIndex()
        index.entries = [
            entry(id: "a", title: "One", href: "OPS/ch1.xhtml"),
            entry(id: "b", title: "Two", href: "OPS/ch2.xhtml"),
            entry(id: "c", title: "Three", href: "OPS/ch3.xhtml"),
        ]
        index.buildProgressions(
            readingOrder: [
                Link(href: "OPS/ch1.xhtml"),
                Link(href: "OPS/ch2.xhtml"),
                Link(href: "OPS/ch3.xhtml"),
            ],
            readingOrderPositions: [
                [try locator(totalProgression: 0)],
                [try locator(totalProgression: 0.3)],
                [try locator(totalProgression: 0.6)],
            ]
        )
        return index
    }

    private func entry(id: String, title: String, href: String) -> ClassicTOCEntry {
        ClassicTOCEntry(id: id, displayTitle: title, href: href, level: 0)
    }

    private func selection(id: String, index: Int, title: String = "") -> EbookReaderInitialSelection {
        EbookReaderInitialSelection(chapterID: id, chapterIndex: index, chapterTitle: title, locatorJSON: nil)
    }

    private func locator(
        href: String = "OPS/ch1.xhtml",
        totalProgression: Double? = nil,
        title: String? = nil
    ) throws -> Locator {
        var locations: [String: Any] = [:]
        if let totalProgression { locations["totalProgression"] = totalProgression }
        var json: [String: Any] = ["href": href, "type": "application/xhtml+xml", "locations": locations]
        if let title { json["title"] = title }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try Locator(jsonString: String(decoding: data, as: UTF8.self))
    }
}
