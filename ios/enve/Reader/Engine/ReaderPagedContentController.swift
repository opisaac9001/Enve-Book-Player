import Foundation
import ImageIO
import Logging
import PDFKit
import UIKit

extension ReaderComicLayoutOption {
    init(_ direction: ComicReadingDirection) {
        switch direction {
        case .leftToRight: self = .leftToRight
        case .rightToLeft: self = .rightToLeft
        case .vertical: self = .scroll
        }
    }

    var readingDirection: ComicReadingDirection {
        switch self {
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        case .scroll: .vertical
        }
    }
}

enum ReaderPagedPagePolicy {
    static func autoComicLayout(
        defaultLayout: ReaderComicLayoutOption,
        metadataDirection: ComicReadingDirection?
    ) -> ReaderComicLayoutOption {
        guard let metadataDirection else { return defaultLayout }
        return ReaderComicLayoutOption(metadataDirection)
    }

    static func effectiveComicLayout(
        bookOverride: ComicReadingDirection?,
        defaultLayout: ReaderComicLayoutOption,
        providerDirection: ComicReadingDirection?,
        archiveDirection: ComicReadingDirection?
    ) -> ReaderComicLayoutOption {
        if let bookOverride { return ReaderComicLayoutOption(bookOverride) }
        return autoComicLayout(defaultLayout: defaultLayout, metadataDirection: providerDirection ?? archiveDirection)
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

    // The cover stands alone, then pages pair in order and a wide page restarts the pairing after itself.
    static func comicSpread(
        containing index: Int,
        pageCount: Int,
        step: Int,
        isWidePage: (Int) -> Bool
    ) -> ClosedRange<Int> {
        let bounded = boundedPageIndex(index, pageCount: pageCount)
        guard step == 2, bounded > 0 else { return bounded...bounded }
        var start = 1
        while true {
            let next = start + 1
            let end = next < pageCount && !isWidePage(start) && !isWidePage(next) ? next : start
            if bounded <= end { return start...end }
            start = end + 1
        }
    }

    static func adjacentComicPageIndex(
        from index: Int,
        by direction: Int,
        pageCount: Int,
        step: Int,
        isWidePage: (Int) -> Bool
    ) -> Int {
        let current = comicSpread(containing: index, pageCount: pageCount, step: step, isWidePage: isWidePage)
        let target = direction > 0 ? current.upperBound + 1 : current.lowerBound - 1
        return comicSpread(containing: target, pageCount: pageCount, step: step, isWidePage: isWidePage).lowerBound
    }

    // Mirrors PDFKit's two-up pairing: `displaysAsBook` keeps the first page alone and pairs the rest in order.
    static func pdfSpread(containing index: Int, pageCount: Int, layout: PDFReadingLayout) -> ClosedRange<Int> {
        let bounded = boundedPageIndex(index, pageCount: pageCount)
        guard layout.twoPageEnabled, pageCount > 1 else { return bounded...bounded }
        if layout.showsCoverSeparately, bounded == 0 { return 0...0 }
        let firstPaired = layout.showsCoverSeparately ? 1 : 0
        let start = firstPaired + (bounded - firstPaired) / 2 * 2
        return start...min(start + 1, pageCount - 1)
    }

    static func adjacentPDFPageIndex(from index: Int, by direction: Int, pageCount: Int, layout: PDFReadingLayout) -> Int {
        let current = pdfSpread(containing: index, pageCount: pageCount, layout: layout)
        let target = direction > 0 ? current.upperBound + 1 : current.lowerBound - 1
        return pdfSpread(containing: target, pageCount: pageCount, layout: layout).lowerBound
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
final class ComicWidePageRegistry {
    static let shared = ComicWidePageRegistry()

    private var isWideByURL: [URL: Bool] = [:]

    func isWide(_ url: URL) -> Bool {
        isWideByURL[url] ?? false
    }

    func prepare(_ urls: [URL]) async throws -> Set<URL> {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            var widePages = Set<URL>()
            for url in urls where url.isFileURL {
                try Task.checkCancellation()
                if let size = Self.headerPixelSize(of: url), size.width > size.height { widePages.insert(url) }
            }
            return widePages
        }
        let pages = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return pages
    }

    func forget(_ urls: [URL]) {
        for url in urls { isWideByURL[url] = nil }
    }

    @discardableResult
    func record(_ size: CGSize, for url: URL) -> Bool {
        let wide = size.width > size.height
        isWideByURL[url] = wide
        return wide
    }

    private nonisolated static func headerPixelSize(of url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        // EXIF orientations 5–8 rotate the stored pixels by 90 degrees.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
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
    func pagedApplyPageState(visibleRange: ClosedRange<Int>, progress: Double, sectionTitle: String, isUserNavigation: Bool)
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
    private(set) var lastVisibleComicPageIndex = 0
    private(set) var currentPDFPageIndex = 0
    private(set) var lastStablePDFPageIndex = 0
    private(set) var pdfController: PDFReaderController?
    private(set) var pdfLayout: PDFReadingLayout
    private let pdfPreferences: PDFReadingPreferencesStore
    private var serverEbookFormat: String?
    private var providerReadingDirection: ComicReadingDirection?
    private var archiveReadingDirection: ComicReadingDirection?
    private var providerReadingDirectionLoad: Task<Void, Never>?
    private(set) var comicDirectionOverride: ComicReadingDirection?

    private let streamingPages: ServerPageStreamingService
    private let comicArchive: ComicArchiveService
    private let profileSession: ProfileSession
    private var cacheOwner = UUID().uuidString
    private var archiveTask: Task<[URL], Error>?
    private var localWidePages: Set<URL>?

    init(
        book: Book,
        providerResolver: any LibraryProviderResolving,
        libraryCache: LibraryBookCache,
        appearanceController: ReaderAppearanceController,
        profileSession: ProfileSession = .owner
    ) {
        self.profileSession = profileSession
        streamingPages = profileSession.comicStreamingPages
        comicArchive = ComicArchiveService(cachesDirectory: profileSession.storage.cachesDirectory)
        self.book = book
        self.providerResolver = providerResolver
        self.libraryCache = libraryCache
        self.appearanceController = appearanceController
        comicDirectionOverride = profileSession.comicReadingDirections.direction(forBookID: book.stableId)
        providerReadingDirection = profileSession.comicReadingDirections.providerDirection(forBookID: book.stableId)
        pdfPreferences = PDFReadingPreferencesStore(defaults: profileSession.defaults)
        pdfLayout = pdfPreferences.layout(forBookID: book.stableId)
    }

    private var appearance: ClassicReaderAppearance { appearanceController.appearance }
    private var totalPages: Int { host?.pagedTotalPages ?? 0 }
    private var visiblePageRange: ClosedRange<Int>? { host?.pagedVisiblePageRange }

    var isComicBook: Bool {
        if book.isComic { return true }
        if !comicPages.isEmpty { return true }
        if isImageFolderBook { return true }
        if ReaderPagedPagePolicy.isComicFormat(serverEbookFormat ?? book.ebookFormat) {
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
            bookOverride: comicDirectionOverride,
            defaultLayout: appearance.comicLayout,
            providerDirection: providerReadingDirection,
            archiveDirection: archiveReadingDirection
        )
    }

    var autoComicLayout: ReaderComicLayoutOption {
        ReaderPagedPagePolicy.autoComicLayout(
            defaultLayout: appearance.comicLayout,
            metadataDirection: providerReadingDirection ?? archiveReadingDirection
        )
    }

    func setComicDirectionOverride(_ direction: ComicReadingDirection?) {
        guard direction != comicDirectionOverride else { return }
        host?.pagedWillChange()
        comicDirectionOverride = direction
        profileSession.comicReadingDirections.setDirection(direction, forBookID: book.stableId)
        refreshVisibleComicSpread()
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
        guard !book.isComic, book.ebookFormat == nil || book.ebookFormat?.lowercased() == "epub",
            let provider = providerResolver.provider(for: book.providerId),
            provider.capabilities.contains(.serverPageStreaming),
            let refreshed = try? await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId),
            let format = refreshed.ebookFormat
        else { return }
        serverEbookFormat = format
        if format != book.ebookFormat {
            libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.ebookFormat = format }
        }
    }

    func openServerStreamedComicIfAvailable() async throws -> Bool {
        try Task.checkCancellation()
        guard let provider = providerResolver.capability(ServerPageProvider.self, for: book),
            provider.capabilities.contains(.serverPageStreaming)
        else { return false }
        var candidate = book
        candidate.ebookFormat = serverEbookFormat ?? book.ebookFormat
        guard provider.canStreamPages(for: candidate) || isImageFolderBook else { return false }
        _ = loadProviderReadingDirection()
        let pages = try await streamingPages.streamedPages(
            for: book,
            provider: provider,
            mode: appearance.comicPageLoadingMode
        )
        try Task.checkCancellation()
        guard !pages.isEmpty else { throw ClassicReaderError.invalidComicArchive(book.title) }
        host?.pagedWillChange()
        comicPages = pages
        host?.pagedPrepareArtifacts(loadingAnnotations: false)
        host?.pagedTotalPages = pages.count
        let initialPageIndex = ReaderLocatorProgress.restoreComicPageIndex(book: book, totalPages: pages.count)
        host?.pagedReaderState = .readyComic
        setComicPage(initialPageIndex, shouldRecordStats: false)
        return true
    }

    private func loadProviderReadingDirection() -> Task<Void, Never> {
        if let providerReadingDirectionLoad { return providerReadingDirectionLoad }
        let load = Task { [weak self, book, providerResolver] in
            guard let provider = providerResolver.capability(ComicReadingDirectionProvider.self, for: book) else { return }
            do {
                let direction = try await provider.fetchComicReadingDirection(for: book)
                try Task.checkCancellation()
                self?.host?.pagedWillChange()
                self?.providerReadingDirection = direction
                self?.profileSession.comicReadingDirections.setProviderDirection(direction, forBookID: book.stableId)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.general.warning("Comic reading direction unavailable: \(error.localizedDescription)")
            }
        }
        providerReadingDirectionLoad = load
        return load
    }

    func isComicArchiveWithoutEPUBContainer(_ fileURL: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            await self.comicArchive.isComicArchiveWithoutEPUBContainer(fileURL)
        }.value
    }

    func openComicArchive(at fileURL: URL, initialSelection: EbookReaderInitialSelection?) async throws {
        try Task.checkCancellation()
        let stableId = book.stableId
        let owner = cacheOwner
        await profileSession.readingCache.protect(
            [fileURL, comicArchive.cacheDirectory(for: stableId)], owner: owner
        )
        try Task.checkCancellation()
        let extraction = Task.detached(priority: .userInitiated) {
            try await self.comicArchive.extractedPages(from: fileURL, bookId: stableId)
        }
        archiveTask = extraction
        let pages = try await extraction.value
        archiveTask = nil
        localWidePages = try await ComicWidePageRegistry.shared.prepare(pages)
        guard !pages.isEmpty else {
            throw ClassicReaderError.invalidComicArchive(fileURL.path)
        }

        let archiveDirection = await Task.detached(priority: .userInitiated) {
            await self.comicArchive.readingDirection(from: fileURL)
        }.value
        try Task.checkCancellation()
        host?.pagedWillChange()
        archiveReadingDirection = archiveDirection

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
        try Task.checkCancellation()
        let contents = try await Task.detached(priority: .userInitiated) {
            try FileManager().contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }.value
        let pages =
            contents
            .filter { EbookFormat.isImagePageExtension($0.pathExtension.lowercased()) }
            .sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        guard !pages.isEmpty else {
            throw ClassicReaderError.invalidComicArchive(folderURL.path)
        }
        localWidePages = try await ComicWidePageRegistry.shared.prepare(pages)

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
        let currentBook = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        let initialPageIndex =
            initialSelection.map { ReaderPagedPagePolicy.boundedPageIndex($0.chapterIndex, pageCount: pageCount) }
            ?? ReaderLocatorProgress.restorePDFPageIndex(book: currentBook, totalPages: pageCount)
        host?.pagedWillChange()
        comicPages = []
        host?.pagedPrepareArtifacts(loadingAnnotations: true)
        host?.pagedTotalPages = pageCount
        lastStablePDFPageIndex = initialPageIndex

        let controller = PDFReaderController(
            document: document,
            initialPageIndex: initialPageIndex,
            scrollEnabled: appearance.pdfScrollEnabled,
            layout: pdfLayout,
            onPageChange: { [weak self] index in
                self?.updatePDFPageState(index)
            },
            onTap: { [weak self] point, size in
                self?.host?.pagedHandleTap(at: point, in: size)
            }
        )
        pdfController = controller

        updatePDFPageState(initialPageIndex, shouldRecordStats: false)

        await profileSession.readingStats.updateBookTotalPages(bookId: book.id, totalPages: totalPages)

        let pdfChapters = (0..<pageCount).map {
            Chapter(
                id: "page-\($0)",
                start: Double($0) / Double(pageCount),
                end: Double($0 + 1) / Double(pageCount),
                title: "Page \($0 + 1)",
                index: $0
            )
        }
        profileSession.readerArtifacts.saveCachedChapters(bookId: book.id, chapters: pdfChapters)

        host?.pagedReaderState = .readyPDF(document)
    }

    func appearanceDidChange(_ appearance: ClassicReaderAppearance) {
        refreshVisibleComicSpread()
    }

    // Orientation, layout, and spread changes alter which pages share the screen.
    private func refreshVisibleComicSpread() {
        setComicPage(currentComicPageIndex, shouldRecordStats: false)
    }

    func applyAppearance(_ value: ClassicReaderAppearance) {
        pdfController?.configure(scrollEnabled: value.pdfScrollEnabled, layout: pdfLayout)
    }

    // Pairing changes alter which pages share the screen, so the range refreshes without a stats tick.
    func setPDFLayout(_ layout: PDFReadingLayout) {
        guard layout != pdfLayout else { return }
        host?.pagedWillChange()
        pdfLayout = layout
        pdfPreferences.setLayout(layout, forBookID: book.stableId)
        pdfController?.configure(scrollEnabled: appearance.pdfScrollEnabled, layout: layout)
        updatePDFPageState(currentPDFPageIndex, shouldRecordStats: false, preservingProgress: true)
    }

    // The spread's last page drives progress, so a final pair reads as finished.
    func setComicPage(_ index: Int, shouldRecordStats: Bool = true) {
        guard !comicPages.isEmpty else { return }
        let pageIndex = ReaderPagedPagePolicy.boundedPageIndex(index, pageCount: comicPages.count)
        let spread = ReaderPagedPagePolicy.comicSpread(
            containing: pageIndex,
            pageCount: comicPages.count,
            step: comicPageStep,
            isWidePage: isWideComicPage
        )
        let visibleRange = (spread.lowerBound + 1)...(spread.upperBound + 1)
        guard pageIndex != currentComicPageIndex || visiblePageRange != visibleRange else { return }

        host?.pagedWillChange()
        currentComicPageIndex = pageIndex
        lastVisibleComicPageIndex = spread.upperBound
        host?.pagedApplyPageState(
            visibleRange: visibleRange,
            progress: ReaderLocatorProgress.comicProgress(pageIndex: spread.upperBound, totalPages: totalPages),
            sectionTitle: "Page \(pageIndex + 1)",
            isUserNavigation: shouldRecordStats
        )
        let pageURL = comicPages[pageIndex]
        Task {
            await streamingPages.preparePageWindow(around: pageURL)
        }

        guard shouldRecordStats else { return }
        recordStatsTick()
    }

    func stepComicPage(by direction: Int) {
        setComicPage(
            ReaderPagedPagePolicy.adjacentComicPageIndex(
                from: currentComicPageIndex,
                by: direction,
                pageCount: comicPages.count,
                step: comicPageStep,
                isWidePage: isWideComicPage
            )
        )
    }

    private func isWideComicPage(_ index: Int) -> Bool {
        if let localWidePages { return localWidePages.contains(comicPages[index]) }
        return ComicWidePageRegistry.shared.isWide(comicPages[index])
    }

    func stepPDFPage(by direction: Int) {
        requestPDFPage(
            ReaderPagedPagePolicy.adjacentPDFPageIndex(
                from: currentPDFPageIndex,
                by: direction,
                pageCount: totalPages,
                layout: pdfLayout
            )
        )
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

    func comicPageData(at url: URL) async throws -> Data {
        try await streamingPages.pageData(at: url)
    }

    func endServerPageStreamingSession() {
        ComicWidePageRegistry.shared.forget(comicPages)
        localWidePages = nil
        providerReadingDirectionLoad?.cancel()
        providerReadingDirectionLoad = nil
        streamingPages.endSession(for: book)
        let extraction = archiveTask
        extraction?.cancel()
        archiveTask = nil
        let owner = cacheOwner
        cacheOwner = UUID().uuidString
        Task { [cache = profileSession.readingCache] in
            _ = try? await extraction?.value
            await cache.release(owner: owner)
            await cache.trim()
        }
    }

    func requestPDFPage(_ index: Int, shouldRecordStats: Bool = true) {
        guard totalPages > 0 else { return }
        let boundedIndex = ReaderPagedPagePolicy.boundedPageIndex(index, pageCount: totalPages)
        pdfController?.goToPage(boundedIndex)
        updatePDFPageState(boundedIndex, shouldRecordStats: shouldRecordStats)
    }

    private func updatePDFPageState(_ index: Int, shouldRecordStats: Bool = true, preservingProgress: Bool = false) {
        guard totalPages > 0 else { return }
        let boundedIndex = ReaderPagedPagePolicy.boundedPageIndex(index, pageCount: totalPages)
        lastStablePDFPageIndex = boundedIndex
        let spread = ReaderPagedPagePolicy.pdfSpread(containing: boundedIndex, pageCount: totalPages, layout: pdfLayout)
        let visibleRange = (spread.lowerBound + 1)...(spread.upperBound + 1)
        guard boundedIndex != currentPDFPageIndex || visiblePageRange != visibleRange else { return }

        let progress = preservingProgress ? host?.pagedCurrentProgress : nil
        host?.pagedWillChange()
        currentPDFPageIndex = boundedIndex
        host?.pagedApplyPageState(
            visibleRange: visibleRange,
            progress: progress ?? ReaderLocatorProgress.pdfProgress(pageIndex: spread.upperBound, totalPages: totalPages),
            sectionTitle: "Page \(boundedIndex + 1)",
            isUserNavigation: shouldRecordStats
        )

        guard shouldRecordStats else { return }
        recordStatsTick()
    }

    private func recordStatsTick() {
        let progression = host?.pagedCurrentProgress ?? 0
        Task {
            await profileSession.readingStats.recordTick(bookId: book.stableId, positionProgression: progression, isReading: true)
            if progression >= Book.finishedProgressThreshold {
                await profileSession.readingStats.markBookAsFinished(bookId: book.stableId)
            }
        }
    }
}
