import Foundation
import Testing

@testable import enve

struct ReaderPagedPagePolicyTests {
    @Test func spreadsRequireSpreadsAPagedLayoutAndALandscapeInterface() {
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .leftToRight, isInterfaceLandscape: true) == 2)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .rightToLeft, isInterfaceLandscape: true) == 2)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .scroll, isInterfaceLandscape: true) == 1)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: true, layout: .leftToRight, isInterfaceLandscape: false) == 1)
        #expect(ReaderPagedPagePolicy.comicPageStep(spreadEnabled: false, layout: .rightToLeft, isInterfaceLandscape: true) == 1)
    }

    @Test func spreadsAlwaysStartOnAnEvenPageAndClampToTheArchive() {
        #expect(ReaderPagedPagePolicy.alignedComicPageIndex(5, pageCount: 20, step: 2) == 4)
        #expect(ReaderPagedPagePolicy.alignedComicPageIndex(5, pageCount: 20, step: 1) == 5)
        #expect(ReaderPagedPagePolicy.alignedComicPageIndex(-3, pageCount: 20, step: 2) == 0)
        #expect(ReaderPagedPagePolicy.alignedComicPageIndex(99, pageCount: 20, step: 2) == 18)
        #expect(ReaderPagedPagePolicy.alignedComicPageIndex(99, pageCount: 21, step: 2) == 20)
        #expect(ReaderPagedPagePolicy.alignedComicPageIndex(99, pageCount: 1, step: 2) == 0)
    }

    @Test func pageIndexClampingSurvivesAnEmptyPageList() {
        #expect(ReaderPagedPagePolicy.boundedPageIndex(4, pageCount: 0) == 0)
        #expect(ReaderPagedPagePolicy.boundedPageIndex(-4, pageCount: 10) == 0)
        #expect(ReaderPagedPagePolicy.boundedPageIndex(40, pageCount: 10) == 9)
        #expect(ReaderPagedPagePolicy.boundedPageIndex(4, pageCount: 10) == 4)
    }

    @Test func visiblePageRangesPairOnlyWhileASpreadHasASecondPage() {
        #expect(ReaderPagedPagePolicy.comicVisiblePageRange(pageIndex: 4, pageCount: 20, step: 2) == 5...6)
        #expect(ReaderPagedPagePolicy.comicVisiblePageRange(pageIndex: 4, pageCount: 20, step: 1) == 5...5)
        #expect(ReaderPagedPagePolicy.comicVisiblePageRange(pageIndex: 0, pageCount: 1, step: 2) == 1...1)
        #expect(ReaderPagedPagePolicy.comicVisiblePageRange(pageIndex: 20, pageCount: 21, step: 2) == 21...21)
    }

    @Test func scrollLayoutOverridesTheComicInfoDirection() {
        #expect(ReaderPagedPagePolicy.effectiveComicLayout(appearanceLayout: .scroll, metadataDirection: .rightToLeft) == .scroll)
        #expect(ReaderPagedPagePolicy.effectiveComicLayout(appearanceLayout: .scroll, metadataDirection: .leftToRight) == .scroll)
        #expect(ReaderPagedPagePolicy.effectiveComicLayout(appearanceLayout: .leftToRight, metadataDirection: .rightToLeft) == .rightToLeft)
        #expect(ReaderPagedPagePolicy.effectiveComicLayout(appearanceLayout: .rightToLeft, metadataDirection: .leftToRight) == .leftToRight)
        #expect(ReaderPagedPagePolicy.effectiveComicLayout(appearanceLayout: .scroll, metadataDirection: nil) == .scroll)
        #expect(ReaderPagedPagePolicy.effectiveComicLayout(appearanceLayout: .rightToLeft, metadataDirection: nil) == .rightToLeft)
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
        #expect(
            ReaderPagedPagePolicy.isImageFolder(
                filePath: "/books/manga",
                ebookFileURL: URL(fileURLWithPath: "/books/manga.cbz"),
                isDirectory: { _ in true }
            )
        )
        #expect(
            ReaderPagedPagePolicy.isImageFolder(
                filePath: "/books/manga",
                ebookFileURL: nil,
                isDirectory: { _ in false }
            )
        )
        #expect(
            !ReaderPagedPagePolicy.isImageFolder(
                filePath: "/books/manga.cbz",
                ebookFileURL: URL(fileURLWithPath: "/books/manga.cbz"),
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
}
