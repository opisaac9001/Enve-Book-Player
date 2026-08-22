import Combine
import Logging
import PDFKit
@preconcurrency import ReadiumAdapterGCDWebServer
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import SwiftUI
import UIKit
import WebKit

@MainActor
final class ClassicReaderModel: NSObject, ObservableObject, EPUBNavigatorDelegate {
    let book: Book
    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }
    private let readerEngineOverride: ReaderEngineKind?
    private let providerResolver: any LibraryProviderResolving
    private let libraryCache: LibraryBookCache
    private let presentation: AppPresentationState
    private(set) var readerEngineSelection = ReaderEngineSelection(
        preferred: .readium,
        active: .readium,
        fallbackReason: nil
    )
    private var readerEngineAdapter: (any ReaderEngineAdapter)?
    private var epubBridgeSession: EpubBridgeSession?
    private var epubBridgeIdentity: (bookKey: String, publicationFingerprint: String)?
    private var foliateSearchTask: Task<Void, Never>?
    private var ttsStartTask: Task<Void, Never>?
    private var ttsRetargetTask: Task<Void, Never>?
    private var ttsNavigationTask: Task<Void, Never>?
    private var pendingTTSNavigationLocator: Locator?
    private var isTTSFollowSuspendedByUser = false
    private var appliedTTSDecorationLocatorJSON: String?
    private var followedTTSLocatorJSON: String?

    var activeReaderEngineAdapter: (any ReaderEngineAdapter)? { readerEngineAdapter }
    var activeReaderEngineKind: ReaderEngineKind { readerEngineAdapter?.kind ?? readerEngineSelection.active }

    enum State {
        case loading
        case readyEPUB(EPUBNavigatorViewController)
        case readyFoliate(FoliateReaderEngineAdapter)
        case readyPDF(PDFKit.PDFDocument)
        case readyComic
        case readyHTML(WKWebView)
        case failed(Error)

        var isReady: Bool {
            switch self {
            case .readyEPUB, .readyFoliate, .readyPDF, .readyComic, .readyHTML:
                return true
            default:
                return false
            }
        }
    }

    @Published var state: State = .loading
    @Published var totalPages = 0

    var sessionStartDate: Date = Date()
    var sessionStartProgress: Double = 0
    @Published private var sessionSnapshot = ReaderSessionSnapshot()
    var tocEntries: [ClassicTOCEntry] {
        get { tocIndex.entries }
        set { tocIndex.entries = newValue }
    }
    @Published var pendingSelection: ReaderSelectionSnapshot?

    let annotationController: ReaderAnnotationController
    private let locatorProgress: ReaderLocatorProgress
    private let progress: ReaderProgressController
    var lastKnownLocator: Locator? { locatorProgress.lastKnownLocator }
    var lastKnownLocatorJSON: String? { locatorProgress.lastKnownLocatorJSON }
    private let pagedContent: ReaderPagedContentController
    var comicPages: [URL] { pagedContent.comicPages }
    var currentComicPageIndex: Int { pagedContent.currentComicPageIndex }
    var pdfController: PDFReaderController? { pagedContent.pdfController }
    private let appearanceController: ReaderAppearanceController
    var appearance: ClassicReaderAppearance {
        get { appearanceController.appearance }
        set { appearanceController.appearance = newValue }
    }

    private let searchModel = ReaderSearchModel()
    private let navigatorWrapper = ReaderNavigatorWrapper()
    var searchService: EbookSearchService { searchModel.searchService }
    let ttsService = EbookTTSService()

    private let readAloud: ReaderReadAloudController
    var overlayPlayer: MediaOverlayPlayer? { readAloud.player }
    var isReadAloudMode: Bool { readAloud.isActive }
    @Published var isFixedLayoutBook: Bool = false
    var hasMediaOverlay: Bool { readAloud.hasMediaOverlay }
    var overlayClipCount: Int { readAloud.clipCount }
    var currentOverlayClipIndex: Int? { readAloud.currentClipIndex }

    var tapHandler: ((CGPoint, CGSize) -> Void)?
    var doubleTapHandler: ((CGPoint) -> Void)?
    var longPressHandler: (() -> Void)?
    var pendingSingleTapTask: Task<Void, Never>?

    private var cachedCustomFontJS: (familyName: String, js: String)?
    private var lastAppliedScrollEnabled: Bool? = nil

    private let speedTracker = ReadingSpeedTracker()

    private let companion: ReaderCompanionController
    var isReadTogetherActive: Bool { companion.isActive }
    var castingCanvasSize: CGSize? { companion.castingCanvasSize }

    var preferredColorScheme: ColorScheme? {
        appearanceController.preferredColorScheme
    }

    var effectiveAppearance: ClassicReaderAppearance {
        appearanceController.effectiveAppearance
    }

    func updateSystemColorScheme(_ colorScheme: ColorScheme) {
        appearanceController.updateSystemColorScheme(colorScheme)
    }

    func flushPendingAppearanceUpdate() {
        appearanceController.flushPendingUpdate()
    }

    var currentProgress: Double? {
        get { sessionSnapshot.progress }
        set { updateSessionSnapshot { $0.progress = newValue } }
    }

    var visiblePageRange: ClosedRange<Int>? {
        get { sessionSnapshot.visiblePageRange }
        set { updateSessionSnapshot { $0.visiblePageRange = newValue } }
    }

    var currentSectionTitle: String? {
        get { sessionSnapshot.sectionTitle }
        set { updateSessionSnapshot { $0.sectionTitle = newValue } }
    }

    var currentTOCEntryId: String? {
        get { sessionSnapshot.tocEntryId }
        set { updateSessionSnapshot { $0.tocEntryId = newValue } }
    }

    var minutesLeftInChapter: Int? {
        get { sessionSnapshot.minutesLeftInChapter }
        set { updateSessionSnapshot { $0.minutesLeftInChapter = newValue } }
    }

    var minutesLeftInBook: Int? {
        get { sessionSnapshot.minutesLeftInBook }
        set { updateSessionSnapshot { $0.minutesLeftInBook = newValue } }
    }

    var readingSpeedDisplay: String? {
        get { sessionSnapshot.readingSpeedDisplay }
        set { updateSessionSnapshot { $0.readingSpeedDisplay = newValue } }
    }

    private func updateSessionSnapshot(_ update: (inout ReaderSessionSnapshot) -> Void) {
        var next = sessionSnapshot
        update(&next)
        if next != sessionSnapshot {
            sessionSnapshot = next
        }
    }

    var isComicBook: Bool { pagedContent.isComicBook }

    var effectiveComicLayout: ReaderComicLayoutOption { pagedContent.effectiveComicLayout }

    var isRightToLeftPageProgression: Bool { pagedContent.isRightToLeftPageProgression }

    var backwardButtonIconName: String {
        isRightToLeftPageProgression ? "chevron.right" : "chevron.left"
    }

    var forwardButtonIconName: String {
        isRightToLeftPageProgression ? "chevron.left" : "chevron.right"
    }

    var pageSummaryText: String? {
        guard totalPages > 0 else { return nil }
        let unit = !tocIndex.hasPageMarkers && isEPUBState ? "Location" : "Page"
        if let range = visiblePageRange {
            let lo = max(1, range.lowerBound)
            let hi = max(lo, range.upperBound)
            if let current = tocIndex.pageLabel(atPage: lo) {
                let last = tocIndex.lastPageLabel ?? String(totalPages)
                return "Page \(current) of \(last)"
            }
            return lo == hi ? "\(unit) \(lo) of \(totalPages)" : "\(unit)s \(lo)-\(hi) of \(totalPages)"
        }
        let page = max(1, min(totalPages, Int(round((currentProgress ?? 0) * Double(totalPages)))))
        return "\(unit) \(page) of \(totalPages)"
    }

    private var isEPUBState: Bool {
        switch state {
        case .readyEPUB, .readyFoliate: true
        default: false
        }
    }

    var bottomBarPrimarySummaryText: String? {
        chapterPagesLeftSummaryText ?? pageSummaryText
    }

    private var chapterPagesLeftSummaryText: String? {
        guard totalPages > 0,
            let chapterIndex = currentChapterIndex,
            let chapterEndProgression = tocIndex.chapterEndProgression(atChapter: chapterIndex)
        else {
            return nil
        }

        let visibleUpperPage = max(
            1,
            min(
                totalPages,
                visiblePageRange?.upperBound
                    ?? Int(round((currentProgress ?? 0) * Double(totalPages)))
            )
        )
        let chapterEndPage = max(visibleUpperPage, min(totalPages, Int(ceil(chapterEndProgression * Double(totalPages)))))
        let pagesLeft = max(0, chapterEndPage - visibleUpperPage)

        if pagesLeft == 1 {
            return "1 page left in chapter"
        }
        return "\(pagesLeft) pages left in chapter"
    }

    var percentSummaryText: String {
        "\(Int((currentProgress ?? 0) * 100))%"
    }

    var progressSummaryText: String {
        [pageSummaryText, percentSummaryText].compactMap { $0 }.joined(separator: " • ")
    }

    private var hasStarted = false
    private let publicationSession: ReaderPublicationSession
    private let initialLocationResolver: ReaderInitialLocationResolver
    private let tocIndex: ReaderTOCIndex
    private let locationPipeline = ReaderLocationPipeline()
    private let sectionTitleResolver = ReaderSectionTitleResolver()

    var currentChapterIndex: Int? {
        chapterIndex(for: currentProgress)
    }

    private func chapterIndex(for progress: Double?) -> Int? {
        tocIndex.chapterIndex(for: progress)
    }

    var tocTickProgressions: [Double] {
        tocIndex.tickProgressions
    }
    private var pendingInitialChapterSelection: EbookReaderInitialSelection?
    nonisolated(unsafe) private var seekObserver: NSObjectProtocol?
    nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?

    func startTTS(from requestedLocator: Locator? = nil) {
        guard let publication = publicationSession.publication,
            ttsStartTask == nil,
            !ttsService.isPlaying,
            !ttsService.isPaused
        else { return }
        if ttsService.synthesizer == nil {
            ttsService.configure(
                with: publication,
                title: book.title,
                author: book.author ?? book.authors?.joined(separator: ", "),
                artworkURL: book.coverURL,
                contentIdentifier: book.id
            )
        }
        isTTSFollowSuspendedByUser = false

        ttsStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { ttsStartTask = nil }
            await progress.awaitRestoration()
            guard !Task.isCancelled else { return }

            let visibleLocator: Locator?
            if let requestedLocator {
                visibleLocator = requestedLocator
            } else {
                visibleLocator = await readerEngineAdapter?.ttsLocator(at: nil)
            }

            guard !Task.isCancelled else { return }
            let persistedLocator = book.epubLocator
                .flatMap { try? Locator(jsonString: $0) }
            ttsService.startSpeaking(from: visibleLocator ?? persistedLocator)
        }
    }

    func handleReaderDoubleTap(at point: CGPoint) {
        pendingSingleTapTask?.cancel()
        pendingSingleTapTask = nil

        if isReadAloudMode, case .readyEPUB(let navigator) = state {
            handleReadAloudTap(at: point, in: navigator)
            return
        }

        guard ttsService.isPlaying || ttsService.isPaused else { return }
        ttsRetargetTask?.cancel()
        ttsRetargetTask = Task { @MainActor [weak self] in
            guard let self, let adapter = readerEngineAdapter else { return }
            defer { ttsRetargetTask = nil }
            guard let locator = await adapter.ttsLocator(at: point),
                !Task.isCancelled
            else { return }
            isTTSFollowSuspendedByUser = false
            ttsService.stop()
            await Task.yield()
            guard !Task.isCancelled else { return }
            startTTS(from: locator)
        }
    }

    init(
        book: Book,
        initialChapterSelection: EbookReaderInitialSelection? = nil,
        readerEngineOverride: ReaderEngineKind? = nil,
        providerResolver: any LibraryProviderResolving,
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        presentation: AppPresentationState = AppState.shared.presentation,
        bookStore: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.book = book
        self.readerEngineOverride = readerEngineOverride
        self.providerResolver = providerResolver
        self.libraryCache = libraryCache
        self.presentation = presentation
        self.annotationController = ReaderAnnotationController(
            book: book,
            store: ReaderArtifactsAdapter(book: book),
            sync: ProviderReaderNotebookSync(book: book, providerResolver: providerResolver),
            persistVocab: { await bookStore.upsertVocabEntry($0) }
        )
        let appearanceController = ReaderAppearanceController()
        let locatorProgress = ReaderLocatorProgress()
        self.appearanceController = appearanceController
        self.locatorProgress = locatorProgress
        let readAloud = ReaderReadAloudController(
            book: book,
            libraryCache: libraryCache,
            appearanceController: appearanceController,
            locatorProgress: locatorProgress
        )
        self.readAloud = readAloud
        let tocIndex = ReaderTOCIndex()
        self.tocIndex = tocIndex
        self.initialLocationResolver = ReaderInitialLocationResolver(
            book: book,
            libraryCache: libraryCache,
            tocIndex: tocIndex,
            readAloud: readAloud
        )
        self.progress = ReaderProgressController(
            book: book,
            providerResolver: providerResolver,
            libraryCache: libraryCache,
            bookStore: bookStore,
            locatorProgress: locatorProgress,
            readAloud: readAloud
        )
        self.companion = ReaderCompanionController(book: book)
        self.pagedContent = ReaderPagedContentController(
            book: book,
            providerResolver: providerResolver,
            libraryCache: libraryCache,
            appearanceController: appearanceController
        )
        self.pendingInitialChapterSelection = initialChapterSelection
        self.publicationSession = ReaderPublicationSession(
            book: book,
            providerResolver: providerResolver
        )
        super.init()
        currentProgress = book.canonicalEbookProgress
        locationPipeline.reset(initialProgression: book.canonicalEbookProgress)
        annotationController.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        annotationController.onDecorationRefresh = { [weak self] in
            self?.applyAnnotationDecorations()
        }
        annotationController.locationProvider = { [weak self] in
            self?.currentArtifactLocation()
        }
        annotationController.contextProvider = { [weak self] in
            guard let self else { return nil }
            return ReaderAnnotationController.Context(
                selection: readerEngineAdapter?.currentSelection ?? pendingSelection,
                engineKind: activeReaderEngineKind,
                progress: currentProgress,
                chapterTitle: currentSectionTitle
            )
        }
        annotationController.clearSelection = { [weak self] in
            self?.readerEngineAdapter?.clearSelection()
            self?.pendingSelection = nil
        }
        tocIndex.onEntriesChange = { [weak self] in
            self?.objectWillChange.send()
        }
        readAloud.host = self
        companion.host = self
        progress.host = self
        pagedContent.host = self

        appearanceController.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        appearanceController.onApply = { [weak self] appearance in
            self?.applyAppearance(appearance)
        }
        appearanceController.onAppearanceChange = { [weak self] appearance in
            self?.pagedContent.appearanceDidChange(appearance)
        }

        seekObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SeekToEbookBookmark"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bookmark = notification.object as? Bookmark,
                let self = self,
                bookmark.bookId == self.book.stableId || bookmark.bookId == self.book.id
            else { return }
            Task { await self.seekToBookmark(bookmark) }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.readAloud.isPlaybackActive {
                    self.readAloud.syncPositionNow()
                    self.flushProgressToServer(reason: "background")
                } else {
                    _ = await self.readerEngineAdapter?.flushPosition()
                    self.saveProgress()
                    self.flushProgressToServer(reason: "background")
                }
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.readAloud.reconcileAfterForeground()
            }
        }
    }

    deinit {
        ttsStartTask?.cancel()
        ttsRetargetTask?.cancel()
        ttsNavigationTask?.cancel()
        foliateSearchTask?.cancel()
        if let seekObserver { NotificationCenter.default.removeObserver(seekObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        progress.beginHydration()
        publicationSession.begin { [weak self] in await self?.open() }
        progress.beginRestorationWhenReady()
    }

    private func open() async {
        await pagedContent.refreshServerFormatIfNeeded()
        if await pagedContent.openServerStreamedComicIfAvailable() { return }

        let fileURL: URL
        switch await publicationSession.resolveAsset(openStreamed: { session in
            try await self.openPublication(streamedWith: session)
        }) {
        case .file(let url):
            fileURL = url
        case .streamed, .cancelled:
            return
        case .downloadFailed(let error):
            AppLogger.general.error("Reader asset preparation failed: \(error)")
            presentation.presentError(
                title: "Could Not Download Ebook",
                message: "\(book.title): \(error.localizedDescription)"
            )
            state = .failed(error)
            return
        case .notFound:
            let fileNotFoundError = ClassicReaderError.fileNotFound(book.filePath ?? book.ebookFileURL?.path)
            presentation.presentError(
                title: "Ebook Not Found",
                message: "\(book.title): The file could not be located. Try re-downloading it."
            )
            state = .failed(fileNotFoundError)
            return
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            do {
                try await openImageFolder(at: fileURL)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error)
            }
            return
        }

        let ext = fileURL.pathExtension.lowercased()
        if ext == EbookFormat.fb2.rawValue || isFB2File(fileURL) {
            do {
                try await openFB2(at: fileURL)
            } catch is CancellationError {
                return
            } catch {
                presentation.presentError(
                    title: "Could Not Open FictionBook",
                    message: "\(book.title): \(error.localizedDescription)"
                )
                state = .failed(error)
            }
            return
        }

        if ext == EbookFormat.pdf.rawValue {
            do {
                try await openPDF(at: fileURL)
            } catch is CancellationError {
                return
            } catch {
                presentation.presentError(
                    title: "Could Not Open PDF",
                    message: "\(book.title): \(error.localizedDescription)"
                )
                state = .failed(error)
            }
            return
        }

        if ext == EbookFormat.cbz.rawValue || ext == EbookFormat.cbr.rawValue {
            do {
                try await openComicArchive(at: fileURL)
            } catch is CancellationError {
                return
            } catch {
                presentation.presentError(
                    title: "Could Not Open Comic Book",
                    message: "\(book.title): \(error.localizedDescription)"
                )
                state = .failed(error)
            }
            return
        }

        if EbookFormat.mobiExtensions.contains(ext) {
            do {
                let epubURL = try await LocalEbookImporter.shared.convertMobiToEpub(fileURL)
                try await openPublication(at: epubURL)
            } catch is CancellationError {
                return
            } catch let error as MobiConversionError where error == .encrypted {
                presentation.presentError(
                    title: "DRM-Protected File",
                    message: "\(book.title): This Kindle file is DRM-protected and cannot be opened. Please use a DRM-free copy."
                )
                state = .failed(error)
            } catch {
                AppLogger.general.warning("EPUB path failed bookDiagnosticID=\(bookDiagnosticID); trying HTML fallback: \(error.localizedDescription)")
                do {
                    try await openMobiAsHTML(fileURL)
                } catch is CancellationError {
                    return
                } catch {
                    presentation.presentError(
                        title: "Could Not Open Kindle File",
                        message: "\(book.title): \(error.localizedDescription)"
                    )
                    state = .failed(error)
                }
            }
            return
        }

        if !ext.isEmpty && ext != EbookFormat.epub.rawValue {
            let supportedExtensions = EbookFormat.allExtensions
            if !supportedExtensions.contains(ext) {
                let error = ClassicReaderError.unsupportedFormat(ext)
                presentation.presentError(
                    title: "Unsupported File Format",
                    message: "\(book.title): .\(ext) files are not supported. Supported formats: EPUB, PDF, CBZ, CBR, MOBI, AZW3."
                )
                state = .failed(error)
                return
            }
        }

        do {
            try await openPublication(at: fileURL)
        } catch is CancellationError {
            return
        } catch {
            if book.source == .local,
                let stagedURL = try? LocalEbookImporter.shared.copyToCanonicalLocation(fileURL),
                stagedURL != fileURL
            {
                do {
                    try await openPublication(at: stagedURL)
                    Task { @MainActor in
                        libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = stagedURL }
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    presentation.presentError(
                        title: "Could Not Open Ebook",
                        message: "\(book.title): \(readerOpenFailureMessage(error))"
                    )
                    state = .failed(error)
                    return
                }
            }
            publicationSession.discardUnreadableAsset(at: fileURL)
            presentation.presentError(
                title: "Could Not Open Ebook",
                message: "\(book.title): \(readerOpenFailureMessage(error))"
            )
            state = .failed(error)
        }
    }

    private func openMobiAsHTML(_ fileURL: URL) async throws {
        let html = try await MobiConverter.extractHTMLForWebKit(mobiURL: fileURL)
        let wv = await MainActor.run { () -> WKWebView in
            let webView = WKWebView()
            webView.loadHTMLString(html, baseURL: nil)
            return webView
        }
        state = .readyHTML(wv)
    }

    private func openFB2(at fileURL: URL) async throws {
        guard FoliateRuntimeSupport.isPackaged else {
            throw FoliateReaderError.runtimeUnavailable
        }
        annotationController.loadBookmarks()
        annotationController.loadAnnotations()
        tocEntries = []
        totalPages = 0
        isFixedLayoutBook = false
        readerEngineSelection = ReaderEngineSelection(
            preferred: .foliate,
            active: .foliate,
            fallbackReason: nil
        )
        epubBridgeSession?.close()
        epubBridgeSession = nil
        epubBridgeIdentity = nil

        let currentBook = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        let initialLocatorJSON = currentBook.epubLocator.flatMap {
            (try? Locator(jsonString: $0)) == nil ? nil : $0
        }
        let adapter = try await FoliateReaderEngineAdapter.make(
            source: .file(fileURL, fileExtension: EbookFormat.fb2.rawValue),
            initialLocatorJSON: initialLocatorJSON,
            initialProgression: currentBook.canonicalEbookProgress,
            appearance: effectiveAppearance,
            annotations: annotationController.annotations
        )
        readerEngineAdapter = adapter
        state = .readyFoliate(adapter)
        wireFoliateAdapter(adapter)
        AppLogger.library.debug("Using Foliate reader engine bookDiagnosticID=\(bookDiagnosticID)")
    }

    private func openPublication(at fileURL: URL) async throws {
        try await applyOpenedPublication(publicationSession.open(at: fileURL))
    }

    private func openPublication(streamedWith session: GrimmoryEpubStreamingSession) async throws {
        try await applyOpenedPublication(publicationSession.openStreamed(session))
    }

    private func isFB2File(_ fileURL: URL) -> Bool {
        guard fileURL.pathExtension.caseInsensitiveCompare(EbookFormat.epub.rawValue) == .orderedSame,
            let handle = try? FileHandle(forReadingFrom: fileURL)
        else {
            return false
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 65_536)) ?? Data()
        return String(decoding: prefix, as: UTF8.self).range(
            of: "<FictionBook",
            options: .caseInsensitive
        ) != nil
    }

    private func scheduleStreamedPositions() {
        publicationSession.scheduleStreamedPositions { [weak self] publication, positionsByReadingOrder in
            guard let self else { return }
            tocIndex.loadPositions(positionsByReadingOrder)
            tocIndex.loadPageMarkers(await ReaderTOCIndex.resolvePageMarkers(in: publication))
            totalPages = tocIndex.pageCount
            await ReadingStatsTracker.shared.updateBookTotalPages(bookId: book.id, totalPages: totalPages)
            buildTOCProgressionTable(readingOrderPositions: positionsByReadingOrder)
            updateEPUBPageState(using: lastKnownLocator)
        }
    }

    private func applyOpenedPublication(_ opened: ReaderPublicationSession.Opened) async throws {
        let publication = opened.publication
        let fileURL = opened.fileURL
        ttsService.configure(
            with: publication,
            title: book.title,
            author: book.author ?? book.authors?.joined(separator: ", "),
            artworkURL: book.coverURL,
            contentIdentifier: book.id
        )

        let toc = (try? await publication.tableOfContents().get()) ?? []
        if toc.isEmpty {
            tocEntries = publication.readingOrder.enumerated().map { index, link in
                let cleaned = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = (cleaned?.isEmpty == false ? cleaned : nil) ?? "Chapter \(index + 1)"
                return ClassicTOCEntry(id: "spine-\(index)-\(link.href)", link: link, depth: 0, displayTitle: title)
            }
        } else {
            tocEntries = ReaderTOCIndex.flatten(toc)
        }
        let smilResources = publication.resources.filterByMediaType(.smil)
        let manifestHasOverlays =
            !smilResources.isEmpty
            || publication.resources.contains {
                let href = $0.href.lowercased()
                return href.hasSuffix(".smil") || href.contains(".smil#")
            }

        var archiveFeatures: EPUB3Features?
        if !manifestHasOverlays,
            book.epub3Features?.hasMediaOverlay != true,
            let fileURL,
            fileURL.pathExtension.caseInsensitiveCompare("epub") == .orderedSame
        {
            archiveFeatures = await EPUB3SMILParser.detectFeatures(epubFileURL: fileURL)
        }
        let hasOverlayResources =
            manifestHasOverlays
            || archiveFeatures?.hasMediaOverlay == true
        let usesMediaOverlayPosition = book.hasEPUB3MediaOverlay || hasOverlayResources
        isFixedLayoutBook =
            publication.metadata.layout == .fixed
            || archiveFeatures?.hasFixedLayout == true
        annotationController.loadBookmarks()
        annotationController.loadAnnotations()
        try await configureReaderEngine(
            publication: publication,
            fileURL: fileURL,
            hasMediaOverlay: hasOverlayResources
        )

        if fileURL == nil {
            tocIndex.clearPositions()
            totalPages = 0
            scheduleStreamedPositions()
        } else {
            let positionsByReadingOrder = (try? await publication.positionsByReadingOrder().get()) ?? []
            tocIndex.loadPositions(positionsByReadingOrder)
            tocIndex.loadPageMarkers(await ReaderTOCIndex.resolvePageMarkers(in: publication))
            totalPages = tocIndex.pageCount

            await ReadingStatsTracker.shared.updateBookTotalPages(bookId: book.id, totalPages: totalPages)

            buildTOCProgressionTable(readingOrderPositions: positionsByReadingOrder)
            updateEPUBPageState(using: lastKnownLocator)
        }

        if !hasOverlayResources, !tocEntries.isEmpty {
            let bookChapters = tocEntries.map { Chapter(id: $0.id, start: 0, end: 0, title: $0.displayTitle) }
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: bookChapters)
        }

        let initial = await initialLocationResolver.resolve(
            ReaderInitialLocationResolver.Request(
                publication: publication,
                pendingSelection: pendingInitialChapterSelection,
                bridge: epubBridgeSession.map {
                    ReaderInitialLocationResolver.BridgeCheckpoint(
                        observedAt: $0.checkpointObservedAt,
                        locatorJSON: $0.initialReadiumLocatorJSON
                    )
                },
                engineKind: readerEngineSelection.active,
                usesMediaOverlayPosition: usesMediaOverlayPosition
            )
        )
        pendingInitialChapterSelection = nil
        let initialLocation = initial.locator
        let initialLocatorJSON = initial.locatorJSON
        epubBridgeSession?.setRestoreTarget(
            locatorJSON: initialLocatorJSON,
            fallbackProgression: usesMediaOverlayPosition
                ? nil
                : initialLocation?.locations.totalProgression
                    ?? initialLocation?.locations.progression
        )

        progress.noteInitialLocation(initialLocation)
        var readiumNavigator: EPUBNavigatorViewController?
        if readerEngineSelection.active == .foliate {
            do {
                let adapter = try await FoliateReaderEngineAdapter.make(
                    source: publicationSession.foliateSource(),
                    initialLocatorJSON: initialLocatorJSON,
                    initialProgression: usesMediaOverlayPosition
                        ? 0
                        : initialLocation?.locations.totalProgression
                            ?? initialLocation?.locations.progression
                            ?? currentProgress
                            ?? 0,
                    appearance: effectiveAppearance,
                    annotations: annotationController.annotations
                )
                readerEngineAdapter = adapter
                state = .readyFoliate(adapter)
                wireFoliateAdapter(adapter)
                AppLogger.library.debug("Using Foliate reader engine bookDiagnosticID=\(bookDiagnosticID)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogger.library.warning(
                    "Foliate unavailable bookDiagnosticID=\(bookDiagnosticID); falling back to Readium: \(error.localizedDescription)"
                )
                readerEngineSelection = ReaderEngineSelection(
                    preferred: .foliate,
                    active: .readium,
                    fallbackReason: .foliateUnavailable
                )
                restartEpubBridgeSession(engine: .readium)
                epubBridgeSession?.setRestoreTarget(
                    locatorJSON: initialLocatorJSON,
                    fallbackProgression: usesMediaOverlayPosition
                        ? nil
                        : initialLocation?.locations.totalProgression
                            ?? initialLocation?.locations.progression
                )
            }
        }
        if readerEngineSelection.active == .readium {
            let safeInitialLocation =
                initialLocatorJSON
                .flatMap(EpubLocationBridge.locatorForReadiumRestore)
                .flatMap { try? Locator(jsonString: $0) }
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: safeInitialLocation,
                config: makeConfig(from: effectiveAppearance)
            )
            navigator.delegate = self
            readerEngineAdapter = ReadiumReaderEngineAdapter(
                navigator: navigator,
                publication: publication
            )
            state = .readyEPUB(navigator)
            readiumNavigator = navigator
            progress.noteInitialLocation(navigator.currentLocation ?? safeInitialLocation)
            annotationController.observeDecorationInteractions(on: navigator)
        }
        applyAnnotationDecorations()

        lastAppliedScrollEnabled = appearance.scrollEnabled

        applyAppearance(effectiveAppearance)

        if book.source == .storyteller, !book.isFinished {
            Task {
                if let provider = providerResolver.provider(for: book.providerId) as? StorytellerProvider {
                    await provider.syncFinishedStatus(for: book)
                }
            }
        }

        if book.epub3Features == nil {
            let hasOverlays = hasOverlayResources
            let isFixed = isFixedLayoutBook
            if hasOverlays || isFixed {
                let detected =
                    archiveFeatures
                    ?? EPUB3Features(
                        hasMediaOverlay: hasOverlays,
                        hasFixedLayout: isFixed,
                        smilFileCount: smilResources.count
                    )
                readAloud.noteDetectedFeatures(detected)
                Task { @MainActor in
                    libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.epub3Features = detected }
                }
            }
        }

        if hasMediaOverlay, let navigator = readiumNavigator {
            readAloud.beginPreparation(publication: publication, navigator: navigator)
        }

        if let loc = initialLocation {
            refreshSectionTitle(using: loc)
        }
    }

    private func configureReaderEngine(
        publication: Publication,
        fileURL: URL?,
        hasMediaOverlay: Bool
    ) async throws {
        let isEPUB =
            fileURL?.pathExtension.caseInsensitiveCompare("epub") == .orderedSame
            || book.ebookFormat?.caseInsensitiveCompare("epub") == .orderedSame
            || publicationSession.isStreaming
        let context = ReaderEnginePolicy.Context(
            source: book.source,
            isReflowableEPUB: isEPUB && publication.metadata.layout != .fixed,
            isReadAloud: book.isReadAloudBook,
            hasMediaOverlay: hasMediaOverlay || book.epub3Features?.hasMediaOverlay == true,
            isFixedLayout: publication.metadata.layout == .fixed
        )

        readerEngineSelection = ReaderEnginePolicy.selection(
            for: context,
            override: readerEngineOverride,
            foliateAvailable: FoliateRuntimeSupport.isPackaged
        )

        epubBridgeSession?.close()
        epubBridgeSession = nil
        epubBridgeIdentity = nil
        guard context.isReflowableEPUB,
            !context.isReadAloud,
            !context.hasMediaOverlay,
            !context.isFixedLayout,
            context.source != .storyteller
        else {
            return
        }
        guard let fileURL else {
            return
        }

        do {
            let fingerprint = try await EpubPublicationFingerprint.sha256(fileURL: fileURL)
            try Task.checkCancellation()
            epubBridgeIdentity = (
                bookKey: EpubBridgeBookKey.make(for: book, fileURL: fileURL),
                publicationFingerprint: fingerprint
            )
            restartEpubBridgeSession(engine: readerEngineSelection.active)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.library.error(
                "Unable to initialize EPUB engine bridge bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func restartEpubBridgeSession(engine: ReaderEngineKind) {
        progress.resetBridgeWriteState()
        epubBridgeSession?.close()
        guard let epubBridgeIdentity else {
            epubBridgeSession = nil
            return
        }
        epubBridgeSession = EpubBridgeSession(
            bookKey: epubBridgeIdentity.bookKey,
            publicationFingerprint: epubBridgeIdentity.publicationFingerprint,
            engine: engine
        )
    }

    func search(query: String) {
        guard let adapter = readerEngineAdapter, adapter.kind == .foliate else {
            searchModel.search(in: publicationSession.publication, query: query)
            return
        }
        foliateSearchTask?.cancel()
        searchService.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchService.query = trimmed
        searchService.results = []
        searchService.currentIndex = 0
        guard !trimmed.isEmpty else {
            searchService.isSearching = false
            Task {
                await adapter.clearSearch()
            }
            return
        }
        searchService.isSearching = true
        foliateSearchTask = Task { @MainActor [weak self] in
            guard let self,
                let adapter = readerEngineAdapter,
                adapter.kind == .foliate
            else {
                return
            }
            let results = await adapter.search(query: trimmed)
            guard !Task.isCancelled,
                searchService.isSearching,
                searchService.query == trimmed
            else {
                return
            }
            searchService.results = results
            searchService.isSearching = false
        }
    }

    func navigateTo(locator: Locator) {
        guard let adapter = readerEngineAdapter else { return }
        markUserEPUBNavigation()
        Task {
            _ = await adapter.navigate(to: locator, animated: true)
        }
    }

    func navigateTo(locatorJSON: String) {
        guard let adapter = readerEngineAdapter else { return }
        markUserEPUBNavigation()
        Task {
            _ = await adapter.restore(locatorJSON: locatorJSON, animated: true)
        }
    }

    func navigateTo(searchResult: EbookSearchResult) {
        if let locatorJSON = searchResult.locatorJSON,
            let adapter = readerEngineAdapter,
            adapter.kind == .foliate
        {
            markUserEPUBNavigation()
            Task {
                await adapter.clearSearch()
                _ = await adapter.restore(locatorJSON: locatorJSON, animated: true)
            }
        } else {
            if case .readyEPUB(let navigator) = state {
                let style = Decoration.Style.highlight(
                    tint: UIColor(Hearth.accent).withAlphaComponent(0.42),
                    isActive: true
                )
                navigator.apply(
                    decorations: [Decoration(id: "search-current", locator: searchResult.locator, style: style)],
                    in: "reader-search"
                )
            }
            navigateTo(locator: searchResult.locator)
        }
    }

    func clearSearchDecoration() {
        if case .readyEPUB(let navigator) = state {
            navigator.apply(decorations: [], in: "reader-search")
        }
        if let adapter = readerEngineAdapter, adapter.kind == .foliate {
            Task {
                await adapter.clearSearch()
            }
        }
    }

    func seek(toProgress progress: Double) async {
        switch state {
        case .readyEPUB, .readyFoliate:
            guard let adapter = readerEngineAdapter else { return }
            markUserEPUBNavigation()
            clearPendingSelectionForNavigation()
            _ = await adapter.navigate(toFraction: min(max(progress, 0), 1), animated: false)
        default:
            return
        }
    }

    func positionSummaryText(atProgress progress: Double) -> String {
        let bounded = min(max(progress, 0), 1)
        var parts: [String] = []
        if totalPages > 0 {
            let page = max(1, min(totalPages, Int(round(bounded * Double(totalPages)))))
            if let label = tocIndex.pageLabel(atPage: page) {
                let lastPage = tocIndex.lastPageLabel ?? String(totalPages)
                parts.append("Page \(label) of \(lastPage)")
            } else {
                parts.append("Location \(page) of \(totalPages)")
            }
        }
        parts.append("\(Int(bounded * 100))%")
        return parts.joined(separator: " · ")
    }

    private func openComicArchive(at fileURL: URL) async throws {
        try await pagedContent.openComicArchive(at: fileURL, initialSelection: pendingInitialChapterSelection)
        pendingInitialChapterSelection = nil
    }

    private func openPDF(at fileURL: URL) async throws {
        try await pagedContent.openPDF(at: fileURL, initialSelection: pendingInitialChapterSelection)
        pendingInitialChapterSelection = nil
    }

    private func openImageFolder(at folderURL: URL) async throws {
        try await pagedContent.openImageFolder(at: folderURL, initialSelection: pendingInitialChapterSelection)
        pendingInitialChapterSelection = nil
    }

    func pageForward() async {
        switch state {
        case .readyEPUB, .readyFoliate:
            markUserEPUBNavigation()
            clearPendingSelectionForNavigation()
            _ = await readerEngineAdapter?.pageForward(animated: false)
        case .readyPDF:
            clearPendingSelectionForNavigation()
            pagedContent.stepPDFPage(by: 1)
        case .readyComic:
            clearPendingSelectionForNavigation()
            pagedContent.stepComicPage(by: 1)
        default:
            return
        }
    }

    func pageBackward() async {
        switch state {
        case .readyEPUB, .readyFoliate:
            markUserEPUBNavigation()
            clearPendingSelectionForNavigation()
            _ = await readerEngineAdapter?.pageBackward(animated: false)
        case .readyPDF:
            clearPendingSelectionForNavigation()
            pagedContent.stepPDFPage(by: -1)
        case .readyComic:
            clearPendingSelectionForNavigation()
            pagedContent.stepComicPage(by: -1)
        default:
            return
        }
    }

    private func clearPendingSelectionForNavigation(navigator: EPUBNavigatorViewController? = nil) {
        guard pendingSelection != nil else { return }
        if let navigator {
            navigator.clearSelection()
        } else {
            readerEngineAdapter?.clearSelection()
        }
        pendingSelection = nil
    }

    private func markUserEPUBNavigation() {
        if ttsService.isPlaying || ttsService.isPaused {
            isTTSFollowSuspendedByUser = true
            pendingTTSNavigationLocator = nil
            ttsNavigationTask?.cancel()
            ttsNavigationTask = nil
        }
        progress.noteUserNavigation()
        readAloud.clearVisibleClipCache()
    }

    func navigateTo(link: ReadiumShared.Link) async {
        guard let adapter = readerEngineAdapter else { return }
        markUserEPUBNavigation()
        _ = await adapter.navigate(toHref: link.href, animated: false)
    }

    func navigateToTOCEntry(_ entry: ClassicTOCEntry) async {
        switch state {
        case .readyEPUB, .readyFoliate:
            markUserEPUBNavigation()
            if let link = entry.link, let locator = await publicationSession.publication?.locate(link) {
                _ = await readerEngineAdapter?.navigate(to: locator, animated: false)
                return
            }
            _ = await readerEngineAdapter?.navigate(toHref: entry.href, animated: false)
        default:
            break
        }
    }

    func seekToBookmark(_ bookmark: Bookmark) async {
        switch state {
        case .readyEPUB, .readyFoliate:
            guard let locatorJSON = bookmark.locator else { return }
            markUserEPUBNavigation()
            _ = await readerEngineAdapter?.restore(
                locatorJSON: locatorJSON,
                animated: false
            )
        case .readyPDF:
            pagedContent.seekPDFToBookmark(bookmark)
        case .readyComic:
            pagedContent.seekComicToBookmark(bookmark)
        default:
            return
        }
    }

    func startAutoSaveTimer() {
        progress.startAutoSaveTimer()
    }

    func stopAutoSaveTimer() {
        progress.stopAutoSaveTimer()
    }

    func saveProgressResolvingVisibleOverlay() async {
        await progress.saveProgressResolvingVisibleOverlay()
    }

    func saveProgress() {
        progress.saveProgress()
    }

    func flushProgressToServer(reason: String = "close") {
        progress.flushProgressToServer(reason: reason)
    }

    var bookmarkSummaryText: String {
        if let pageSummaryText {
            return pageSummaryText
        }
        return percentSummaryText
    }

    var annotationSummaryText: String {
        [sectionLabelText, bookmarkSummaryText].joined(separator: " • ")
    }

    var sectionLabelText: String {
        if let currentSectionTitle, !currentSectionTitle.isEmpty {
            return currentSectionTitle
        }
        return "Reading"
    }

    private func currentArtifactLocation() -> ReaderArtifactLocation? {
        if let readAloudLocation = readAloud.currentArtifactLocation(
            chapterTitle: currentSectionTitle?.isEmpty == false ? currentSectionTitle : nil
        ) {
            return readAloudLocation
        }
        switch state {
        case .readyEPUB(let nav):
            guard let currentLocation = nav.currentLocation else { return nil }
            let locatorJSON = try? currentLocation.jsonString()
            return ReaderArtifactLocation(
                position: currentLocation.locations.totalProgression ?? currentLocation.locations.progression ?? currentProgress ?? 0,
                locator: EpubLocationBridge.markingSourceEngine(
                    .readium,
                    in: locatorJSON
                ) ?? locatorJSON,
                chapterTitle: currentSectionTitle?.isEmpty == false ? currentSectionTitle : nil
            )
        case .readyFoliate:
            guard let locatorJSON = readerEngineAdapter?.currentLocatorJSON,
                let locator = try? Locator(jsonString: locatorJSON)
            else {
                return nil
            }
            return ReaderArtifactLocation(
                position: locator.locations.totalProgression
                    ?? locator.locations.progression
                    ?? currentProgress
                    ?? 0,
                locator: EpubLocationBridge.markingSourceEngine(
                    .foliate,
                    in: locatorJSON
                ) ?? locatorJSON,
                chapterTitle: currentSectionTitle?.isEmpty == false ? currentSectionTitle : nil
            )
        case .readyPDF:
            return pagedContent.pdfArtifactLocation(
                chapterTitle: currentSectionTitle?.isEmpty == false ? currentSectionTitle : nil
            )
        case .readyComic:
            return pagedContent.comicArtifactLocation(
                chapterTitle: currentSectionTitle?.isEmpty == false ? currentSectionTitle : nil
            )
        default:
            return nil
        }
    }

    func seekToAnnotation(_ annotation: ReaderAnnotation) async {
        guard
            let bookmark = annotation.locator.map({ locator in
                Bookmark(
                    bookId: book.id,
                    position: annotation.position,
                    title: annotation.text,
                    note: annotation.note,
                    locator: locator,
                    mediaType: .ebook,
                    chapterTitle: currentSectionTitle,
                    remoteID: annotation.remoteID,
                    isRemotePlaceholder: annotation.isRemotePlaceholder
                )
            })
        else { return }

        await seekToBookmark(bookmark)
    }

    func applyTTSDecoration(_ locator: Locator?) {
        let locatorJSON = locator.flatMap { try? $0.jsonString() }
        guard locatorJSON != appliedTTSDecorationLocatorJSON else { return }
        appliedTTSDecorationLocatorJSON = locatorJSON
        if locator == nil {
            followedTTSLocatorJSON = nil
            isTTSFollowSuspendedByUser = false
            pendingTTSNavigationLocator = nil
            ttsNavigationTask?.cancel()
            ttsNavigationTask = nil
        }
        if case .readyFoliate = state {
            Task { [weak self] in
                await self?.readerEngineAdapter?.applyTTSDecoration(
                    locatorJSON: locatorJSON
                )
            }
            return
        }
        guard case .readyEPUB(let navigator) = state else { return }
        guard let locator else {
            navigator.apply(decorations: [], in: "tts-highlight")
            return
        }
        let style = Decoration.Style.highlight(tint: UIColor.systemBlue.withAlphaComponent(0.4), isActive: true)
        navigator.apply(decorations: [Decoration(id: "tts-current", locator: locator, style: style)], in: "tts-highlight")
    }

    func followTTSLocator(_ locator: Locator) {
        guard state.isReady, !isTTSFollowSuspendedByUser else { return }
        guard let locatorJSON = try? locator.jsonString(),
            locatorJSON != followedTTSLocatorJSON
        else { return }
        followedTTSLocatorJSON = locatorJSON
        pendingTTSNavigationLocator = locator
        guard ttsNavigationTask == nil else { return }

        ttsNavigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { ttsNavigationTask = nil }

            while !Task.isCancelled, let locator = pendingTTSNavigationLocator {
                pendingTTSNavigationLocator = nil
                guard let adapter = readerEngineAdapter else { return }
                guard let locatorJSON = try? locator.jsonString() else { continue }
                await adapter.followTTS(locatorJSON: locatorJSON)
            }
        }
    }

    private func applyAnnotationDecorations() {
        if case .readyFoliate = state {
            Task { [weak self] in
                guard let self else { return }
                await readerEngineAdapter?.updateAnnotations(annotationController.annotations)
            }
            return
        }
        guard case .readyEPUB(let navigator) = state else { return }
        let decorations = annotationController.readiumDecorations
        navigator.apply(decorations: decorations.annotations, in: ReaderAnnotationController.annotationDecorationGroup)
        navigator.apply(decorations: decorations.noteIndicators, in: ReaderAnnotationController.noteIndicatorDecorationGroup)
    }

    private func effectiveReflowablePreferences(_ appearance: ClassicReaderAppearance) -> EPUBPreferences {
        var prefs = appearance.readiumPreferences
        if let columns = companion.columnOverride, prefs.scroll != true {
            prefs.columnCount = columns
        }
        return prefs
    }

    private func makeConfig(from appearance: ClassicReaderAppearance) -> EPUBNavigatorViewController.Configuration {
        return EPUBNavigatorViewController.Configuration(
            preferences: isFixedLayoutBook
                ? appearance.readiumPreferencesForFixedLayout
                : effectiveReflowablePreferences(appearance),
            editingActions: EditingAction.defaultActions,
            contentInset: [
                .compact: (top: 0, bottom: 0),
                .regular: (top: 0, bottom: 0),
            ],
            decorationTemplates: annotationController.decorationTemplates,
            fontFamilyDeclarations: ReaderFontLibrary.shared.readiumDeclarations
        )
    }

    private func applyAppearance(_ value: ClassicReaderAppearance) {
        AppLogger.library.info(
            "[Font] applyAppearance: usesCustomFont=\(value.usesCustomFont) customFontFamilyName=\(value.customFontFamilyName ?? "nil") fontFamily=\(value.fontFamily.rawValue)"
        )
        if case .readyFoliate = state {
            lastAppliedScrollEnabled = value.scrollEnabled
            Task { [weak self] in
                await self?.readerEngineAdapter?.applyAppearance(value)
            }
        } else if case .readyEPUB(let nav) = state {
            let scrollChanged = lastAppliedScrollEnabled != nil && lastAppliedScrollEnabled != value.scrollEnabled
            lastAppliedScrollEnabled = value.scrollEnabled

            nav.submitPreferences(
                isFixedLayoutBook
                    ? value.readiumPreferencesForFixedLayout
                    : effectiveReflowablePreferences(value)
            )

            if scrollChanged, let locator = nav.currentLocation {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    _ = await nav.go(to: locator, options: .init(animated: false))
                }
            }

            let safeAreaCSS = """
                (function(){
                    if (!document.getElementById('enveeSafeAreaFix')) {
                        var style = document.createElement('style');
                        style.id = 'enveeSafeAreaFix';
                        style.textContent = 'html { padding-top: max(env(safe-area-inset-top), 8px); } body { padding-top: 0; }';
                        document.head.appendChild(style);
                    }
                })();
                """
            Task { _ = await nav.evaluateJavaScript(safeAreaCSS) }

            injectCustomFontCSS(into: nav)
            injectBionicReading(into: nav)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.applyAnnotationDecorations()
            }
        }

        pagedContent.applyAppearance(value)

        readAloud.applySyncOffset(value.readAloudSyncOffset)

        if !value.readAloudHighlightEnabled {
            readAloud.clearHighlight()
        }
    }

    private func injectCustomFontCSS(into nav: EPUBNavigatorViewController) {
        guard appearance.usesCustomFont,
            let fontFamilyName = appearance.customFontFamilyName,
            !fontFamilyName.isEmpty,
            let family = ReaderFontLibrary.shared.fontFamily(named: fontFamilyName)
        else {
            cachedCustomFontJS = nil
            return
        }

        let js: String
        if let cached = cachedCustomFontJS, cached.familyName == fontFamilyName {
            js = cached.js
        } else {
            let safeId =
                "enve-custom-font-"
                + fontFamilyName
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: "-")

            let missingFiles = family.files.filter { !FileManager.default.fileExists(atPath: $0.filePath) }
            if !missingFiles.isEmpty {
                AppLogger.library.warning(
                    "[CustomFont] \(missingFiles.count) font file(s) missing for '\(fontFamilyName)', attempting reinstall..."
                )
                Task {
                    let success = await ReaderFontLibrary.shared.reinstallIfNeeded(fontFamilyName)
                    if success {
                        AppLogger.library.info("[CustomFont] Reinstalled '\(fontFamilyName)', re-injecting...")
                        self.cachedCustomFontJS = nil
                        self.injectCustomFontCSS(into: nav)
                    } else {
                        AppLogger.library.error("[CustomFont] Failed to reinstall '\(fontFamilyName)'")
                    }
                }
                return
            }

            let fontFaceRules = family.files.compactMap { file -> String? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.filePath)) else {
                    AppLogger.library.error(
                        "[CustomFont] Failed to read \(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: file.filePath)))"
                    )
                    return nil
                }
                let ext = URL(fileURLWithPath: file.filePath).pathExtension.lowercased()
                let mimeType = ext == "otf" ? "font/otf" : "font/ttf"
                let formatHint = ext == "otf" ? "opentype" : "truetype"
                let base64 = data.base64EncodedString()
                let style = file.style == .italic ? "italic" : "normal"
                let escapedName = fontFamilyName.replacingOccurrences(of: "'", with: "\\'")
                let weightRange: String
                switch file.weightKind {
                case .standardNormal: weightRange = "400"
                case .standardBold: weightRange = "700"
                case .variable(let r): weightRange = "\(r.lowerBound) \(r.upperBound)"
                }
                return
                    "@font-face { font-family: '\(escapedName)'; src: url('data:\(mimeType);base64,\(base64)') format('\(formatHint)'); font-style: \(style); font-weight: \(weightRange); font-display: block; }"
            }.joined(separator: "\n")
            guard !fontFaceRules.isEmpty else {
                AppLogger.library.error("[CustomFont] No valid font faces generated for '\(fontFamilyName)'")
                return
            }
            let escapedId = safeId.replacingOccurrences(of: "'", with: "\\'")
            let escapedCSS =
                fontFaceRules
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
            js = """
                (function(){
                    if (!document.getElementById('\(escapedId)')) {
                        var s = document.createElement('style');
                        s.id = '\(escapedId)';
                        s.textContent = `\(escapedCSS)`;
                        document.head.appendChild(s);
                    }
                })();
                """
            cachedCustomFontJS = (familyName: fontFamilyName, js: js)
        }

        Task {
            let result = await nav.evaluateJavaScript(js)
            if case .failure(let err) = result {
                AppLogger.library.error("[CustomFont] JS inject failed: \(err)")
            } else {
                AppLogger.library.info("[CustomFont] Injected @font-face for '\(fontFamilyName)'")
            }
        }
    }

    private func injectBionicReading(into nav: EPUBNavigatorViewController) {
        let js = ReaderBionicScript.makeScript(enabled: appearance.bionicReading)
        Task { _ = await nav.evaluateJavaScript(js) }
    }

    func cleanupOverlayPlayer() {
        publicationSession.cleanup()
        ttsStartTask?.cancel()
        ttsStartTask = nil
        ttsRetargetTask?.cancel()
        ttsRetargetTask = nil
        ttsNavigationTask?.cancel()
        ttsNavigationTask = nil
        pendingTTSNavigationLocator = nil
        progress.cleanup()
        epubBridgeSession?.close()
        epubBridgeSession = nil
        epubBridgeIdentity = nil
        readerEngineAdapter?.tearDown()
        readerEngineAdapter = nil
        readAloud.cleanup()
    }

    func toggleReadAloud() {
        readAloud.toggle()
    }

    func syncAudioToVisiblePage() {
        readAloud.syncAudioToVisiblePage()
    }

    func handleReadAloudTap(at point: CGPoint, in navigator: EPUBNavigatorViewController) {
        readAloud.handleTap(at: point, in: navigator)
    }

    func toggleReadAloudPlayback() {
        readAloud.togglePlayback()
    }

    func previousReadAloudSegment() {
        readAloud.previousSegment()
    }

    func nextReadAloudSegment() {
        readAloud.nextSegment()
    }

    func skipReadAloudBackward(seconds: TimeInterval = 15) {
        readAloud.skipBackward(seconds: seconds)
    }

    func skipReadAloudForward(seconds: TimeInterval = 30) {
        readAloud.skipForward(seconds: seconds)
    }

    func setReadAloudSpeed(_ speed: Double) {
        readAloud.setSpeed(speed)
    }

    func toggleReadAloudHighlighting() {
        readAloud.toggleHighlighting()
    }

    func toggleReadAloudSkipSkippables() {
        readAloud.toggleSkipSkippables()
    }

    func addReadAloudBookmark(title: String? = nil, note: String? = nil) {
        readAloud.syncPositionForUserAction()
        annotationController.addBookmark(title: title, note: note)
    }

    private func refreshSectionTitle(using locator: Locator) {
        let fallbackTitle = tocIndex.fallbackSectionTitle(from: locator)
        let tocEntry = tocIndex.entry(for: locator)
        updateSessionSnapshot {
            $0.tocEntryId = tocEntry?.id
            if let fallbackTitle {
                $0.sectionTitle = fallbackTitle
            }
        }

        let lookupKey = "\(ReaderTOCIndex.normalizedResourcePath(locator.href.string))|\(tocEntry?.id ?? "")"
        sectionTitleResolver.scheduleLookup(
            key: lookupKey,
            locator: locator,
            fallbackTitle: fallbackTitle,
            resolveVisibleTitle: { [weak self] locator in
                guard let self else { return nil }
                return await self.visibleTOCTitle(for: locator)
            },
            apply: { [weak self] resolvedTitle in
                guard let self, self.currentSectionTitle != resolvedTitle else { return }
                self.updateSessionSnapshot { $0.sectionTitle = resolvedTitle }
            }
        )
    }

    private func updateEPUBPageState(using locator: Locator?) {
        guard let progression = locator?.locations.totalProgression,
            let page = tocIndex.pageNumber(forProgression: progression)
        else {
            return
        }
        if visiblePageRange != page...page {
            visiblePageRange = page...page
        }
    }

    private func visibleTOCTitle(for locator: Locator) async -> String? {
        guard case .readyEPUB(let navigator) = state else { return nil }

        let candidates = tocIndex.fragmentTitleCandidates(for: locator)
        guard !candidates.isEmpty else { return nil }

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: candidates.map { ["fragment": $0.fragment, "title": $0.title] },
                options: []
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let script = """
            (() => {
              const entries = \(json);
              const viewportTop = 96;
              const viewportLeft = 0;
              const viewportRight = window.innerWidth;
              const viewportBottom = window.innerHeight;
              const visible = [];
              for (const item of entries) {
                const fragment = decodeURIComponent(item.fragment);
                const el = document.getElementById(fragment) || document.getElementsByName(fragment)[0];
                if (!el) continue;
                const rect = el.getBoundingClientRect();
                const intersects = rect.right >= viewportLeft && rect.left <= viewportRight && rect.bottom >= 0 && rect.top <= viewportBottom;
                visible.push({
                  title: item.title,
                  top: rect.top,
                  left: rect.left,
                  intersects: intersects,
                  atOrAboveTop: rect.top <= viewportTop && rect.left <= viewportRight
                });
              }
              if (!visible.length) return null;
              const sortVisible = (a, b) => a.left === b.left ? a.top - b.top : a.left - b.left;
              const passed = visible.filter(v => v.atOrAboveTop).sort(sortVisible);
              if (passed.length) return passed[passed.length - 1].title;
              const inView = visible.filter(v => v.intersects).sort(sortVisible);
              if (inView.length) return inView[0].title;
              visible.sort(sortVisible);
              return visible[0].title;
            })();
            """

        switch await navigator.evaluateJavaScript(script) {
        case .success(let value as String):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    private func buildTOCProgressionTable(readingOrderPositions: [[Locator]]) {
        guard let publication = publicationSession.publication,
            let progressions = tocIndex.buildProgressions(
                readingOrder: publication.readingOrder,
                readingOrderPositions: readingOrderPositions
            )
        else { return }

        LinkedBookProgressCoordinator.shared.recordChapterLandmarks(
            for: book,
            landmarks: progressions.map {
                LinkedBookChapterLandmark(
                    title: $0.entry.displayTitle,
                    progression: $0.progression
                )
            }
        )
    }

    func navigatorContentInset(_ navigator: any VisualNavigator) -> UIEdgeInsets? {
        let remToPt: CGFloat = 16.0
        let topPt = CGFloat(appearance.topMargins) * remToPt
        let bottomPt = CGFloat(appearance.bottomMargins) * remToPt
        let safeTop: CGFloat = {
            guard
                let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                let window = scene.windows.first(where: { $0.isKeyWindow })
            else { return 0 }
            return window.safeAreaInsets.top
        }()
        let safeBottom: CGFloat = {
            guard
                let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                let window = scene.windows.first(where: { $0.isKeyWindow })
            else { return 0 }
            return window.safeAreaInsets.bottom
        }()
        return UIEdgeInsets(
            top: max(safeTop, topPt),
            left: 0,
            bottom: max(safeBottom, bottomPt),
            right: 0
        )
    }

    private func wireFoliateAdapter(_ adapter: FoliateReaderEngineAdapter) {
        adapter.onRelocation = { [weak self] relocation in
            self?.handleEngineRelocation(relocation, readiumNavigator: nil)
        }
        adapter.onSelectionChange = { [weak self] selection in
            self?.pendingSelection = selection
        }
        adapter.onAnnotationActivated = { [weak self] id in
            self?.annotationController.activateAnnotation(id: id)
        }
        adapter.onTap = { [weak self] point, size in
            guard let self else { return }
            pendingSingleTapTask?.cancel()
            pendingSingleTapTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.tapHandler?(point, size)
            }
        }
        adapter.onExternalLink = { url in
            UIApplication.shared.open(url)
        }
    }

    func navigator(_ navigator: any ReadiumNavigator.Navigator, locationDidChange locator: ReadiumShared.Locator) {
        guard let locatorJSON = try? locator.jsonString() else { return }
        handleEngineRelocation(
            ReaderEngineRelocation(
                locator: locator,
                locatorJSON: locatorJSON,
                visiblePageRange: visiblePageRange
            ),
            readiumNavigator: navigator as? EPUBNavigatorViewController
        )
    }

    private func handleEngineRelocation(
        _ relocation: ReaderEngineRelocation,
        readiumNavigator: EPUBNavigatorViewController?
    ) {
        let locator = relocation.locator
        updateEPUBPageState(using: locator)
        if relocation.isUserInitiated {
            markUserEPUBNavigation()
        }
        progress.armBridgeWriteIfUserInteractionPending()
        let enginePageRange: ClosedRange<Int>? = {
            if tocIndex.hasPageMarkers {
                return visiblePageRange
            }
            if readiumNavigator != nil {
                return relocation.visiblePageRange
            }
            guard totalPages > 0 else { return nil }
            let progression =
                locator.locations.totalProgression
                ?? locator.locations.progression
                ?? currentProgress
                ?? 0
            let page = max(
                1,
                min(totalPages, Int(round(progression * Double(totalPages))))
            )
            return page...page
        }()
        if let range = enginePageRange, visiblePageRange != range {
            visiblePageRange = range
        }
        if !readAloud.isActive {
            readAloud.clearVisibleClipCache()
        }
        if let readiumNavigator {
            clearPendingSelectionForNavigation(navigator: readiumNavigator)
        } else {
            clearPendingSelectionForNavigation()
        }

        let update = locationPipeline.observe(
            locator: locator,
            locatorProgress: locatorProgress,
            fallbackProgress: currentProgress,
            publishedProgress: currentProgress,
            chapterIndex: { [weak self] progress in self?.chapterIndex(for: progress) }
        )
        if update.shouldPublishProgress {
            updateSessionSnapshot { $0.progress = update.progression }
        }
        refreshSectionTitle(using: locator)

        readAloud.markManualNavigationIfNeeded(at: locator)

        if let readiumNavigator {
            progress.scheduleLocatorEnrichment(locator: locator, navigator: readiumNavigator)
        }
        progress.noteRelocation(relocation, readiumNavigator: readiumNavigator)

        if let readiumNavigator {
            let resourcePath = ReaderTOCIndex.normalizedResourcePath(locator.href.string)
            guard locationPipeline.shouldEnhanceResource(path: resourcePath) else {
                processLocationSideEffects(update: update)
                return
            }
            injectCustomFontCSS(into: readiumNavigator)
            injectBionicReading(into: readiumNavigator)
        }

        processLocationSideEffects(update: update)
    }

    private func processLocationSideEffects(update: ReaderLocationPipeline.Update) {
        companion.locationDidChange()

        readAloud.handleUserPageTurn()

        if locationPipeline.shouldRecordStats(progression: update.progression) {
            Task {
                await ReadingStatsTracker.shared.recordTick(bookId: book.stableId, positionProgression: update.progression, isReading: true)
                if update.progression >= 0.99 {
                    await ReadingStatsTracker.shared.markBookAsFinished(bookId: book.stableId)
                    if book.source == .storyteller {
                        var finishedBook = book
                        finishedBook.isFinished = true
                        if let provider = providerResolver.provider(for: book.providerId) as? StorytellerProvider {
                            await provider.syncFinishedStatus(for: finishedBook)
                        }
                    }
                }

                if update.progression != update.previousProgression {
                    await speedTracker.recordPageTurn(progress: update.progression)
                    await updateReadingSpeedEstimates(progression: update.progression)
                }
            }
        }

        if let newChapter = update.newChapterIndex,
            let oldChapter = update.previousChapterIndex,
            newChapter != oldChapter,
            progress.hasResolvedInitialHydration
        {
            saveProgress()
            flushProgressToServer(reason: "chapterBoundary")
        }
    }

    private func updateReadingSpeedEstimates(progression: Double) async {
        if await readAloud.updateTimeEstimatesIfOverlayActive(totalProgression: progression) {
            return
        }

        guard let ppm = await speedTracker.progressPerMinute, ppm > 0 else {
            await MainActor.run {
                updateSessionSnapshot {
                    $0.minutesLeftInBook = nil
                    $0.minutesLeftInChapter = nil
                    $0.readingSpeedDisplay = nil
                }
            }
            return
        }

        let bookSec = await speedTracker.timeRemaining(from: progression)
        let bookMin = bookSec.map { max(1, Int(ceil($0 / 60))) }

        let chapterEnd = await MainActor.run { self.tocIndex.nextChapterProgression(after: progression) }
        let chapterMin: Int? = {
            guard let end = chapterEnd, end > progression + 0.0005 else { return nil }
            let secs = (end - progression) / ppm * 60
            return secs > 0 ? max(1, Int(ceil(secs / 60))) : nil
        }()

        let wpm = Int(ppm * 250)
        await MainActor.run {
            self.updateSessionSnapshot {
                $0.minutesLeftInBook = bookMin
                $0.minutesLeftInChapter = chapterMin
                $0.readingSpeedDisplay = "\(wpm) wpm"
            }
        }
    }

    @MainActor
    func saveReadingSpeedRecord() {
        Task {
            let totals = await speedTracker.totals
            guard totals.seconds > 30 else { return }
            let ppm = await speedTracker.progressPerMinute ?? 0
            let record = ReadingSpeedRecord(
                bookId: book.stableId,
                averageProgressPerMinute: ppm,
                totalReadingSeconds: totals.seconds,
                lastUpdated: Date()
            )
            ListeningStatsTracker.shared.recordReadingSession(bookId: book.stableId, record: record)
        }
    }

    func navigator(_ navigator: any SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        pendingSelection = ReaderSelectionSnapshot(selection)
        return false
    }

    func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
        guard !tocIndex.hasPageMarkers else { return }
        let range = navigatorWrapper.visiblePageRange(from: viewport)
        if visiblePageRange != range {
            visiblePageRange = range
        }
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        let size = (navigator as? UIViewController)?.view.bounds.size ?? .zero
        pendingSingleTapTask?.cancel()
        pendingSingleTapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.tapHandler?(point, size)
        }
    }

    func navigator(
        _ navigator: any ReadiumNavigator.Navigator,
        shouldNavigateToNoteAt link: ReadiumShared.Link,
        content: String,
        referrer: String?
    ) -> Bool {
        guard case .readyEPUB(let controller) = state else { return true }
        guard controller.presentedViewController == nil else { return false }

        let footnote = ReadiumFootnoteViewController(content: content, referrer: referrer)
        let navigation = UINavigationController(rootViewController: footnote)
        navigation.modalPresentationStyle = .pageSheet
        navigation.navigationBar.tintColor = UIColor(red: 245 / 255, green: 146 / 255, blue: 26 / 255, alpha: 1)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        controller.present(navigation, animated: true)
        return false
    }

    #if DEBUG
    func activateFirstFootnoteForTesting() async {
        for _ in 0..<50 {
            let activated: Bool
            switch state {
            case .readyEPUB(let navigator):
                let script = """
                    (function() {
                        const link = document.querySelector('#ref-local') ?? Array.from(document.querySelectorAll('a')).find(element => {
                            const semantics = `${element.getAttribute('epub:type') ?? ''} ${element.getAttribute('role') ?? ''}`;
                            return semantics.split(/\\s+/).some(value => value === 'noteref' || value === 'doc-noteref');
                        });
                        if (!link) return false;
                        link.click();
                        return true;
                    })();
                    """
                if case .success(let value) = await navigator.evaluateJavaScript(script) {
                    activated = value as? Bool == true
                } else {
                    activated = false
                }
            case .readyFoliate(let adapter):
                activated = await adapter.activateFirstFootnoteForTesting()
            default:
                return
            }
            if activated { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #endif

    func navigator(_ navigator: any ReadiumNavigator.Navigator, presentError error: ReadiumNavigator.NavigatorError) {
        state = .failed(error)
    }

    func setComicPage(_ index: Int, shouldRecordStats: Bool = true) {
        pagedContent.setComicPage(index, shouldRecordStats: shouldRecordStats)
    }

    func endServerPageStreamingSession() {
        pagedContent.endServerPageStreamingSession()
    }
}

extension ClassicReaderModel {
    func startReadTogether() async {
        await companion.start()
    }

    func stopReadTogether() async {
        await companion.stop()
    }
}

extension ClassicReaderModel: ReaderCompanionHosting {
    var companionIsFixedLayoutBook: Bool { isFixedLayoutBook }

    var companionHasMediaOverlay: Bool { hasMediaOverlay }

    var companionScrollEnabled: Bool { appearance.scrollEnabled }

    var companionOverlayPlayer: MediaOverlayPlayer? { overlayPlayer }

    var companionProgress: Double? { currentProgress }

    var companionTotalPages: Int { totalPages }

    var companionChapterTitle: String? { currentSectionTitle }

    var companionPageSourceViewController: UIViewController? { readerEngineAdapter?.viewController }

    var companionHighlightSourceViewController: UIViewController? {
        guard case .readyEPUB(let navigator) = state else { return nil }
        return navigator
    }

    func companionDidChange() {
        objectWillChange.send()
    }

    func companionPageForward() async {
        await pageForward()
    }

    func companionPageBackward() async {
        await pageBackward()
    }

    func companionToggleReadAloud() {
        toggleReadAloud()
    }

    func companionReapplyReflowableLayout(onLayoutSettled: @escaping @MainActor () async -> Void) {
        guard !isFixedLayoutBook else { return }
        if case .readyFoliate = state, let adapter = readerEngineAdapter {
            var companionAppearance = effectiveAppearance
            if companion.columnOverride != nil, !appearance.scrollEnabled {
                companionAppearance.columnMode = .two
            }
            Task {
                await adapter.applyAppearance(companionAppearance)
                try? await Task.sleep(for: .milliseconds(200))
                await onLayoutSettled()
            }
        } else if case .readyEPUB(let nav) = state {
            nav.submitPreferences(effectiveReflowablePreferences(effectiveAppearance))
            if let locator = nav.currentLocation {
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    _ = await nav.go(to: locator, options: .init(animated: false))
                    await onLayoutSettled()
                }
            }
        }
    }
}

extension ClassicReaderModel: ReaderProgressHosting {
    var progressReaderState: State { state }

    var progressEngineAdapter: (any ReaderEngineAdapter)? { readerEngineAdapter }

    var progressPublication: Publication? { publicationSession.publication }

    var progressPublicationFileURL: URL? { publicationSession.fileURL }

    var progressBridgeSession: EpubBridgeSession? { epubBridgeSession }

    var progressCurrentProgress: Double? {
        get { currentProgress }
        set { currentProgress = newValue }
    }

    var progressObservedProgression: Double? { locationPipeline.latestObservedProgression }

    var progressSectionTitle: String? { currentSectionTitle }

    var progressTotalPages: Int { totalPages }

    var progressComicPageIndex: Int { pagedContent.currentComicPageIndex }

    var progressStablePDFPageIndex: Int { pagedContent.lastStablePDFPageIndex }

    var progressPDFController: PDFReaderController? { pagedContent.pdfController }

    func progressLocatorAtOrBefore(progression: Double) -> Locator? {
        tocIndex.locatorAtOrBefore(progression: progression)
    }
}

extension ClassicReaderModel: ReaderPagedContentHosting {
    var pagedReaderState: State {
        get { state }
        set { state = newValue }
    }

    var pagedTotalPages: Int {
        get { totalPages }
        set { totalPages = newValue }
    }

    var pagedVisiblePageRange: ClosedRange<Int>? { visiblePageRange }

    var pagedCurrentProgress: Double? { currentProgress }

    var pagedPublicationFileURL: URL? { publicationSession.fileURL }

    func pagedWillChange() {
        objectWillChange.send()
    }

    func pagedPrepareArtifacts(loadingAnnotations: Bool) {
        tocEntries = []
        annotationController.loadBookmarks()
        if loadingAnnotations {
            annotationController.loadAnnotations()
        }
    }

    func pagedApplyPageState(visibleRange: ClosedRange<Int>, progress: Double, sectionTitle: String) {
        updateSessionSnapshot {
            $0.visiblePageRange = visibleRange
            $0.progress = progress
            $0.sectionTitle = sectionTitle
            $0.tocEntryId = nil
        }
    }

    func pagedHandleTap(at point: CGPoint, in size: CGSize) {
        tapHandler?(point, size)
    }
}

extension ClassicReaderModel: ReaderReadAloudHosting {
    var readAloudNavigator: EPUBNavigatorViewController? {
        guard case .readyEPUB(let navigator) = state else { return nil }
        return navigator
    }

    var readAloudPublication: Publication? { publicationSession.publication }

    var readAloudPublicationFileURL: URL? { publicationSession.fileURL }

    var readAloudObservedProgression: Double? { locationPipeline.latestObservedProgression }

    var readAloudProgress: Double? { currentProgress }

    var readAloudStorytellerActivityAt: Date? {
        get { progress.storytellerPositionActivityAt }
        set { progress.storytellerPositionActivityAt = newValue }
    }

    func readAloudDidChange() {
        objectWillChange.send()
    }

    func readAloudDidPublishPlayerState() {
        objectWillChange.send()
        companion.readAloudStateDidChange()
    }

    func readAloudDidDeactivate() {
        // Stopping read-aloud drops an in-flight engine search, as it always has.
        foliateSearchTask?.cancel()
        foliateSearchTask = nil
    }

    func readAloudDidAdvanceHighlight() async {
        await companion.broadcastHighlightFrameIfActive()
    }

    func readAloudDidUpdateTimeEstimates(chapterMinutes: Int?, bookMinutes: Int?) {
        updateSessionSnapshot {
            $0.minutesLeftInChapter = chapterMinutes
            $0.minutesLeftInBook = bookMinutes
            $0.readingSpeedDisplay = nil
        }
    }

    func readAloudRequestsProgressFlush(reason: String) {
        flushProgressToServer(reason: reason)
    }

    func readAloudDidCommitPosition(_ commit: ReaderReadAloudPositionCommit) {
        progress.commitReadAloudPosition(commit)
    }
}

func readerOpenFailureMessage(_ error: Error) -> String {
    if let retrieval = error as? AssetRetrieveURLError {
        switch retrieval {
        case .formatNotSupported:
            return readerInvalidEpubMessage
        case .schemeNotSupported(let scheme):
            return "This location type is not supported: \(scheme.rawValue)."
        case .reading(let cause):
            return readerReadErrorMessage(cause)
        }
    }
    if let retrieval = error as? AssetRetrieveError {
        switch retrieval {
        case .formatNotSupported:
            return readerInvalidEpubMessage
        case .reading(let cause):
            return readerReadErrorMessage(cause)
        }
    }
    if let open = error as? PublicationOpenError {
        switch open {
        case .formatNotSupported:
            return readerInvalidEpubMessage
        case .reading(let cause):
            return readerReadErrorMessage(cause)
        }
    }
    return error.localizedDescription
}

private func readerReadErrorMessage(_ error: ReadError) -> String {
    switch error {
    case .access(let cause):
        return readerMessage("The file could not be read.", cause)
    case .decoding(let cause):
        return readerMessage("The file is damaged or incomplete. It will be re-downloaded on the next attempt.", cause)
    case .outOfMemory:
        return "This book is too large to open on this device."
    case .unsupportedOperation(let cause):
        return readerMessage("The file could not be opened.", cause)
    case .cancelled:
        return "Opening was cancelled."
    }
}

private func readerMessage(_ lead: String, _ cause: Error?) -> String {
    guard let detail = readerCauseDetail(cause), !detail.isEmpty else { return lead }
    return "\(lead) (\(detail))"
}

private func readerCauseDetail(_ error: Error?, depth: Int = 0) -> String? {
    guard let error, depth < 4 else { return nil }
    if let debug = error as? DebugError {
        let nested = debug.cause.flatMap { readerCauseDetail($0, depth: depth + 1) }
        return nested.map { "\(debug.message) \($0)" } ?? debug.message
    }
    return String(describing: error)
}

private let readerInvalidEpubMessage =
    "The file is not a valid EPUB package. The server may have returned an error page or a different format."

enum ClassicReaderError: LocalizedError {
    case fileNotFound(String?)
    case invalidURL(String)
    case invalidComicArchive(String)
    case invalidPDF(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Ebook file not found at \(path ?? "unknown path")"
        case .invalidURL(let path):
            return "Invalid file URL: \(path)"
        case .invalidComicArchive(let path):
            return "Could not read any comic pages from \(path)"
        case .invalidPDF(let path):
            return "Could not open PDF at \(path)"
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext). Supported formats are EPUB, PDF, CBZ, and CBR."
        }
    }
}
