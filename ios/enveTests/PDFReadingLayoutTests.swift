import Foundation
import Testing

@testable import enve

struct PDFReadingLayoutTests {
    private let twoPage = PDFReadingLayout(twoPageEnabled: true)
    private let coverSeparately = PDFReadingLayout(twoPageEnabled: true, showsCoverSeparately: true)

    @Test func singlePageLayoutLeavesEveryPageAlone() {
        #expect(spreads(pageCount: 6, layout: PDFReadingLayout()) == [0...0, 1...1, 2...2, 3...3, 4...4, 5...5])
        // The cover option has no effect until the two-page view is on.
        #expect(spreads(pageCount: 4, layout: PDFReadingLayout(showsCoverSeparately: true)) == [0...0, 1...1, 2...2, 3...3])
    }

    @Test func twoPageViewPairsFromTheFirstPage() {
        #expect(spreads(pageCount: 6, layout: twoPage) == [0...1, 2...3, 4...5])
        #expect(spreads(pageCount: 7, layout: twoPage) == [0...1, 2...3, 4...5, 6...6])
    }

    @Test func separateCoverKeepsTheFirstPageAloneThenPairs() {
        #expect(spreads(pageCount: 6, layout: coverSeparately) == [0...0, 1...2, 3...4, 5...5])
        #expect(spreads(pageCount: 7, layout: coverSeparately) == [0...0, 1...2, 3...4, 5...6])
    }

    @Test func spreadsClampToTheDocument() {
        #expect(spread(99, pageCount: 6, layout: twoPage) == 4...5)
        #expect(spread(99, pageCount: 6, layout: coverSeparately) == 5...5)
        #expect(spread(-4, pageCount: 6, layout: twoPage) == 0...1)
        #expect(spread(-4, pageCount: 6, layout: coverSeparately) == 0...0)
        #expect(spread(0, pageCount: 1, layout: coverSeparately) == 0...0)
        #expect(spread(3, pageCount: 0, layout: twoPage) == 0...0)
    }

    @Test func pagedTurnsAdvanceAWholeSpreadAndReturnToTheCover() {
        #expect(walk(from: 0, by: 1, pageCount: 6, layout: coverSeparately) == [0, 1, 3, 5])
        #expect(walk(from: 5, by: -1, pageCount: 6, layout: coverSeparately) == [5, 3, 1, 0])
        #expect(walk(from: 0, by: 1, pageCount: 6, layout: twoPage) == [0, 2, 4])
        #expect(walk(from: 4, by: -1, pageCount: 6, layout: twoPage) == [4, 2, 0])
        #expect(walk(from: 0, by: 1, pageCount: 7, layout: twoPage) == [0, 2, 4, 6])
        #expect(walk(from: 0, by: 1, pageCount: 3, layout: PDFReadingLayout()) == [0, 1, 2])
    }

    @Test func turningFromInsideASpreadMovesToTheNeighbouringSpread() {
        #expect(step(from: 2, by: 1, pageCount: 6, layout: coverSeparately) == 3)
        #expect(step(from: 2, by: -1, pageCount: 6, layout: coverSeparately) == 0)
        #expect(step(from: 3, by: 1, pageCount: 6, layout: twoPage) == 4)
        #expect(step(from: 3, by: -1, pageCount: 6, layout: twoPage) == 0)
    }

    @MainActor
    @Test func layoutIsStoredPerBookAndPerProfileAndDefaultsToSinglePages() throws {
        let ownerSuite = "PDFReadingPreferencesStoreTests.owner.\(UUID().uuidString)"
        let childSuite = "PDFReadingPreferencesStoreTests.child.\(UUID().uuidString)"
        let ownerDefaults = try #require(UserDefaults(suiteName: ownerSuite))
        let childDefaults = try #require(UserDefaults(suiteName: childSuite))
        defer {
            ownerDefaults.removePersistentDomain(forName: ownerSuite)
            childDefaults.removePersistentDomain(forName: childSuite)
        }
        let owner = PDFReadingPreferencesStore(defaults: ownerDefaults)
        let child = PDFReadingPreferencesStore(defaults: childDefaults)

        #expect(owner.layout(forBookID: "local:a:manual") == PDFReadingLayout())
        #expect(PDFReadingLayout() == PDFReadingLayout(twoPageEnabled: false, showsCoverSeparately: false))

        owner.setLayout(coverSeparately, forBookID: "local:a:manual")
        #expect(owner.layout(forBookID: "local:a:manual") == coverSeparately)
        #expect(owner.layout(forBookID: "local:a:other") == PDFReadingLayout())
        #expect(child.layout(forBookID: "local:a:manual") == PDFReadingLayout())
        #expect(PDFReadingPreferencesStore(defaults: ownerDefaults).layout(forBookID: "local:a:manual") == coverSeparately)

        owner.setLayout(twoPage, forBookID: "local:a:manual")
        #expect(owner.layout(forBookID: "local:a:manual") == twoPage)
        owner.setLayout(PDFReadingLayout(), forBookID: "local:a:manual")
        #expect(owner.layout(forBookID: "local:a:manual") == PDFReadingLayout())
        #expect(ownerDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("reader.pdf.") }.isEmpty)
    }

    private func spread(_ index: Int, pageCount: Int, layout: PDFReadingLayout) -> ClosedRange<Int> {
        ReaderPagedPagePolicy.pdfSpread(containing: index, pageCount: pageCount, layout: layout)
    }

    private func spreads(pageCount: Int, layout: PDFReadingLayout) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var index = 0
        while index < pageCount {
            let next = spread(index, pageCount: pageCount, layout: layout)
            result.append(next)
            index = next.upperBound + 1
        }
        return result
    }

    private func step(from index: Int, by direction: Int, pageCount: Int, layout: PDFReadingLayout) -> Int {
        ReaderPagedPagePolicy.adjacentPDFPageIndex(from: index, by: direction, pageCount: pageCount, layout: layout)
    }

    private func walk(from index: Int, by direction: Int, pageCount: Int, layout: PDFReadingLayout) -> [Int] {
        var visited = [index]
        while true {
            let next = step(from: visited.last!, by: direction, pageCount: pageCount, layout: layout)
            if next == visited.last! { return visited }
            visited.append(next)
        }
    }
}
