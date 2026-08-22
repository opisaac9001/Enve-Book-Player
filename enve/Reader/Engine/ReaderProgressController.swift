import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

@MainActor
protocol ReaderProgressHosting: AnyObject {
    var progressReaderState: ClassicReaderModel.State { get }
    var progressEngineAdapter: (any ReaderEngineAdapter)? { get }
    var progressPublication: Publication? { get }
    var progressPublicationFileURL: URL? { get }
    var progressBridgeSession: EpubBridgeSession? { get }
    var progressCurrentProgress: Double? { get set }
    var progressObservedProgression: Double? { get }
    var progressSectionTitle: String? { get }
    var progressTotalPages: Int { get }
    var progressComicPageIndex: Int { get }
    var progressStablePDFPageIndex: Int { get }
    var progressPDFController: PDFReaderController? { get }
    func progressLocatorAtOrBefore(progression: Double) -> Locator?
}

// A checkpoint may only be written once a user interaction has been rendered.
struct ReaderBridgeWriteGate: Equatable {
    private(set) var isWriteArmed = false
    private(set) var isUserInteractionPending = false
    private(set) var hasCommittedUserPosition = false

    mutating func noteUserInteraction() {
        isUserInteractionPending = true
    }

    mutating func armIfUserInteractionPending() {
        guard isUserInteractionPending else { return }
        isUserInteractionPending = false
        isWriteArmed = true
    }

    mutating func noteCommittedWrite() {
        isWriteArmed = false
        hasCommittedUserPosition = true
    }

    mutating func reset() {
        self = ReaderBridgeWriteGate()
    }
}

struct ReaderReadAloudPositionCommit {
    let progression: Double
    let locatorJSON: String?
    let audioTime: TimeInterval
    let audioDuration: TimeInterval
    let observedAt: Date
    let isAuthoritative: Bool
    let schedulesRemoteSync: Bool
}

@MainActor
final class ReaderProgressController {
    weak var host: (any ReaderProgressHosting)?

    private let book: Book
    private let providerResolver: any LibraryProviderResolving
    private let libraryCache: LibraryBookCache
    private let bookStore: BookStoreRepository
    private let locatorProgress: ReaderLocatorProgress
    private let readAloud: ReaderReadAloudController

    private var hydrateTask: Task<String?, Never>?
    private var hydrationApplyTask: Task<Void, Never>?
    private(set) var hasResolvedInitialHydration = false
    private var initialEPUBLocationAtOpen: Locator?
    private var userNavigatedEPUBBeforeHydration = false
    private var lastRenderedEngineRelocation: ReaderEngineRelocation?

    private var bridgeWriteGate = ReaderBridgeWriteGate()
    private var readiumBridgeRestoreTask: Task<Void, Never>?

    private var autoSaveTimer: Timer?
    private var serverSyncTask: Task<Void, Never>?
    private var locatorEnrichmentTask: Task<Void, Never>?
    private var progressSaveTask: Task<Void, Never>?

    // Storyteller positions persist only on deliberate activity, so nil also gates the save.
    var storytellerPositionActivityAt: Date?

    init(
        book: Book,
        providerResolver: any LibraryProviderResolving,
        libraryCache: LibraryBookCache,
        bookStore: BookStoreRepository,
        locatorProgress: ReaderLocatorProgress,
        readAloud: ReaderReadAloudController
    ) {
        self.book = book
        self.providerResolver = providerResolver
        self.libraryCache = libraryCache
        self.bookStore = bookStore
        self.locatorProgress = locatorProgress
        self.readAloud = readAloud
    }

    deinit {
        locatorEnrichmentTask?.cancel()
        progressSaveTask?.cancel()
        readiumBridgeRestoreTask?.cancel()
        hydrationApplyTask?.cancel()
    }

    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }
    private var state: ClassicReaderModel.State { host?.progressReaderState ?? .loading }
    private var engineAdapter: (any ReaderEngineAdapter)? { host?.progressEngineAdapter }
    private var bridgeSession: EpubBridgeSession? { host?.progressBridgeSession }
    private var observedProgression: Double? { host?.progressObservedProgression }

    private var currentProgress: Double? {
        get { host?.progressCurrentProgress }
        set { host?.progressCurrentProgress = newValue }
    }

    func beginHydration() {
        hasResolvedInitialHydration = false
        hydrateTask = Task { await hydrateServerPositionIfNeeded() }
    }

    func beginRestorationWhenReady() {
        hydrationApplyTask = Task { [weak self] in await self?.applyHydratedServerPositionWhenReady() }
    }

    func awaitRestoration() async {
        await hydrationApplyTask?.value
    }

    func noteInitialLocation(_ locator: Locator?) {
        initialEPUBLocationAtOpen = locator
    }

    private func hydrateServerPositionIfNeeded() async -> String? {
        guard let provider = providerResolver.provider(for: book.providerId),
            provider.syncCapability.contains(.pullProgress)
        else { return nil }
        if book.isStorytellerReadAloud,
            let storyteller = provider as? StorytellerProvider
        {
            return await hydrateStorytellerPosition(through: storyteller)
        }
        guard let progressProvider = provider as? any EbookProgressPulling,
            let result = try? await progressProvider.fetchEbookProgress(for: book)
        else { return nil }

        let serverProgress = result.progress
        let serverLocator = result.locator
        let serverDate = result.updatedAt ?? .distantPast
        let local = await MainActor.run { () -> (direction: SyncDirection, book: Book, progress: Double, locator: String?)? in
            guard let current = libraryCache.bookInMemory(uniqueId: self.book.uniqueId) else { return nil }
            let localProgress = current.canonicalEbookProgress
            let localDate = current.lastUpdate

            let direction: SyncDirection
            direction = ProgressConflictResolver.resolve(
                localPosition: localProgress,
                localDate: localDate,
                serverPosition: serverProgress,
                serverDate: serverDate,
                protectsAgainstBackwardProgress: true
            )
            return (direction, current, localProgress, current.epubLocator)
        }
        guard let local else { return nil }

        if local.direction == .push,
            local.book.source == .storyteller,
            provider is StorytellerProvider
        {
            var syncBook = syncSourceBook(for: local.book)
            syncBook.ebookProgress = local.progress
            syncBook.epubLocator = local.locator
            syncBook.lastUpdate = local.book.lastUpdate
            await SyncCoordinator.shared.pushProgress(
                book: syncBook,
                forceImmediate: true,
                domain: .ebook
            )
            return nil
        }

        guard local.direction == .pull || local.direction == .conflict else { return nil }

        let hydratedBook = await MainActor.run { () -> Book? in
            guard
                let updated = libraryCache.mutateBook(
                    uniqueId: self.book.uniqueId,
                    { book in
                        book.ebookProgress = serverProgress
                        if let loc = serverLocator, !loc.isEmpty {
                            book.epubLocator = loc
                        } else if self.book.source == .booklore {
                            book.epubLocator = nil
                        }
                        book.lastUpdate = serverDate
                    }
                )
            else { return nil }
            EbookLinkStore.shared.saveLinks()

            AppLogger.sync.debug("Hydrated server position bookDiagnosticID=\(bookDiagnosticID) percent=\(Int(serverProgress * 100))")
            return updated
        }
        guard let hydratedBook else { return nil }
        await LinkedBookProgressCoordinator.shared.recordEbookProgress(
            book: hydratedBook,
            progression: serverProgress,
            observedAt: serverDate,
            authoritative: true
        )
        return (serverLocator?.isEmpty == false) ? serverLocator : nil
    }

    private func hydrateStorytellerPosition(
        through provider: StorytellerProvider
    ) async -> String? {
        guard
            let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
                for: book,
                through: provider
            )
        else { return nil }
        let position = authoritative.position
        let updatedBook = libraryCache.mutateBook(uniqueId: book.uniqueId) { updated in
            updated.ebookProgress = position.progression
            updated.epubLocator = position.locatorJSON
            updated.lastUpdate = position.observedAt
            updated.isFinished = position.progression >= 0.99
        }
        guard let updatedBook else { return nil }
        EbookLinkStore.shared.saveLinks()
        await bookStore.updateEbookProgress(
            uniqueId: updatedBook.uniqueId,
            ebookProgress: position.progression,
            epubLocator: position.locatorJSON,
            isFinished: updatedBook.isFinished,
            lastUpdate: position.observedAt
        )
        await LinkedBookProgressCoordinator.shared.recordEbookProgress(
            book: updatedBook,
            progression: position.progression,
            observedAt: position.observedAt,
            authoritative: true
        )
        return position.locatorJSON
    }

    private func applyHydratedServerPositionWhenReady() async {
        defer {
            hasResolvedInitialHydration = true
            if let lastRenderedEngineRelocation {
                let readiumNavigator: EPUBNavigatorViewController? = {
                    guard case .readyEPUB(let navigator) = state else { return nil }
                    return navigator
                }()
                confirmBridgeRestore(
                    from: lastRenderedEngineRelocation,
                    readiumNavigator: readiumNavigator
                )
            }
        }
        guard let serverLocatorJSON = await hydrateTask?.value else { return }
        guard let serverLocator = try? Locator(jsonString: serverLocatorJSON) else { return }

        var adapter: (any ReaderEngineAdapter)?
        for _ in 0..<50 {
            if state.isReady, let ready = engineAdapter {
                adapter = ready
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let adapter else { return }
        let usesMediaOverlayPosition = book.hasEPUB3MediaOverlay || readAloud.hasMediaOverlay

        let currentLocation = adapter.currentLocatorJSON.flatMap {
            try? Locator(jsonString: $0)
        }
        if userNavigatedEPUBBeforeHydration
            || ReaderLocationController.locationsDiffer(initialEPUBLocationAtOpen, currentLocation)
        {
            AppLogger.sync.debug("Skipping server jump bookDiagnosticID=\(bookDiagnosticID): user moved")
            return
        }

        let targetLocator: Locator
        if usesMediaOverlayPosition {
            guard let publication = host?.progressPublication,
                let resolved = await readAloud.resolvedInitialLocation(
                    rawLocator: serverLocatorJSON,
                    parsed: serverLocator,
                    publication: publication
                )
            else {
                AppLogger.sync.warning(
                    "Rejected hydrated EPUB3 media-overlay position bookDiagnosticID=\(bookDiagnosticID)"
                )
                return
            }
            targetLocator = resolved
        } else if EpubLocationBridge.canRestoreDirectly(serverLocatorJSON) {
            targetLocator = serverLocator
        } else {
            let serverProgression = serverLocator.locations.totalProgression ?? serverLocator.locations.progression ?? 0
            targetLocator = host?.progressLocatorAtOrBefore(progression: serverProgression) ?? serverLocator
        }
        let targetJSON: String? = {
            if !usesMediaOverlayPosition,
                adapter.kind == .foliate,
                EpubLocationBridge.canStoreAlongsidePercentageSync(serverLocatorJSON)
            {
                return serverLocatorJSON
            }
            return try? targetLocator.jsonString()
        }()
        bridgeSession?.setRestoreTarget(
            locatorJSON: targetJSON,
            fallbackProgression: usesMediaOverlayPosition
                ? nil
                : serverLocator.locations.totalProgression
                    ?? serverLocator.locations.progression
        )
        guard let targetJSON,
            await adapter.restore(locatorJSON: targetJSON, animated: false)
        else {
            AppLogger.sync.warning(
                "Selected reader could not apply hydrated server position bookDiagnosticID=\(bookDiagnosticID)"
            )
            return
        }
        AppLogger.sync.debug("Applied hydrated server position bookDiagnosticID=\(bookDiagnosticID)")
    }

    func noteUserNavigation() {
        if book.isStorytellerReadAloud {
            storytellerPositionActivityAt = Date()
        }
        if !hasResolvedInitialHydration {
            userNavigatedEPUBBeforeHydration = true
        }
        readiumBridgeRestoreTask?.cancel()
        readiumBridgeRestoreTask = nil
        bridgeSession?.noteUserInteraction()
        bridgeWriteGate.noteUserInteraction()
    }

    func armBridgeWriteIfUserInteractionPending() {
        bridgeWriteGate.armIfUserInteractionPending()
    }

    func noteRelocation(
        _ relocation: ReaderEngineRelocation,
        readiumNavigator: EPUBNavigatorViewController?
    ) {
        lastRenderedEngineRelocation = relocation
        guard hasResolvedInitialHydration else { return }
        confirmBridgeRestore(from: relocation, readiumNavigator: readiumNavigator)
        scheduleProgressSave()
    }

    func resetBridgeWriteState() {
        readiumBridgeRestoreTask?.cancel()
        readiumBridgeRestoreTask = nil
        bridgeWriteGate.reset()
    }

    private func confirmBridgeRestore(
        from relocation: ReaderEngineRelocation,
        readiumNavigator: EPUBNavigatorViewController? = nil
    ) {
        guard hasResolvedInitialHydration, let session = bridgeSession else { return }
        let targetLocatorJSON = session.restoreTargetLocatorJSON
        let requiresPortableReadiumRestore =
            readiumNavigator != nil
            && targetLocatorJSON.flatMap {
                EpubBridgePosition(
                    readiumLocatorJSON: $0,
                    fallbackProgression: currentProgress
                )
            }?.hasPortableAnchor == true
        if !requiresPortableReadiumRestore,
            session.confirmRestore(
                observedLocatorJSON: relocation.locatorJSON,
                fallbackProgression: relocation.locator.locations.totalProgression
                    ?? relocation.locator.locations.progression
                    ?? currentProgress
            )
        {
            return
        }
        guard let readiumNavigator,
            readiumBridgeRestoreTask == nil,
            requiresPortableReadiumRestore,
            let targetLocatorJSON
        else {
            return
        }
        readiumBridgeRestoreTask = Task { @MainActor [weak self, weak readiumNavigator] in
            defer { self?.readiumBridgeRestoreTask = nil }
            guard let self, let readiumNavigator else { return }
            await self.confirmReadiumPortableRestore(
                targetLocatorJSON: targetLocatorJSON,
                navigator: readiumNavigator
            )
        }
    }

    private func confirmReadiumPortableRestore(
        targetLocatorJSON: String,
        navigator: EPUBNavigatorViewController
    ) async {
        var isJavaScriptReady = false
        for _ in 0..<50 {
            guard !Task.isCancelled else { return }
            if case .success(let value) = await navigator.evaluateJavaScript(
                "(function(){ return 'ready'; })();"
            ), value as? String == "ready" {
                isJavaScriptReady = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled,
            isJavaScriptReady,
            let script = ReadiumPortableAnchorScript.restore(
                locatorJSON: targetLocatorJSON
            ),
            case .success(let result) = await navigator.evaluateJavaScript(script),
            !Task.isCancelled,
            result as? String == "true"
        else {
            return
        }

        try? await Task.sleep(for: .milliseconds(300))
        for attempt in 0..<5 {
            guard !Task.isCancelled,
                let session = bridgeSession,
                let locator = navigator.currentLocation,
                let enriched = await Self.locatorWithMiddlePageAnchor(
                    locator: locator,
                    navigator: navigator
                )
            else {
                return
            }
            if session.confirmPortableRestore(
                observedLocatorJSON: enriched,
                fallbackProgression: locator.locations.totalProgression
                    ?? locator.locations.progression
                    ?? currentProgress
            ) {
                locatorProgress.updateLocatorJSON(enriched)
                return
            }
            if attempt < 4 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func startAutoSaveTimer() {
        stopAutoSaveTimer()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                let current = self.observedProgression ?? self.currentProgress ?? 0
                if self.locatorProgress.shouldSkipAutoSave(currentProgress: current) {
                    return
                }
                _ = await self.engineAdapter?.flushPosition()
                self.saveProgress()

                if let progress = self.observedProgression ?? self.currentProgress {
                    await ReadingStatsTracker.shared.recordTick(
                        bookId: self.book.id,
                        positionProgression: progress,
                        isReading: true,
                        location: self.host?.progressSectionTitle
                    )
                }
            }
        }
    }

    func stopAutoSaveTimer() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    func scheduleLocatorEnrichment(locator: ReadiumShared.Locator, navigator: EPUBNavigatorViewController) {
        locatorEnrichmentTask?.cancel()
        locatorEnrichmentTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            if await self.readAloud.captureVisibleOverlayPosition(in: navigator, locator: locator) {
                return
            }
            guard let enriched = await Self.locatorWithMiddlePageAnchor(locator: locator, navigator: navigator) else { return }
            guard !Task.isCancelled else { return }
            self.locatorProgress.updateLocatorJSON(enriched)
        }
    }

    private func scheduleProgressSave() {
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.hasResolvedInitialHydration else { return }
            if case .readyEPUB(let navigator) = self.state {
                _ = await self.readAloud.captureVisibleOverlayPosition(in: navigator)
            } else if case .readyFoliate = self.state {
                _ = await self.engineAdapter?.flushPosition()
            }
            self.saveProgress()
        }
    }

    func saveProgressResolvingVisibleOverlay() async {
        if readAloud.isActive {
            readAloud.syncPositionNow(allowRegression: true)
            return
        }
        await readAloud.waitForOverlayTimelineIfPreparing()
        if case .readyEPUB(let navigator) = state {
            _ = await readAloud.captureVisibleOverlayPosition(in: navigator)
        } else if case .readyFoliate = state {
            _ = await engineAdapter?.flushPosition()
        }
        saveProgress()
    }

    func saveProgress() {
        guard hasResolvedInitialHydration else { return }
        if readAloud.isActive {
            readAloud.syncPositionNow()
            return
        }
        if book.isStorytellerReadAloud, storytellerPositionActivityAt == nil {
            return
        }
        guard
            let snapshot = locatorProgress.snapshot(
                state: state,
                currentProgress: observedProgression ?? currentProgress,
                currentComicPageIndex: host?.progressComicPageIndex ?? 0,
                lastStablePDFPageIndex: host?.progressStablePDFPageIndex ?? 0,
                totalPages: host?.progressTotalPages ?? 0,
                pdfController: host?.progressPDFController
            )
        else { return }

        var progression = snapshot.progression
        var sourceEngine: ReaderEngineKind?
        let overlayPosition =
            readAloud.isActive
            ? nil
            : readAloud.overlayLocatorForCurrentReadingPosition(progression: progression)
        var locatorJSON = overlayPosition?.locatorJSON ?? snapshot.locatorJSON

        if let bridgeSession {
            guard bridgeWriteGate.isWriteArmed else { return }
            guard let candidateLocator = locatorJSON else {
                AppLogger.library.warning("Skipping EPUB save without bridgeable locator bookDiagnosticID=\(bookDiagnosticID)")
                return
            }
            do {
                let checkpoint = try bridgeSession.commit(
                    locatorJSON: candidateLocator,
                    fallbackProgression: progression,
                    observedAt: Date()
                )
                progression = checkpoint.totalProgression
                sourceEngine = checkpoint.sourceEngine
                locatorJSON =
                    checkpoint.readiumLocatorJSON
                    ?? EpubLocationBridge.readiumLocator(
                        from: checkpoint.position,
                        sourceEngine: checkpoint.sourceEngine
                    )
                bridgeWriteGate.noteCommittedWrite()
            } catch {
                AppLogger.library.warning(
                    "Skipping EPUB save before bridge restore confirmation bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)"
                )
                return
            }
        }

        let existingProgress = book.canonicalEbookProgress
        guard bridgeSession != nil || progression > 0.001 || existingProgress < 0.001 else {
            AppLogger.general.debug("Skipping zero-percent save bookDiagnosticID=\(bookDiagnosticID) existingPercent=\(Int(existingProgress * 100))")
            return
        }

        locatorProgress.markSaved(progression: progression)
        locatorProgress.updateLocatorJSON(locatorJSON)

        let fileURL = host?.progressPublicationFileURL ?? book.ebookFileURL
        let effectiveDuration = readAloud.totalAudioDuration ?? book.duration ?? 0
        let mirroredCurrentTime =
            overlayPosition?.audioTime
            ?? (effectiveDuration > 0 ? progression * effectiveDuration : 0)
        let now = storytellerPositionActivityAt ?? Date()
        storytellerPositionActivityAt = nil
        let didMutate = libraryCache.mutateBook(uniqueId: book.uniqueId) { updated in
            updated.epubLocator = locatorJSON
            updated.ebookProgress = progression
            if effectiveDuration > 0 {
                updated.duration = effectiveDuration
                updated.currentTime = mirroredCurrentTime
            }
            updated.ebookFileURL = fileURL
            updated.lastUpdate = now
        }
        if didMutate != nil {
            EbookLinkStore.shared.saveLinks()
        }
        mirrorToReadAloudSourceBook(
            progression: progression,
            locatorJSON: locatorJSON,
            observedAt: now,
            clearsMissingLocator: false
        )
        if effectiveDuration > 0 {
            BookProgressStore.shared.saveProgress(
                for: book,
                progress: mirroredCurrentTime,
                duration: effectiveDuration
            )
            UserProgressStore.shared.update(
                UserMediaProgress(
                    id: UUID().uuidString,
                    libraryItemId: book.id,
                    providerId: book.providerId,
                    episodeId: nil,
                    currentTime: mirroredCurrentTime,
                    progress: progression,
                    isFinished: progression >= 0.99,
                    duration: effectiveDuration,
                    lastUpdate: now,
                    ebookProgress: progression
                )
            )
        }

        serverSyncTask?.cancel()
        let capturedProgression = progression
        let capturedLocator = locatorJSON
        let capturedBook = book
        let capturedAudioTime = overlayPosition?.audioTime
        let capturedSourceEngine = sourceEngine
        let capturedAudioDuration =
            readAloud.totalAudioDuration
            ?? readAloud.player?.totalDuration
        Task {
            await LinkedBookProgressCoordinator.shared.recordEbookProgress(
                book: capturedBook,
                progression: capturedProgression,
                exactAudioTime: capturedAudioTime,
                exactAudioDuration: capturedAudioDuration,
                observedAt: now
            )
        }
        serverSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let syncBook = self.syncSourceBook(for: capturedBook)
            await bookStore.updateEbookProgress(
                uniqueId: syncBook.uniqueId,
                ebookProgress: capturedProgression,
                epubLocator: capturedLocator,
                isFinished: capturedProgression >= 0.99,
                lastUpdate: now
            )
            guard !Task.isCancelled else { return }
            if capturedBook.isStorytellerReadAloud {
                do {
                    guard let capturedLocator else { return }
                    try await StorytellerPositionSyncService.shared.submit(
                        book: capturedBook,
                        locatorJSON: capturedLocator,
                        observedAt: now
                    )
                } catch is CancellationError {
                    return
                } catch {
                    AppLogger.general.error(
                        "Debounced Storyteller position push failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: syncBook.stableId)): \(error.localizedDescription)"
                    )
                }
                return
            }
            let ebookForPush = libraryCache.bookInMemory(uniqueId: capturedBook.uniqueId) ?? capturedBook
            await SyncCoordinator.shared.pushProgress(
                book: ebookForPush,
                forceImmediate: true,
                sourceEngine: capturedSourceEngine,
                domain: .ebook
            )
        }
        AppLogger.general.debug("Saved ebook progress bookDiagnosticID=\(bookDiagnosticID) percent=\(Int(progression * 100))")
    }

    func flushProgressToServer(reason: String = "close") {
        guard hasResolvedInitialHydration else { return }
        serverSyncTask?.cancel()
        serverSyncTask = nil

        let isReadAloudFlush = readAloud.isPlaybackActive
        if isReadAloudFlush {
            readAloud.syncPositionNow(allowRegression: true, scheduleRemoteSync: false)
        }

        let committedBridgeBook: Book? = {
            guard bridgeSession != nil else { return nil }
            guard bridgeWriteGate.hasCommittedUserPosition else { return nil }
            return libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        }()
        if bridgeSession != nil, committedBridgeBook == nil {
            return
        }
        let progression =
            committedBridgeBook?.canonicalEbookProgress
            ?? currentProgress
            ?? book.canonicalEbookProgress
        guard committedBridgeBook != nil || progression > 0.001 else { return }
        AppLogger.network.debug("[EbookReader] Flushing progress reason=\(reason) bookDiagnosticID=\(bookDiagnosticID) percent=\(Int(progression * 100))")

        let overlayPosition =
            isReadAloudFlush
            ? nil
            : readAloud.overlayLocatorForCurrentReadingPosition(progression: progression)
        let locator =
            isReadAloudFlush
            ? locatorProgress.lastKnownLocatorJSON
            : (committedBridgeBook?.epubLocator
                ?? overlayPosition?.locatorJSON
                ?? locatorProgress.lastKnownLocatorJSON)
        let capturedBook = book
        let capturedSourceEngine = committedBridgeBook.flatMap {
            EpubLocationBridge.sourceEngine(from: $0.epubLocator)
        }
        let capturedOverlayAudioTime =
            isReadAloudFlush
            ? readAloud.player?.currentTime
            : overlayPosition?.audioTime
        let capturedOverlayAudioDuration =
            readAloud.totalAudioDuration
            ?? readAloud.player?.totalDuration
        let capturedAt = Date()

        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }

        serverSyncTask = Task { @MainActor in
            defer {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }
            await LinkedBookProgressCoordinator.shared.recordEbookProgress(
                book: capturedBook,
                progression: progression,
                exactAudioTime: capturedOverlayAudioTime,
                exactAudioDuration: capturedOverlayAudioDuration,
                observedAt: capturedAt,
                authoritative: true
            )
            let syncBook = self.syncSourceBook(for: capturedBook)
            await bookStore.updateEbookProgress(
                uniqueId: syncBook.uniqueId,
                ebookProgress: progression,
                epubLocator: locator,
                isFinished: progression >= 0.99,
                lastUpdate: capturedAt
            )
            guard !Task.isCancelled else { return }
            if capturedBook.isStorytellerReadAloud {
                do {
                    guard let locator else { return }
                    try await StorytellerPositionSyncService.shared.submit(
                        book: capturedBook,
                        locatorJSON: locator,
                        observedAt: capturedAt
                    )
                } catch is CancellationError {
                    return
                } catch {
                    AppLogger.general.error("Flush Storyteller position push failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: syncBook.stableId)): \(error.localizedDescription)")
                }
                return
            }
            let ebookForPush = libraryCache.bookInMemory(uniqueId: syncBook.uniqueId) ?? syncBook
            await SyncCoordinator.shared.pushProgress(
                book: ebookForPush,
                forceImmediate: true,
                sourceEngine: capturedSourceEngine,
                domain: .ebook
            )

            await WorkProgressSync.shared.fanOut(from: ebookForPush, fraction: progression, isFinished: progression >= 0.99, force: true)
        }

        Task {
            await KOReaderSyncService.shared.pushIfLinked(book: capturedBook, progress: progression, locator: locator)
        }
    }

    func commitReadAloudPosition(_ commit: ReaderReadAloudPositionCommit) {
        currentProgress = commit.progression
        locatorProgress.updateLocatorJSON(commit.locatorJSON)
        locatorProgress.markSaved(progression: commit.progression)

        let mutated = libraryCache.mutateBook(uniqueId: book.uniqueId) { updated in
            if let resumeLoc = commit.locatorJSON {
                updated.epubLocator = resumeLoc
            }
            updated.ebookProgress = commit.progression
            updated.currentTime = min(max(commit.audioTime, 0), commit.audioDuration)
            updated.duration = commit.audioDuration
            updated.lastUpdate = commit.observedAt
        }
        if mutated != nil {
            EbookLinkStore.shared.saveLinks()
        }
        mirrorToReadAloudSourceBook(
            progression: commit.progression,
            locatorJSON: commit.locatorJSON,
            observedAt: commit.observedAt,
            clearsMissingLocator: true
        )

        if commit.audioDuration > 0 {
            let mirroredCurrentTime = min(max(commit.audioTime, 0), commit.audioDuration)
            BookProgressStore.shared.saveProgress(
                for: book,
                progress: mirroredCurrentTime,
                duration: commit.audioDuration,
                at: commit.observedAt
            )
            let mirroredProgress = UserMediaProgress(
                id: UUID().uuidString,
                libraryItemId: book.id,
                providerId: book.providerId,
                episodeId: nil,
                currentTime: mirroredCurrentTime,
                progress: mirroredCurrentTime / commit.audioDuration,
                isFinished: commit.progression >= 0.99,
                duration: commit.audioDuration,
                lastUpdate: commit.observedAt,
                ebookProgress: commit.progression
            )
            UserProgressStore.shared.update(mirroredProgress)
        }

        Task {
            await LinkedBookProgressCoordinator.shared.recordEbookProgress(
                book: book,
                progression: commit.progression,
                exactAudioTime: commit.audioTime,
                exactAudioDuration: commit.audioDuration,
                observedAt: commit.observedAt,
                authoritative: commit.isAuthoritative
            )
        }

        guard commit.schedulesRemoteSync else { return }
        let capturedBook = book
        let capturedProgress = commit.progression
        let capturedLocator = commit.locatorJSON
        let capturedAt = commit.observedAt
        serverSyncTask?.cancel()
        serverSyncTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let syncBook = self.syncSourceBook(for: capturedBook)
            await self.bookStore.updateEbookProgress(
                uniqueId: syncBook.uniqueId,
                ebookProgress: capturedProgress,
                epubLocator: capturedLocator,
                isFinished: capturedProgress >= 0.99,
                lastUpdate: capturedAt
            )
            guard !Task.isCancelled else { return }
            await SyncCoordinator.shared.pushProgress(
                book: syncBook,
                forceImmediate: true,
                sourceEngine: EpubLocationBridge.sourceEngine(from: capturedLocator),
                domain: .ebook
            )
        }
    }

    // A read-aloud book is a synthetic stand-in; progress belongs to the original library book.
    private func resolvedReadAloudSourceBook(for book: Book) -> Book? {
        guard let sourceStableId = book.readAloudSourceStableId,
            let source = libraryCache.bookInMemory(stableId: sourceStableId),
            source.readAloudSourceStableId == nil
        else { return nil }
        return source
    }

    private func syncSourceBook(for book: Book) -> Book {
        resolvedReadAloudSourceBook(for: book) ?? book
    }

    // Read-aloud commits clear a missing locator; ordinary saves keep the previous one.
    private func mirrorToReadAloudSourceBook(
        progression: Double,
        locatorJSON: String?,
        observedAt: Date,
        clearsMissingLocator: Bool
    ) {
        guard let sourceStableId = book.readAloudSourceStableId,
            resolvedReadAloudSourceBook(for: book) != nil
        else { return }
        libraryCache.mutateBook(stableId: sourceStableId) { sourceUpdated in
            if locatorJSON != nil || clearsMissingLocator {
                sourceUpdated.epubLocator = locatorJSON
            }
            sourceUpdated.ebookProgress = progression
            sourceUpdated.lastUpdate = observedAt
        }
    }

    func cleanup() {
        hydrateTask?.cancel()
        hydrateTask = nil
        hydrationApplyTask?.cancel()
        hydrationApplyTask = nil
        readiumBridgeRestoreTask?.cancel()
        readiumBridgeRestoreTask = nil
    }

    private static func locatorWithMiddlePageAnchor(
        locator: ReadiumShared.Locator,
        navigator: EPUBNavigatorViewController
    ) async -> String? {
        let js = """
            (function() {
                var SKIP = {SCRIPT:1, STYLE:1, NOSCRIPT:1, TEMPLATE:1, LINK:1, META:1};
                var BLOCKS = {P:1, LI:1, BLOCKQUOTE:1, DD:1, DT:1, FIGCAPTION:1, PRE:1};
                var HEADINGS = {H1:1, H2:1, H3:1, H4:1, H5:1, H6:1};

                function proseText(el) {
                    if (!el) return '';
                    var walker = document.createTreeWalker(el, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                        acceptNode: function(n) {
                            if (n.nodeType === 1) {
                                if (SKIP[n.tagName]) return NodeFilter.FILTER_REJECT;
                                return NodeFilter.FILTER_SKIP;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    });
                    var parts = [], node;
                    while ((node = walker.nextNode())) parts.push(node.nodeValue || '');
                    return parts.join(' ').replace(/\\s+/g, ' ').trim();
                }

                var vw = window.innerWidth, vh = window.innerHeight;
                var vcx = vw / 2, vcy = vh / 2;

                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, {
                    acceptNode: function(n) {
                        return SKIP[n.tagName] ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
                    }
                });

                var visibleProse = [];
                var cur;
                while ((cur = walker.nextNode())) {
                    if (HEADINGS[cur.tagName]) continue;
                    var text = proseText(cur);
                    if (text.length < 40) continue;
                    var r = cur.getBoundingClientRect();
                    if (r.width === 0 || r.height === 0) continue;

                    var hasChildCandidate = false;
                    for (var i = 0; i < cur.children.length; i++) {
                        var child = cur.children[i];
                        if (SKIP[child.tagName] || HEADINGS[child.tagName]) continue;
                        if (proseText(child).length >= 40) { hasChildCandidate = true; break; }
                    }
                    if (hasChildCandidate) continue;

                    var bx = (r.left + r.right) / 2, by = (r.top + r.bottom) / 2;
                    if (bx < 0 || bx > vw || by < 0 || by > vh) continue;
                    visibleProse.push({text: text, distance: Math.hypot(bx - vcx, by - vcy)});
                }

                if (visibleProse.length === 0) return null;
                visibleProse.sort(function(a, b){ return a.distance - b.distance; });
                var full = visibleProse[0].text;
                if (full.length < 20) return null;

                var m = full.match(/^.{20,200}?[.!?](?=\\s|$)/);
                var highlight = m ? m[0].trim() : full.slice(0, Math.min(160, full.length));
                var idx = full.indexOf(highlight);
                var before = idx > 0 ? full.slice(Math.max(0, idx - 30), idx).trim() : '';
                var afterStart = idx + highlight.length;
                var after = afterStart < full.length ? full.slice(afterStart, Math.min(full.length, afterStart + 30)).trim() : '';
                return JSON.stringify({before: before, highlight: highlight, after: after});
            })();
            """

        guard case .success(let value) = await navigator.evaluateJavaScript(js),
            let jsonString = value as? String,
            let snippetData = jsonString.data(using: .utf8),
            let snippet = try? JSONSerialization.jsonObject(with: snippetData) as? [String: Any],
            let highlight = snippet["highlight"] as? String, !highlight.isEmpty
        else { return nil }

        guard let baseData = (try? locator.jsonString())?.data(using: .utf8),
            var base = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any]
        else { return nil }

        var text: [String: Any] = (base["text"] as? [String: Any]) ?? [:]
        text["highlight"] = highlight
        if let before = snippet["before"] as? String, !before.isEmpty { text["before"] = before }
        if let after = snippet["after"] as? String, !after.isEmpty { text["after"] = after }
        base["text"] = text

        guard let merged = try? JSONSerialization.data(withJSONObject: base),
            let mergedString = String(data: merged, encoding: .utf8)
        else { return nil }
        return mergedString
    }
}
