import Foundation
import Logging
import PDFKit
import UIKit

enum ReaderPagedPagePolicy {
    static func effectiveComicLayout(
        appearanceLayout: ReaderComicLayoutOption,
        metadataDirection: ReaderComicLayoutOption?
    ) -> ReaderComicLayoutOption {
        guard let metadataDirection else { return appearanceLayout }
        if appearanceLayout == .scroll { return .scroll }
        return metadataDirection
    }

    static func comicPageStep(
        spreadEnabled: Bool,
        layout: ReaderComicLayoutOption,
        isInterfaceLandscape: Bool
    ) -> Int {
        spreadEnabled && layout != .scroll && isInterfaceLandscape ? 2 : 1
    }

    static func boundedPageIndex(_ index: Int, pageCount: Int) -> Int {
        min(max(0, index), max(pageCount - 1, 0))
    }

    static func alignedComicPageIndex(_ index: Int, pageCount: Int, step: Int) -> Int {
        let bounded = boundedPageIndex(index, pageCount: pageCount)
        return step == 2 ? (bounded / 2) * 2 : bounded
    }

    static func comicVisiblePageRange(pageIndex: Int, pageCount: Int, step: Int) -> ClosedRange<Int> {
        guard step == 2 else { return (pageIndex + 1)...(pageIndex + 1) }
        let endIndex = max(min(pageIndex + 1, max(pageCount - 1, 0)), pageIndex)
        return (pageIndex + 1)...(endIndex + 1)
    }

    static func isComicFormat(_ format: String?) -> Bool {
        let normalized = format?.lowercased()
        return normalized == EbookFormat.cbz.rawValue || normalized == EbookFormat.cbr.rawValue
    }

    static func hasComicExtension(_ candidates: [String?]) -> Bool {
        let extensions = candidates.compactMap { $0?.lowercased() }
        return extensions.contains(EbookFormat.cbz.rawValue)
            || extensions.contains(EbookFormat.cbr.rawValue)
    }

    static func isImageFolder(
        filePath: String?,
        ebookFileURL: URL?,
        isDirectory: (String) -> Bool
    ) -> Bool {
        if let filePath, isDirectory(filePath) { return true }
        return ebookFileURL == nil && filePath != nil
            && EbookFormat.from(fileExtension: "imagefolder") != nil
    }
}

@MainActor
protocol ReaderPagedContentHosting: AnyObject {
    var pagedReaderState: ClassicReaderModel.State { get set }
    var pagedTotalPages: Int { get set }
    var pagedVisiblePageRange: ClosedRange<Int>? { get }
    var pagedCurrentProgress: Double? { get }
    var pagedPublicationFileURL: URL? { get }
    func pagedWillChange()
    func pagedPrepareArtifacts(loadingAnnotations: Bool)
    func pagedApplyPageState(visibleRange: ClosedRange<Int>, progress: Double, sectionTitle: String)
    func pagedHandleTap(at point: CGPoint, in size: CGSize)
}

@MainActor
final class ReaderPagedContentController {
    weak var host: (any ReaderPagedContentHosting)?

    private let book: Book
    private let providerResolver: any LibraryProviderResolving
    private let libraryCache: LibraryBookCache
    private let appearanceController: ReaderAppearanceController

    private(set) var comicPages: [URL] = []
    private(set) var currentComicPageIndex = 0
    private(set) var currentPDFPageIndex = 0
    private(set) var lastStablePDFPageIndex = 0
    private(set) var pdfController: PDFReaderController?
    private var serverEbookFormat: String?
    private var comicMetadataDirection: ReaderComicLayoutOption?
    private var comicLayoutAtMetadataApply: ReaderComicLayoutOption?

    init(
        book: Book,
        providerResolver: any LibraryProviderResolving,
        libraryCache: LibraryBookCache,
        appearanceController: ReaderAppearanceController
    ) {
        self.book = book
        self.providerResolver = providerResolver
        self.libraryCache = libraryCache
        self.appearanceController = appearanceController
    }

    private var appearance: ClassicReaderAppearance { appearanceController.appearance }
    private var totalPages: Int { host?.pagedTotalPages ?? 0 }
    private var visiblePageRange: ClosedRange<Int>? { host?.pagedVisiblePageRange }

    var isComicBook: Bool {
        if isImageFolderBook { return true }
        if [book.ebookFormat, serverEbookFormat].contains(where: ReaderPagedPagePolicy.isComicFormat) {
            return true
        }
        return ReaderPagedPagePolicy.hasComicExtension([
            host?.pagedPublicationFileURL?.pathExtension.lowercased(),
            book.ebookFileURL?.pathExtension.lowercased(),
            book.filePath.flatMap { URL(fileURLWithPath: $0).pathExtension.lowercased() },
            URL(string: book.filePath ?? "")?.pathExtension.lowercased(),
            URL(string: book.title)?.pathExtension.lowercased(),
        ])
    }

    var effectiveComicLayout: ReaderComicLayoutOption {
        ReaderPagedPagePolicy.effectiveComicLayout(
            appearanceLayout: appearance.comicLayout,
            metadataDirection: comicMetadataDirection
        )
    }

    var isRightToLeftPageProgression: Bool {
        isComicBook && effectiveComicLayout == .rightToLeft
    }

    private var isImageFolderBook: Bool {
        ReaderPagedPagePolicy.isImageFolder(
            filePath: book.filePath,
            ebookFileURL: book.ebookFileURL,
            isDirectory: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        )
    }

    private var isEligibleForServerPageStreaming: Bool {
        (book.source == .komga && book.mediaType == .ebook) || isComicBook || isImageFolderBook
    }

    private var comicPageStep: Int {
        ReaderPagedPagePolicy.comicPageStep(
            spreadEnabled: appearance.comicLandscapeSpread,
            layout: effectiveComicLayout,
            isInterfaceLandscape: isInterfaceLandscape
        )
    }

    private var isInterfaceLandscape: Bool {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        {
            if let windowBounds = scene.windows.first(where: { $0.isKeyWindow })?.bounds ?? scene.windows.first?.bounds {
                return windowBounds.width > windowBounds.height
            }
            if #available(iOS 26.0, *) {
                return scene.effectiveGeometry.interfaceOrientation.isLandscape
            }
            let bounds = scene.screen.bounds
            return bounds.width > bounds.height
        }

        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen
        {
            let bounds = screen.bounds
            return bounds.width > bounds.height
        }

        return false
    }

    func refreshServerFormatIfNeeded() async {
        guard book.ebookFormat == nil,
            let provider = providerResolver.provider(for: book.providerId),
            provider.capabilities.contains(.serverPageStreaming),
            let refreshed = try? await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId),
            let format = refreshed.ebookFormat
        else { return }
        serverEbookFormat = format
        libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.ebookFormat = format }
    }

    func openServerStreamedComicIfAvailable() async -> Bool {
        guard let provider = providerResolver.capability(ServerPageProvider.self, for: book),
            provider.capabilities.contains(.serverPageStreaming),
            isEligibleForServerPageStreaming
        else { return false }
        do {
            let pages = try await ServerPageStreamingService.shared.streamedPages(
                for: book,
                provider: provider,
                mode: appearance.comicPageLoadingMode
            )
            guard !pages.isEmpty else { return false }
            host?.pagedWillChange()
            comicPages = pages
            host?.pagedPrepareArtifacts(loadingAnnotations: false)
            host?.pagedTotalPages = pages.count
            let initialPageIndex = ReaderLocatorProgress.restoreComicPageIndex(book: book, totalPages: pages.count)
            host?.pagedReaderState = .readyComic
            setComicPage(initialPageIndex, shouldRecordStats: false)
            return true
        } catch {
            AppLogger.general.error("Server page streaming failed: \(error)")
            return false
        }
    }

    func openComicArchive(at fileURL: URL, initialSelection: EbookReaderInitialSelection?) async throws {
        let stableId = book.stableId
        let pages = try await Task.detached(priority: .userInitiated) {
            try await ComicArchiveService.shared.extractedPages(from: fileURL, bookId: stableId)
        }.value
        guard !pages.isEmpty else {
            throw ClassicReaderError.invalidComicArchive(fileURL.path)
        }

        await applyComicReadingDirectionFromMetadata(archiveURL: fileURL)

        let initialPageIndex =
            initialSelection.map { ReaderPagedPagePolicy.boundedPageIndex($0.chapterIndex, pageCount: pages.count) }
            ?? ReaderLocatorProgress.restoreComicPageIndex(book: book, totalPages: pages.count)
        host?.pagedWillChange()
        comicPages = pages
        host?.pagedPrepareArtifacts(loadingAnnotations: true)
        host?.pagedTotalPages = pages.count
        host?.pagedReaderState = .readyComic
        setComicPage(initialPageIndex, shouldRecordStats: false)
    }

    func openImageFolder(at folderURL: URL, initialSelection: EbookReaderInitialSelection?) async throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let pages =
            contents
            .filter { EbookFormat.isImagePageExtension($0.pathExtension.lowercased()) }
            .sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        guard !pages.isEmpty else {
            throw ClassicReaderError.invalidComicArchive(folderURL.path)
        }

        let initialPageIndex =
            initialSelection.map { ReaderPagedPagePolicy.boundedPageIndex($0.chapterIndex, pageCount: pages.count) }
            ?? ReaderLocatorProgress.restoreComicPageIndex(book: book, totalPages: pages.count)
        host?.pagedWillChange()
        comicPages = pages
        host?.pagedPrepareArtifacts(loadingAnnotations: true)
        host?.pagedTotalPages = pages.count
        host?.pagedReaderState = .readyComic
        setComicPage(initialPageIndex, shouldRecordStats: false)
    }

    func openPDF(at fileURL: URL, initialSelection: EbookReaderInitialSelection?) async throws {
        guard let document = PDFKit.PDFDocument(url: fileURL) else {
            throw ClassicReaderError.invalidPDF(fileURL.path)
        }

        let pageCount = max(document.pageCount, 1)
        let initialPageIndex =
            initialSelection.map { ReaderPagedPagePolicy.boundedPageIndex($0.chapterIndex, pageCount: pageCount) }
            ?? ReaderLocatorProgress.restorePDFPageIndex(book: book, totalPages: pageCount)
        host?.pagedWillChange()
        comicPages = []
        host?.pagedPrepareArtifacts(loadingAnnotations: true)
        host?.pagedTotalPages = pageCount
        lastStablePDFPageIndex = initialPageIndex

        let controller = PDFReaderController(
            document: document,
            initialPageIndex: initialPageIndex,
            scrollEnabled: appearance.pdfScrollEnabled,
            onPageChange: { [weak self] index in
                self?.updatePDFPageState(index)
            },
            onTap: { [weak self] point, size in
                self?.host?.pagedHandleTap(at: point, in: size)
            }
        )
        pdfController = controller

        updatePDFPageState(initialPageIndex, shouldRecordStats: false)

        await ReadingStatsTracker.shared.updateBookTotalPages(bookId: book.id, totalPages: totalPages)

        let pdfChapters = (0..<pageCount).map {
            Chapter(
                id: "page-\($0)",
                start: Double($0) / Double(pageCount),
                end: Double($0 + 1) / Double(pageCount),
                title: "Page \($0 + 1)",
                index: $0
            )
        }
        ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: pdfChapters)

        host?.pagedReaderState = .readyPDF(document)
    }

    private func applyComicReadingDirectionFromMetadata(archiveURL: URL) async {
        let direction = await Task.detached(priority: .userInitiated) {
            await ComicArchiveService.shared.readingDirection(from: archiveURL)
        }.value

        host?.pagedWillChange()
        guard let direction else {
            comicMetadataDirection = nil
            comicLayoutAtMetadataApply = nil
            return
        }

        let layout: ReaderComicLayoutOption
        switch direction {
        case .leftToRight: layout = .leftToRight
        case .rightToLeft: layout = .rightToLeft
        }
        comicMetadataDirection = layout
        comicLayoutAtMetadataApply = appearance.comicLayout
    }

    func appearanceDidChange(_ appearance: ClassicReaderAppearance) {
        guard let baseline = comicLayoutAtMetadataApply,
            appearance.comicLayout != baseline
        else { return }
        host?.pagedWillChange()
        comicMetadataDirection = nil
        comicLayoutAtMetadataApply = nil
    }

    func applyAppearance(_ value: ClassicReaderAppearance) {
        pdfController?.setScrollEnabled(value.pdfScrollEnabled)
    }

    func setComicPage(_ index: Int, shouldRecordStats: Bool = true) {
        guard !comicPages.isEmpty else { return }
        let step = comicPageStep
        let boundedIndex = ReaderPagedPagePolicy.alignedComicPageIndex(
            index,
            pageCount: comicPages.count,
            step: step
        )
        guard boundedIndex != currentComicPageIndex || visiblePageRange == nil else { return }

        host?.pagedWillChange()
        currentComicPageIndex = boundedIndex
        host?.pagedApplyPageState(
            visibleRange: ReaderPagedPagePolicy.comicVisiblePageRange(
                pageIndex: boundedIndex,
                pageCount: comicPages.count,
                step: step
            ),
            progress: ReaderLocatorProgress.comicProgress(pageIndex: boundedIndex, totalPages: totalPages),
            sectionTitle: "Page \(boundedIndex + 1)"
        )
        Task {
            await ServerPageStreamingService.shared.preparePageWindow(around: comicPages[boundedIndex])
        }

        guard shouldRecordStats else { return }
        recordStatsTick()
    }

    func stepComicPage(by direction: Int) {
        setComicPage(currentComicPageIndex + direction * comicPageStep)
    }

    func stepPDFPage(by direction: Int) {
        requestPDFPage(currentPDFPageIndex + direction)
    }

    func seekComicToBookmark(_ bookmark: Bookmark) {
        let fallbackIndex = Int(round(bookmark.position * Double(max(totalPages - 1, 0))))
        setComicPage(ReaderLocatorProgress.parseComicLocator(bookmark.locator) ?? fallbackIndex)
    }

    func seekPDFToBookmark(_ bookmark: Bookmark) {
        let fallbackIndex = Int(round(bookmark.position * Double(max(totalPages - 1, 0))))
        requestPDFPage(ReaderLocatorProgress.parsePDFLocator(bookmark.locator) ?? fallbackIndex)
    }

    func comicArtifactLocation(chapterTitle: String?) -> ReaderArtifactLocation {
        ReaderArtifactLocation(
            position: ReaderLocatorProgress.comicProgress(pageIndex: currentComicPageIndex, totalPages: totalPages),
            locator: ReaderLocatorProgress.makeComicLocator(pageIndex: currentComicPageIndex),
            chapterTitle: chapterTitle
        )
    }

    func pdfArtifactLocation(chapterTitle: String?) -> ReaderArtifactLocation {
        ReaderArtifactLocation(
            position: ReaderLocatorProgress.pdfProgress(pageIndex: currentPDFPageIndex, totalPages: totalPages),
            locator: ReaderLocatorProgress.makePDFLocator(pageIndex: currentPDFPageIndex),
            chapterTitle: chapterTitle
        )
    }

    func endServerPageStreamingSession() {
        ServerPageStreamingService.shared.endSession(for: book)
    }

    private func requestPDFPage(_ index: Int, shouldRecordStats: Bool = true) {
        guard totalPages > 0 else { return }
        let boundedIndex = ReaderPagedPagePolicy.boundedPageIndex(index, pageCount: totalPages)
        pdfController?.goToPage(boundedIndex)
        updatePDFPageState(boundedIndex, shouldRecordStats: shouldRecordStats)
    }

    private func updatePDFPageState(_ index: Int, shouldRecordStats: Bool = true) {
        guard totalPages > 0 else { return }
        let boundedIndex = ReaderPagedPagePolicy.boundedPageIndex(index, pageCount: totalPages)
        lastStablePDFPageIndex = boundedIndex
        guard boundedIndex != currentPDFPageIndex || visiblePageRange == nil else { return }

        host?.pagedWillChange()
        currentPDFPageIndex = boundedIndex
        host?.pagedApplyPageState(
            visibleRange: (boundedIndex + 1)...(boundedIndex + 1),
            progress: ReaderLocatorProgress.pdfProgress(pageIndex: boundedIndex, totalPages: totalPages),
            sectionTitle: "Page \(boundedIndex + 1)"
        )

        guard shouldRecordStats else { return }
        recordStatsTick()
    }

    private func recordStatsTick() {
        let progression = host?.pagedCurrentProgress ?? 0
        Task {
            await ReadingStatsTracker.shared.recordTick(bookId: book.stableId, positionProgression: progression, isReading: true)
            if progression >= 0.99 {
                await ReadingStatsTracker.shared.markBookAsFinished(bookId: book.stableId)
            }
        }
    }
}
