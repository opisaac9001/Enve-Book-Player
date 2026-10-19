import Foundation
import Testing
import UIKit

@testable import enve

struct ReaderPagedPagePolicyTests {
    @Test func spreadsRequireSpreadsAPagedLayoutAndALandscapeInterface() {
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .leftToRight, isInterfaceLandscape: true) == 2)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .rightToLeft, isInterfaceLandscape: true) == 2)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .scroll, isInterfaceLandscape: true) == 1)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .leftToRight, isInterfaceLandscape: false) == 1)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: false, layout: .rightToLeft, isInterfaceLandscape: true) == 1)
    }

    @Test func spreadsKeepTheCoverAloneThenPairInReadingOrder() {
        #expect(spread(0, pageCount: 20) == 0...0)
        #expect(spread(1, pageCount: 20) == 1...2)
        #expect(spread(2, pageCount: 20) == 1...2)
        #expect(spread(5, pageCount: 20) == 5...6)
        #expect(spread(5, pageCount: 20, step: 1) == 5...5)
        #expect(spread(-3, pageCount: 20) == 0...0)
        #expect(spread(99, pageCount: 20) == 19...19)
        #expect(spread(99, pageCount: 21) == 19...20)
        #expect(spread(99, pageCount: 1) == 0...0)
        #expect(spread(0, pageCount: 0) == 0...0)
    }

    @Test func anOddPageCountEndsOnAPair() {
        #expect(spreads(pageCount: 7) == [0...0, 1...2, 3...4, 5...6])
        #expect(spreads(pageCount: 6) == [0...0, 1...2, 3...4, 5...5])
    }

    @Test func aWideFirstContentPageStandsAloneAfterTheCover() {
        #expect(spreads(pageCount: 7, wide: [1]) == [0...0, 1...1, 2...3, 4...5, 6...6])
        #expect(spreads(pageCount: 5, wide: [0]) == [0...0, 1...2, 3...4])
    }

    @Test func aWidePageRestartsThePairingAfterItself() {
        #expect(spreads(pageCount: 8, wide: [2]) == [0...0, 1...1, 2...2, 3...4, 5...6, 7...7])
        #expect(spreads(pageCount: 8, wide: [5]) == [0...0, 1...2, 3...4, 5...5, 6...7])
    }

    @Test func wideCheckIsOnlyAskedAboutPagesInsideTheArchive() {
        var asked: [Int] = []
        _ = ReaderPagedPagePolicy.comicSpread(containing: 20, pageCount: 21, step: 2) { index in
            asked.append(index)
            return false
        }
        #expect(!asked.isEmpty)
        #expect(asked.allSatisfy { (0..<21).contains($0) })
    }

    @MainActor
    @Test func aVisibleFinalSpreadReportsCompletion() throws {
        let finalSpread = spread(5, pageCount: 7)
        #expect(finalSpread == 5...6)
        let snapshot = try #require(
            ReaderLocatorProgress().snapshot(
                state: .readyComic,
                currentProgress: nil,
                currentComicPageIndex: finalSpread.lowerBound,
                lastVisibleComicPageIndex: finalSpread.upperBound,
                lastStablePDFPageIndex: 0,
                totalPages: 7,
                pdfController: nil
            )
        )
        #expect(snapshot.progression == 1)
        #expect(snapshot.progression >= Book.finishedProgressThreshold)
        #expect(snapshot.locatorJSON == ReaderLocatorProgress.makeComicLocator(pageIndex: 5))
    }

    @Test func steppingWalksEveryPageAroundAWidePage() {
        let wide: Set<Int> = [2]
        var forward: [Int] = [0]
        while true {
            let next = step(from: forward.last!, by: 1, pageCount: 7, wide: wide)
            if next == forward.last! { break }
            forward.append(next)
        }
        #expect(forward == [0, 1, 2, 3, 5])

        var backward: [Int] = [6]
        while true {
            let previous = step(from: backward.last!, by: -1, pageCount: 7, wide: wide)
            if previous == backward.last! { break }
            backward.append(previous)
        }
        #expect(backward == [6, 3, 2, 1, 0])
    }

    @Test func singlePageSteppingIgnoresWidePages() {
        #expect(step(from: 2, by: 1, pageCount: 7, step: 1, wide: [2, 3]) == 3)
        #expect(step(from: 3, by: -1, pageCount: 7, step: 1, wide: [2, 3]) == 2)
    }

    @MainActor
    @Test func wideRegistryMeasuresLocalPagesAndTrustsDecodedSizes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let widePage = try writePNG(CGSize(width: 40, height: 20), to: directory.appendingPathComponent("wide.png"))
        let tallPage = try writePNG(CGSize(width: 20, height: 40), to: directory.appendingPathComponent("tall.png"))
        let streamedPage = try #require(URL(string: "enve-comic-page://stream/3"))

        let registry = ComicWidePageRegistry()
        let wide = try await registry.prepare([widePage, tallPage])
        #expect(wide == [widePage])
        #expect(!registry.isWide(widePage))
        #expect(!registry.isWide(tallPage))
        #expect(!registry.isWide(streamedPage))
        #expect(registry.record(CGSize(width: 1600, height: 1200), for: streamedPage))
        #expect(registry.isWide(streamedPage))
        registry.forget([streamedPage])
        #expect(!registry.isWide(streamedPage))
    }

    @Test func pageIndexClampingSurvivesAnEmptyPageList() {
        #expect(ReaderPagedPagePolicy.boundedPageIndex(4, pageCount: 0) == 0)
        #expect(ReaderPagedPagePolicy.boundedPageIndex(-4, pageCount: 10) == 0)
        #expect(ReaderPagedPagePolicy.boundedPageIndex(40, pageCount: 10) == 9)
        #expect(ReaderPagedPagePolicy.boundedPageIndex(4, pageCount: 10) == 4)
    }

    @Test(arguments: ReaderComicLayoutOption.allCases)
    func autoUsesMetadataAndFallsBackToTheSelectedDefault(defaultLayout: ReaderComicLayoutOption) {
        #expect(ReaderPagedPagePolicy.autoComicLayout(defaultLayout: defaultLayout, metadataDirection: .rightToLeft) == .rightToLeft)
        #expect(ReaderPagedPagePolicy.autoComicLayout(defaultLayout: defaultLayout, metadataDirection: .leftToRight) == .leftToRight)
        #expect(ReaderPagedPagePolicy.autoComicLayout(defaultLayout: defaultLayout, metadataDirection: .vertical) == .scroll)
        #expect(ReaderPagedPagePolicy.autoComicLayout(defaultLayout: defaultLayout, metadataDirection: nil) == defaultLayout)
    }

    @Test func directionPrefersTheBookChoiceThenTheServerThenTheFileThenTheDefault() {
        func layout(
            _ bookOverride: ComicReadingDirection?,
            provider: ComicReadingDirection?,
            archive: ComicReadingDirection?,
            defaultLayout: ReaderComicLayoutOption = .leftToRight
        ) -> ReaderComicLayoutOption {
            ReaderPagedPagePolicy.effectiveComicLayout(
                bookOverride: bookOverride,
                defaultLayout: defaultLayout,
                providerDirection: provider,
                archiveDirection: archive
            )
        }
        #expect(layout(.leftToRight, provider: .rightToLeft, archive: .rightToLeft) == .leftToRight)
        #expect(layout(.rightToLeft, provider: nil, archive: nil, defaultLayout: .scroll) == .rightToLeft)
        #expect(layout(.vertical, provider: .rightToLeft, archive: nil) == .scroll)
        #expect(layout(nil, provider: .rightToLeft, archive: .leftToRight) == .rightToLeft)
        #expect(layout(nil, provider: nil, archive: .rightToLeft) == .rightToLeft)
        #expect(layout(nil, provider: nil, archive: nil, defaultLayout: .rightToLeft) == .rightToLeft)
    }

    @MainActor
    @Test func aBookDirectionChoiceIsStoredPerBookAndAutoClearsIt() throws {
        let suiteName = "ComicReadingDirectionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ComicReadingDirectionStore(defaults: defaults)

        store.setProviderDirection(.rightToLeft, forBookID: "komga:manga")
        store.setDirection(.rightToLeft, forBookID: "komga:manga")
        #expect(store.direction(forBookID: "komga:manga") == .rightToLeft)
        #expect(store.direction(forBookID: "komga:western") == nil)
        #expect(ComicReadingDirectionStore(defaults: defaults).direction(forBookID: "komga:manga") == .rightToLeft)

        store.setDirection(nil, forBookID: "komga:manga")
        #expect(store.direction(forBookID: "komga:manga") == nil)
        #expect(store.providerDirection(forBookID: "komga:western") == nil)
        #expect(ComicReadingDirectionStore(defaults: defaults).providerDirection(forBookID: "komga:manga") == .rightToLeft)
        store.setProviderDirection(nil, forBookID: "komga:manga")
        #expect(store.providerDirection(forBookID: "komga:manga") == nil)
        #expect(ReaderComicLayoutOption(ComicReadingDirection.vertical) == .scroll)
        #expect(ReaderComicLayoutOption.scroll.readingDirection == .vertical)
    }

    @Test func comicDetectionAcceptsDeclaredFormatsAndExtensionsRegardlessOfCase() {
        #expect(ReaderPagedPagePolicy.isComicFormat("CBZ"))
        #expect(ReaderPagedPagePolicy.isComicFormat("cbr"))
        #expect(!ReaderPagedPagePolicy.isComicFormat("epub"))
        #expect(!ReaderPagedPagePolicy.isComicFormat(nil))

        #expect(ReaderPagedPagePolicy.hasComicExtension([nil, "cbz"]))
        #expect(ReaderPagedPagePolicy.hasComicExtension(["epub", nil, "cbr"]))
        #expect(!ReaderPagedPagePolicy.hasComicExtension([nil, nil]))
        #expect(ReaderPagedPagePolicy.hasComicExtension(["CBZ"]))
    }

    @Test func imageFolderDetectionPrefersARealDirectoryThenAPathWithoutAnEbookFile() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("books/manga", isDirectory: true)
        let archive = folder.deletingLastPathComponent().appendingPathComponent("manga.cbz")
        #expect(
            ReaderPagedPagePolicy.isImageFolder(
                filePath: folder.path,
                ebookFileURL: archive,
                isDirectory: { _ in true }
            )
        )
        #expect(
            ReaderPagedPagePolicy.isImageFolder(
                filePath: folder.path,
                ebookFileURL: nil,
                isDirectory: { _ in false }
            )
        )
        #expect(
            !ReaderPagedPagePolicy.isImageFolder(
                filePath: archive.path,
                ebookFileURL: archive,
                isDirectory: { _ in false }
            )
        )
        #expect(
            !ReaderPagedPagePolicy.isImageFolder(
                filePath: nil,
                ebookFileURL: nil,
                isDirectory: { _ in true }
            )
        )
    }

    private func spread(_ index: Int, pageCount: Int, step: Int = 2, wide: Set<Int> = []) -> ClosedRange<Int> {
        ReaderPagedPagePolicy.comicSpread(containing: index, pageCount: pageCount, step: step) { wide.contains($0) }
    }

    private func spreads(pageCount: Int, wide: Set<Int> = []) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var index = 0
        while index < pageCount {
            let next = spread(index, pageCount: pageCount, wide: wide)
            result.append(next)
            index = next.upperBound + 1
        }
        return result
    }

    private func step(from index: Int, by direction: Int, pageCount: Int, step: Int = 2, wide: Set<Int>) -> Int {
        ReaderPagedPagePolicy.adjacentComicPageIndex(
            from: index,
            by: direction,
            pageCount: pageCount,
            step: step
        ) { wide.contains($0) }
    }

    private func writePNG(_ size: CGSize, to url: URL) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        try data.write(to: url)
        return url
    }
}
