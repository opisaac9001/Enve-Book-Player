import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

@MainActor
protocol ReaderReadAloudHosting: AnyObject {
    var readAloudNavigator: EPUBNavigatorViewController? { get }
    var readAloudPublication: Publication? { get }
    var readAloudPublicationFileURL: URL? { get }
    var readAloudProgress: Double? { get }
    var readAloudObservedProgression: Double? { get }
    var readAloudStorytellerActivityAt: Date? { get set }
    func readAloudDidChange()
    func readAloudDidPublishPlayerState()
    func readAloudDidDeactivate()
    func readAloudDidAdvanceHighlight() async
    func readAloudDidUpdateTimeEstimates(chapterMinutes: Int?, bookMinutes: Int?)
    func readAloudRequestsProgressFlush(reason: String)
    func readAloudDidCommitPosition(_ commit: ReaderReadAloudPositionCommit)
}

@MainActor
final class ReaderReadAloudController {
    weak var host: (any ReaderReadAloudHosting)?

    private let playback = ReadAloudPlaybackCoordinator()
    private let book: Book
    private let libraryCache: LibraryBookCache
    private let appearanceController: ReaderAppearanceController
    private let locatorProgress: ReaderLocatorProgress

    private var mediaOverlayPreparationTask: Task<Void, Never>?
    private var readAloudStartTask: Task<Void, Never>?
    private var normalReadingOverlayClipIndex: Int?

    init(
        book: Book,
        libraryCache: LibraryBookCache,
        appearanceController: ReaderAppearanceController,
        locatorProgress: ReaderLocatorProgress
    ) {
        self.book = book
        self.libraryCache = libraryCache
        self.appearanceController = appearanceController
        self.locatorProgress = locatorProgress

        playback.onChange = { [weak self] in
            self?.host?.readAloudDidChange()
        }
        playback.onPlayerStateChange = { [weak self] in
            self?.host?.readAloudDidPublishPlayerState()
        }
        playback.onPlaybackChange = { [weak self] isPlaying in
            guard let self else { return }
            guard playback.isReadAloudMode else {
                playback.pendingPreflipTask?.cancel()
                playback.pendingPreflipTask = nil
                return
            }
            if isPlaying {
                startPositionSyncTimer()
                rescheduleCurrentPageFollow()
            } else {
                playback.pendingPreflipTask?.cancel()
                playback.pendingPreflipTask = nil
                syncPositionNow()
                host?.readAloudRequestsProgressFlush(reason: "pause")
                stopPositionSyncTimer()
            }
        }
    }

    deinit {
        mediaOverlayPreparationTask?.cancel()
        readAloudStartTask?.cancel()
    }

    var player: MediaOverlayPlayer? { playback.overlayPlayer }
    var isActive: Bool { playback.isReadAloudMode }
    var isPlaybackActive: Bool { playback.isReadAloudMode && playback.overlayPlayer != nil }
    var clipCount: Int { playback.overlayClips.count }
    var currentClipIndex: Int? { playback.overlayPlayer?.currentClipIndex }
    var totalAudioDuration: TimeInterval? { playback.overlayTimeline?.totalAudioDuration }

    var hasMediaOverlay: Bool {
        book.epub3Features?.hasMediaOverlay == true || playback.detectedEPUB3Features?.hasMediaOverlay == true
    }

    private var appearance: ClassicReaderAppearance { appearanceController.appearance }
    private var navigator: EPUBNavigatorViewController? { host?.readAloudNavigator }
    private var publication: Publication? { host?.readAloudPublication }
    private var publicationFileURL: URL? { host?.readAloudPublicationFileURL }
    private var observedProgression: Double? { host?.readAloudObservedProgression }

    private var currentProgress: Double? { host?.readAloudProgress }

    private var storytellerActivityAt: Date? {
        get { host?.readAloudStorytellerActivityAt }
        set { host?.readAloudStorytellerActivityAt = newValue }
    }

    func noteDetectedFeatures(_ features: EPUB3Features) {
        playback.detectedEPUB3Features = features
    }

    func applySyncOffset(_ offset: TimeInterval) {
        playback.overlayPlayer?.syncOffset = offset
    }

    func clearVisibleClipCache() {
        normalReadingOverlayClipIndex = nil
    }

    func markManualNavigationIfNeeded(at locator: Locator) {
        guard playback.isReadAloudMode, !playback.audioIsNavigating else { return }
        markManualNavigation(at: locator)
    }

    func handleUserPageTurn() {
        guard playback.isReadAloudMode, appearance.readAloudSkipOnPageTurn else { return }
        syncAudioToVisiblePage()
    }

    func waitForOverlayTimelineIfPreparing() async {
        guard playback.overlayTimeline == nil, mediaOverlayPreparationTask != nil else { return }
        for _ in 0..<20 where playback.overlayTimeline == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func updateTimeEstimatesIfOverlayActive(totalProgression: Double) async -> Bool {
        guard playback.isReadAloudMode || !playback.overlayClips.isEmpty,
            let currentFrag = playback.overlayPlayer?.currentFragmentId ?? playback.overlayClips.first?.fragmentId
        else { return false }
        await updateOverlayTimeEstimates(currentFrag: currentFrag, totalProgression: totalProgression)
        return true
    }

    func cleanup() {
        mediaOverlayPreparationTask?.cancel()
        mediaOverlayPreparationTask = nil
        readAloudStartTask?.cancel()
        readAloudStartTask = nil
        stopPositionSyncTimer()
        playback.lastSyncedFragmentId = nil
        playback.lastSyncedClipIndex = -1
        playback.lastSyncedAudioTime = -1
        playback.overlayPlayer?.cleanup()
        playback.resetAfterCleanup()
    }

    func beginPreparation(
        publication: Publication,
        navigator: EPUBNavigatorViewController,
        force: Bool = false
    ) {
        mediaOverlayPreparationTask?.cancel()
        mediaOverlayPreparationTask = Task { [weak self] in
            await self?.prepareMediaOverlays(
                publication: publication,
                navigator: navigator,
                forceAudioPreparation: force
            )
        }
    }

    private func prepareMediaOverlays(
        publication: Publication,
        navigator: EPUBNavigatorViewController,
        forceAudioPreparation: Bool = false
    ) async {
        do {
            let clips = try await EPUB3SMILParser.parse(publication: publication, epubFileURL: publicationFileURL)
            guard !Task.isCancelled, !clips.isEmpty else { return }
            let provisionalTimeline = MediaOverlayTimeline(
                clips: clips,
                orderedAudioDurations: orderedBookAudioDurations()
            )
            playback.publishMapping(clips: clips, timeline: provisionalTimeline)
            _ = await captureVisibleOverlayPosition(in: navigator)
            guard !Task.isCancelled else { return }
            guard forceAudioPreparation || playback.autoStartReadAloud else { return }

            let audioDir = try await EPUB3SMILParser.extractAudio(
                clips: clips,
                publication: publication,
                bookId: book.stableId,
                epubFileURL: publicationFileURL
            )
            guard !Task.isCancelled else { return }
            let measuredDurations = await MediaOverlayTimeline.measuredAudioDurations(
                clips: clips,
                audioDirectory: audioDir
            )
            guard !Task.isCancelled else { return }
            let timeline = MediaOverlayTimeline(
                clips: clips,
                audioDurationsBySource: measuredDurations,
                orderedAudioDurations: orderedBookAudioDurations()
            )

            let chapterDurations: [String: TimeInterval]
            if let epubURL = publicationFileURL {
                chapterDurations = await EPUB3SMILParser.parseChapterDurations(epubFileURL: epubURL)
            } else {
                chapterDurations = [:]
            }
            guard !Task.isCancelled else { return }
            playback.onFragmentChange = { [weak self, weak navigator] fragmentId in
                guard let self, let navigator else { return }
                self.playback.overlayFragmentUpdateTask?.cancel()
                self.playback.overlayFragmentUpdateTask = Task { @MainActor [weak self, weak navigator] in
                    guard let self, let navigator, !Task.isCancelled else { return }
                    let prog = self.currentProgress ?? self.book.canonicalEbookProgress
                    await self.updateOverlayTimeEstimates(currentFrag: fragmentId, totalProgression: prog)
                    guard !Task.isCancelled else { return }
                    guard self.playback.isReadAloudMode, self.appearance.readAloudHighlightEnabled else { return }
                    self.applyOverlayDecoration(fragmentId: fragmentId, navigator: navigator)
                    if self.playback.shouldRunPageFollowWork() {
                        await self.autoPageToFragmentIfNeeded(fragmentId: fragmentId, navigator: navigator)
                        guard !Task.isCancelled else { return }
                        await self.schedulePagePreflipIfNeeded(fragmentId: fragmentId, navigator: navigator)
                    }
                    await self.host?.readAloudDidAdvanceHighlight()
                }
            }
            playback.load(
                clips: clips,
                timeline: timeline,
                chapterDurations: chapterDurations,
                audioDir: audioDir,
                syncOffset: appearance.readAloudSyncOffset,
                book: book
            )

            let computedDuration = timeline.totalAudioDuration
            if computedDuration > 0 {
                libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.duration = computedDuration }
            }
            guard let player = playback.overlayPlayer else { return }

            await presyncOverlayPlayerToReadingPosition(nav: navigator)
            _ = await captureVisibleOverlayPosition(in: navigator)

            if playback.autoStartReadAloud {
                playback.autoStartReadAloud = false
                playback.isReadAloudMode = true
                if let startFrag = await firstVisibleOverlayFragment(in: navigator) {
                    player.seekToFragment(startFrag, preferredHref: navigator.currentLocation?.href.string)
                }
                guard !Task.isCancelled, playback.isReadAloudMode, playback.overlayPlayer === player else { return }
                ActivePlayback.controller.pause()
                player.play()
                startPositionSyncTimer()
            }
        } catch {
            AppLogger.library.error("Failed to prepare media overlays: \(error)")
        }
    }

    private func orderedBookAudioDurations() -> [TimeInterval] {
        let current = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        return (current.audioTracks ?? [])
            .sorted { $0.index < $1.index }
            .map(\.duration)
    }

    func toggle() {
        guard let player = playback.overlayPlayer else {
            if playback.autoStartReadAloud {
                playback.autoStartReadAloud = false
                mediaOverlayPreparationTask?.cancel()
                mediaOverlayPreparationTask = nil
                return
            }
            guard let publication, let navigator else { return }
            playback.autoStartReadAloud = true
            beginPreparation(publication: publication, navigator: navigator, force: true)
            return
        }
        playback.isReadAloudMode.toggle()
        if playback.isReadAloudMode {
            ActivePlayback.controller.pause()
            if let nav = navigator {
                readAloudStartTask?.cancel()
                readAloudStartTask = Task { @MainActor [weak self, weak player] in
                    guard let self, let player else { return }
                    await self.seekOverlayPlayerToCurrentPosition(player: player, nav: nav)
                    guard !Task.isCancelled, self.playback.isReadAloudMode, self.playback.overlayPlayer === player else { return }
                    player.play()
                    self.startPositionSyncTimer()
                    if self.appearance.readAloudHighlightEnabled, let frag = player.currentFragmentId {
                        self.applyOverlayDecoration(fragmentId: frag, navigator: nav)
                    }
                }
            } else {
                player.play()
                startPositionSyncTimer()
            }
        } else {
            readAloudStartTask?.cancel()
            readAloudStartTask = nil
            host?.readAloudDidDeactivate()
            playback.pendingPreflipTask?.cancel()
            playback.pendingPreflipTask = nil
            player.pause()
            stopPositionSyncTimer()
            if book.isStorytellerReadAloud {
                storytellerActivityAt = Date()
            }
            syncPositionNow(allowRegression: true)
            clearHighlight()
        }
    }

    private func seekOverlayPlayerToCurrentPosition(
        player: MediaOverlayPlayer,
        nav: EPUBNavigatorViewController
    ) async {
        guard !playback.overlayClips.isEmpty else { return }

        playback.lastSyncedClipIndex = -1

        if let startFrag = await firstVisibleOverlayFragment(in: nav) {
            player.seekToFragment(startFrag, preferredHref: nav.currentLocation?.href.string)
            clearPendingInitialPosition()
            AppLogger.library.info("ReadAloud start: visible fragment \(startFrag)")
            return
        }

        if let pendingFragment = playback.pendingInitialFragmentId,
            CFAbsoluteTimeGetCurrent() - playback.pendingInitialSetAt < 120,
            let idx = playback.bestClipIndex(for: pendingFragment, preferredHref: playback.pendingInitialHref)
        {
            let clip = playback.overlayClips[idx]
            player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
            clearPendingInitialPosition()
            AppLogger.library.info("ReadAloud start: restored server fragment \(clip.fragmentId)")
            return
        }
        clearPendingInitialPosition()

        if let locator = nav.currentLocation {
            let href = locator.href.string
            let chapterClips = playback.overlayClips.filter { ReadAloudOverlayTransform.hrefMatches($0.textHref, href) }
            if !chapterClips.isEmpty {
                let prog = locator.locations.progression ?? 0
                let clipIdx = min(max(Int(prog * Double(chapterClips.count)), 0), chapterClips.count - 1)
                let clip = chapterClips[clipIdx]
                player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
                AppLogger.library.info("ReadAloud start: chapter+progression fallback -> \(clip.fragmentId)")
                return
            }
        }

        if let last = playback.lastSyncedFragmentId,
            let idx = playback.overlayClipIndexMap[last], idx < playback.overlayClips.count
        {
            let clip = playback.overlayClips[idx]
            player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
            AppLogger.library.info("ReadAloud start: last synced fragment \(clip.fragmentId)")
            return
        }

        if let locJSON = book.epubLocator,
            let persisted = try? Locator(jsonString: locJSON)
        {
            let href = persisted.href.string
            let chapterClips = playback.overlayClips.filter { ReadAloudOverlayTransform.hrefMatches($0.textHref, href) }
            if !chapterClips.isEmpty {
                let prog = persisted.locations.progression ?? 0
                let clipIdx = min(max(Int(prog * Double(chapterClips.count)), 0), chapterClips.count - 1)
                let clip = chapterClips[clipIdx]
                player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
                AppLogger.library.info("ReadAloud start: persisted locator fallback -> \(clip.fragmentId)")
                return
            }
        }

        AppLogger.library.info("ReadAloud start: no visible/chapter/persisted position found, keeping current clip")
    }

    private func firstVisibleOverlayFragment(in navigator: EPUBNavigatorViewController) async -> String? {
        if let first = await firstVisibleOverlayClipIndex(in: navigator),
            playback.overlayClips.indices.contains(first)
        {
            return playback.overlayClips[first].fragmentId
        }
        guard let locator = navigator.currentLocation else { return nil }
        let currentHref = locator.href.string
        if let clip = playback.overlayClips.first(where: { ReadAloudOverlayTransform.hrefMatches($0.textHref, currentHref) }) {
            return clip.fragmentId
        }
        return nil
    }

    private func applyOverlayDecoration(fragmentId: String, navigator: EPUBNavigatorViewController) {
        let preferredHref = preferredOverlayHref(for: fragmentId, navigator: navigator)
        guard let clipIdx = playback.bestClipIndex(for: fragmentId, preferredHref: preferredHref) else { return }
        let clip = playback.overlayClips[clipIdx]
        let totalProgression = Double(clipIdx) / max(Double(playback.overlayClips.count), 1.0)

        let tint = appearance.readAloudHighlightColor.uiColor
        var decorations: [Decoration] = []

        let granularityMode = appearance.readAloudGranularityMode
        let decorationKey: String
        if clip.granularity == .small, granularityMode != .wordOnly, let groupIdx = clip.parentGroupIndex {
            decorationKey = "group|\(clip.textHref)|\(groupIdx)"
        } else {
            decorationKey = "clip|\(clip.textHref)|\(clip.fragmentId)"
        }
        guard playback.shouldApplyOverlayDecoration(key: decorationKey) else { return }

        if clip.granularity == .small, granularityMode == .wordOnly {
            if let wordLocator = makeOverlayLocator(for: clip, totalProgression: totalProgression) {
                decorations.append(
                    Decoration(
                        id: "overlay-word-active",
                        locator: wordLocator,
                        style: .highlight(tint: tint, isActive: true)
                    )
                )
            }
        } else if clip.granularity == .small, let groupIdx = clip.parentGroupIndex,
            granularityMode != .wordOnly
        {
            let sentenceClips = playback.siblingClips(groupIndex: groupIdx, textHref: clip.textHref)
            for (i, siblingClip) in sentenceClips.enumerated() {
                if let sentenceLocator = makeOverlayLocator(for: siblingClip) {
                    decorations.append(
                        Decoration(
                            id: "overlay-sentence-\(i)",
                            locator: sentenceLocator,
                            style: .highlight(tint: tint, isActive: true)
                        )
                    )
                }
            }
        } else {
            if let locator = makeOverlayLocator(for: clip, totalProgression: totalProgression) {
                decorations.append(
                    Decoration(
                        id: "overlay-active",
                        locator: locator,
                        style: .highlight(tint: tint, isActive: true)
                    )
                )
            }
        }

        if !decorations.isEmpty {
            navigator.apply(decorations: decorations, in: "read-aloud-overlay")
        }
    }

    private func makeOverlayLocator(for clip: AudioOverlayClip, totalProgression: Double? = nil) -> Locator? {
        let clipIdx = playback.bestClipIndex(for: clip.fragmentId, preferredHref: clip.textHref) ?? 0
        let audioTime = playback.overlayTimeline?.audioTime(forClipIndex: clipIdx) ?? 0
        let prog =
            totalProgression
            ?? playback.overlayTimeline?.spokenProgression(atAudioTime: audioTime, clipIndex: clipIdx)
            ?? 0
        return overlayLocator(for: clipIdx, in: playback.overlayClips, totalProgression: prog)
    }

    private func markManualNavigation(at locator: Locator) {
        playback.pendingPreflipTask?.cancel()
        playback.pendingPreflipTask = nil
        playback.manualNavigationGeneration += 1
        playback.lastManualNavigationDocumentHref = ReadAloudOverlayTransform.normalizedDocumentHref(locator.href.string)
        playback.userDidPageTurn = true
        playback.userPageTurnResetTask?.cancel()
        let generation = playback.manualNavigationGeneration
        playback.userPageTurnResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.playback.manualNavigationGeneration == generation else { return }
            self.playback.userDidPageTurn = false
        }
    }

    private func autoPageToFragmentIfNeeded(fragmentId: String, navigator: EPUBNavigatorViewController) async {
        guard !playback.userDidPageTurn else { return }

        let preferredHref = preferredOverlayHref(for: fragmentId, navigator: navigator)
        guard let clipIdx = playback.bestClipIndex(for: fragmentId, preferredHref: preferredHref) else { return }
        let clip = playback.overlayClips[clipIdx]

        guard let currentLocation = navigator.currentLocation else { return }
        let currentHref = currentLocation.href.string
        let clipHref = clip.textHref
        let onSameDocument = currentHref.hasSuffix(clipHref) || clipHref.hasSuffix(currentHref) || currentHref == clipHref

        if onSameDocument, await isOverlayFragmentVisible(fragmentId, in: navigator) {
            return
        }

        if onSameDocument {
            if appearance.scrollEnabled {
                let didScroll: Bool
                if clip.isTextFragment {
                    didScroll = await scrollToTextFragment(clip, in: navigator)
                } else {
                    let safeId = javascriptStringLiteral(fragmentId)
                    let scrollJS = """
                        (function(){
                            const el = document.getElementById(\(safeId));
                            if (!el) return false;
                            const safeAreaTop = parseInt(window.getComputedStyle(document.documentElement).paddingTop) || 0;
                            el.scrollIntoView({behavior:'auto',block:'start'});
                            window.scrollBy(0, -safeAreaTop);
                            return true;
                        })()
                        """
                    if case .success(let value) = await navigator.evaluateJavaScript(scrollJS) {
                        didScroll = value as? Bool == true
                    } else {
                        didScroll = false
                    }
                }
                if !didScroll, let locator = makeOverlayLocator(for: clip) {
                    playback.audioIsNavigating = true
                    _ = await navigator.go(to: locator, options: .init(animated: true))
                    playback.audioIsNavigating = false
                }
            } else if let locator = makeOverlayLocator(for: clip) {
                playback.audioIsNavigating = true
                _ = await navigator.go(to: locator, options: .init(animated: true))
                playback.audioIsNavigating = false
            }
            return
        }

        playback.audioIsNavigating = true

        if let publication {
            if let link = publication.readingOrder.first(where: {
                let linkHref = $0.url().string
                return linkHref.hasSuffix(clipHref) || clipHref.hasSuffix(linkHref) || linkHref == clipHref
            }), var locator = await publication.locate(link) {
                locator = locator.copy(locations: { locations in
                    locations.fragments = [fragmentId]
                })
                _ = await navigator.go(to: locator, options: .init(animated: true))
                playback.audioIsNavigating = false
                return
            }
        }

        let clipProg = Double(clipIdx) / max(Double(playback.overlayClips.count), 1.0)
        let locatorJSON = """
            {
              "href": "\(clipHref)",
              "type": "application/xhtml+xml",
              "locations": {
                "fragments": ["\(fragmentId)"],
                "totalProgression": \(clipProg)
              }
            }
            """
        if let locator = try? Locator(jsonString: locatorJSON) {
            _ = await navigator.go(to: locator, options: .init(animated: true))
        }
        playback.audioIsNavigating = false
    }

    private func rescheduleCurrentPageFollow() {
        playback.pendingPreflipTask?.cancel()
        playback.pendingPreflipTask = nil
        guard playback.isReadAloudMode,
            let player = playback.overlayPlayer,
            player.isPlaying,
            let fragmentId = player.currentFragmentId,
            let navigator
        else { return }
        Task { @MainActor [weak self, weak navigator] in
            guard let self, let navigator else { return }
            await self.schedulePagePreflipIfNeeded(fragmentId: fragmentId, navigator: navigator)
        }
    }

    private func schedulePagePreflipIfNeeded(fragmentId: String, navigator: EPUBNavigatorViewController) async {
        playback.pendingPreflipTask?.cancel()
        playback.pendingPreflipTask = nil

        guard !playback.userDidPageTurn,
            !appearance.scrollEnabled,
            let player = playback.overlayPlayer, player.isPlaying,
            let clipIdx = playback.bestClipIndex(for: fragmentId, preferredHref: preferredOverlayHref(for: fragmentId, navigator: navigator)),
            clipIdx + 1 < playback.overlayClips.count
        else { return }

        let split = await overlayFragmentSplit(fragmentId, in: navigator)
        guard let split else { return }

        let currentClip = playback.overlayClips[clipIdx]
        let clipDuration = max(0, currentClip.duration)
        guard clipDuration > 0 else { return }

        let rate = max(player.playbackRate, 0.25)
        let leadSeconds = Double(appearance.readAloudPageTurnLeadMs) / 1000.0
        let delay =
            split.offScreenRatio >= 0.9
            ? 0
            : ReaderPageTurnTiming.delay(
                clipDuration: clipDuration,
                elapsedClipTime: player.currentClipElapsedTime ?? 0,
                visibleRatio: split.visibleRatio,
                playbackRate: rate,
                lead: leadSeconds
            )
        let nanos = UInt64(delay * 1_000_000_000)
        let scheduledGeneration = playback.manualNavigationGeneration
        let scheduledDocumentHref = ReadAloudOverlayTransform.normalizedDocumentHref(navigator.currentLocation?.href.string)

        playback.pendingPreflipTask = Task { @MainActor [weak self, weak navigator] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled,
                let self, let navigator,
                let player = self.playback.overlayPlayer,
                player.isPlaying,
                player.currentFragmentId == fragmentId,
                self.playback.manualNavigationGeneration == scheduledGeneration,
                ReadAloudOverlayTransform.normalizedDocumentHref(navigator.currentLocation?.href.string) == scheduledDocumentHref,
                !self.playback.userDidPageTurn,
                !self.playback.audioIsNavigating
            else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.playback.lastPagePreflipAt >= 0.3 else { return }
            self.playback.lastPagePreflipAt = now
            self.playback.audioIsNavigating = true
            _ = await navigator.goForward(options: .init(animated: true))
            self.playback.audioIsNavigating = false
        }
    }

    private func overlayFragmentSplit(
        _ fragmentId: String,
        in navigator: EPUBNavigatorViewController
    ) async -> OverlayFragmentSplit? {
        guard !fragmentId.hasPrefix(":~:text=") else { return nil }
        let fragment = javascriptStringLiteral(fragmentId)
        let js = """
            (function() {
                const el = document.getElementById(\(fragment));
                if (!el) return null;
                const writingMode = window.getComputedStyle(document.body).writingMode || '';
                if (writingMode.startsWith('vertical')) return null;
                const rects = Array.from(el.getClientRects()).filter((r) => r.width > 0 && r.height > 0);
                if (!rects.length) return null;
                const viewport = { left: 0, right: window.innerWidth, top: 0, bottom: window.innerHeight };
                const rtl = window.getComputedStyle(document.documentElement).direction === 'rtl';
                let totalArea = 0;
                let visibleArea = 0;
                let forwardArea = 0;
                let backwardArea = 0;
                for (const rect of rects) {
                    const area = rect.width * rect.height;
                    totalArea += area;
                    const overlapWidth = Math.max(0, Math.min(rect.right, viewport.right) - Math.max(rect.left, viewport.left));
                    const overlapHeight = Math.max(0, Math.min(rect.bottom, viewport.bottom) - Math.max(rect.top, viewport.top));
                    visibleArea += overlapWidth * overlapHeight;
                    if (overlapHeight <= 0) continue;
                    const forwardWidth = rtl
                        ? Math.max(0, Math.min(rect.width, viewport.left - rect.left))
                        : Math.max(0, Math.min(rect.width, rect.right - viewport.right));
                    const backwardWidth = rtl
                        ? Math.max(0, Math.min(rect.width, rect.right - viewport.right))
                        : Math.max(0, Math.min(rect.width, viewport.left - rect.left));
                    forwardArea += forwardWidth * overlapHeight;
                    backwardArea += backwardWidth * overlapHeight;
                }
                if (!totalArea || !visibleArea) return null;
                const visibleRatio = visibleArea / totalArea;
                if (visibleRatio >= 0.98) return null;
                const forwardRatio = forwardArea / totalArea;
                const backwardRatio = backwardArea / totalArea;
                const progressionRatio = rtl ? backwardRatio : forwardRatio;
                const oppositeRatio = rtl ? forwardRatio : backwardRatio;
                if (progressionRatio < 0.1 || progressionRatio <= oppositeRatio) return null;
                return JSON.stringify({ visibleRatio: visibleRatio, offScreenRatio: progressionRatio });
            })();
            """

        guard case .success(let value) = await navigator.evaluateJavaScript(js),
            let json = value as? String,
            let data = json.data(using: .utf8),
            let split = try? JSONDecoder().decode(OverlayFragmentSplit.self, from: data)
        else { return nil }
        return OverlayFragmentSplit(
            visibleRatio: min(max(split.visibleRatio, 0), 1),
            offScreenRatio: min(max(split.offScreenRatio, 0), 1)
        )
    }

    func syncAudioToVisiblePage() {
        guard !playback.audioIsNavigating else { return }

        guard playback.isReadAloudMode,
            let player = playback.overlayPlayer,
            !playback.overlayClips.isEmpty,
            let navigator
        else { return }

        if let currentFrag = player.currentFragmentId {
            Task { @MainActor in
                if await self.isOverlayFragmentVisible(currentFrag, in: navigator) {
                    return
                }
                self.seekAudioToVisibleContent(player: player, navigator: navigator)
            }
            return
        }

        seekAudioToVisibleContent(player: player, navigator: navigator)
    }

    private func seekAudioToVisibleContent(player: MediaOverlayPlayer, navigator: EPUBNavigatorViewController) {
        let generation = playback.manualNavigationGeneration

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard self.playback.manualNavigationGeneration == generation else { return }

            if let currentFrag = player.currentFragmentId,
                await self.isOverlayFragmentVisible(currentFrag, in: navigator)
            {
                return
            }

            if let first = await self.firstVisibleOverlayClipIndex(in: navigator),
                self.playback.overlayClips.indices.contains(first)
            {
                let clip = self.playback.overlayClips[first]
                player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
                return
            }

            guard let locator = navigator.currentLocation else { return }
            let visibleHref = locator.href.string
            let matchingClips = self.playback.overlayClips.enumerated().filter {
                ReadAloudOverlayTransform.hrefMatches($0.element.textHref, visibleHref)
            }
            guard let first = matchingClips.first else { return }
            let clip = self.playback.overlayClips[first.offset]
            player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
        }
    }

    func handleTap(at point: CGPoint, in navigator: EPUBNavigatorViewController) {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else { return }
        Task { @MainActor in
            let js = """
                (function() {
                    var el = document.elementFromPoint(\(point.x), \(point.y));
                    while (el && !el.id && el.parentElement) { el = el.parentElement; }
                    return (el && el.id) ? el.id : null;
                })();
                """
            guard case .success(let value) = await navigator.evaluateJavaScript(js),
                let tappedId = value as? String, !tappedId.isEmpty,
                let clipIdx = self.playback.bestClipIndex(for: tappedId, preferredHref: navigator.currentLocation?.href.string)
            else { return }
            let clip = self.playback.overlayClips[clipIdx]
            player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
            if !player.isPlaying { player.play() }
        }
    }

    private var hasTextFragmentClips: Bool {
        playback.overlayClips.contains(where: { $0.isTextFragment })
    }

    private func firstVisibleOverlayClipIndex(in navigator: EPUBNavigatorViewController) async -> Int? {
        if let fullyVisible = await visibleOverlayClipIndices(in: navigator, fullyVisible: true),
            let first = fullyVisible.first
        {
            return first
        }
        return await visibleOverlayClipIndices(in: navigator, fullyVisible: false)?.first
    }

    private func visibleOverlayClipIndices(
        in navigator: EPUBNavigatorViewController,
        fullyVisible: Bool
    ) async -> [Int]? {
        let preferredHref = navigator.currentLocation?.href.string
        let ids =
            fullyVisible
            ? await fullyVisibleOverlayFragmentIDs(in: navigator)
            : await visibleOverlayFragmentIDs(in: navigator)
        var indices =
            ids?.compactMap {
                playback.bestClipIndex(for: $0, preferredHref: preferredHref)
            } ?? []
        if hasTextFragmentClips {
            indices.append(
                contentsOf: await visibleTextFragmentClipIndices(
                    in: navigator,
                    preferredHref: preferredHref,
                    fullyVisible: fullyVisible
                )
            )
        }
        let ordered = Array(Set(indices)).sorted()
        return ordered.isEmpty ? nil : ordered
    }

    private func visibleTextFragmentClipIndices(
        in navigator: EPUBNavigatorViewController,
        preferredHref: String?,
        fullyVisible: Bool
    ) async -> [Int] {
        let chapterCandidates = playback.overlayClips.enumerated().filter { _, clip in
            clip.isTextFragment && (preferredHref.map { ReadAloudOverlayTransform.hrefMatches(clip.textHref, $0) } ?? true)
        }
        guard !chapterCandidates.isEmpty else { return [] }

        let locator = navigator.currentLocation
        let exactFragment = locator?.locations.fragments.first {
            !$0.hasPrefix("epubcfi(") && !$0.hasPrefix("t=")
        }
        let exactClipIndex = exactFragment.flatMap {
            playback.bestClipIndex(for: $0, preferredHref: preferredHref)
        }
        let anchorPosition: Int = {
            if let exactClipIndex,
                let offset = chapterCandidates.firstIndex(where: { $0.offset == exactClipIndex })
            {
                return offset
            }
            if playback.isReadAloudMode,
                let playerIndex = playback.overlayPlayer?.currentClipIndex,
                let offset = chapterCandidates.firstIndex(where: { $0.offset == playerIndex })
            {
                return offset
            }
            let progression = locator?.locations.progression ?? 0
            return min(
                max(Int(progression * Double(chapterCandidates.count)), 0),
                chapterCandidates.count - 1
            )
        }()
        let candidateLimit = 320
        let lowerBound = max(0, min(anchorPosition - candidateLimit / 2, chapterCandidates.count - candidateLimit))
        let upperBound = min(chapterCandidates.count, lowerBound + candidateLimit)
        let nearbyCandidates = chapterCandidates[lowerBound..<upperBound]

        let targets: [[String: Any]] = nearbyCandidates.compactMap { index, clip in
            guard let fragment = clip.textFragment else { return nil }
            return [
                "index": index,
                "textStart": fragment.textStart,
                "textEnd": (fragment.textEnd as Any?) ?? NSNull(),
                "prefix": (fragment.prefix as Any?) ?? NSNull(),
                "suffix": (fragment.suffix as Any?) ?? NSNull(),
            ]
        }
        guard !targets.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: targets),
            let targetsJSON = String(data: data, encoding: .utf8)
        else { return [] }

        let visibilityTest =
            fullyVisible
            ? "rects.length > 0 && rects.every((r) => r.top >= 0 && r.bottom <= window.innerHeight && r.left >= 0 && r.right <= window.innerWidth && (r.width > 0 || r.height > 0))"
            : "rects.some((r) => r.bottom > 0 && r.top < window.innerHeight && r.right > 0 && r.left < window.innerWidth && (r.width > 0 || r.height > 0))"
        let js = """
            (function() {
                const targets = \(targetsJSON);
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                const nodes = [];
                let fullText = "";
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const value = node.textContent || "";
                    if (!value.length) continue;
                    nodes.push({ node, start: fullText.length, end: fullText.length + value.length });
                    fullText += value;
                }
                function locateOffset(offset) {
                    for (const entry of nodes) {
                        if (offset >= entry.start && offset <= entry.end) {
                            return { node: entry.node, offset: Math.max(0, Math.min(entry.node.textContent.length, offset - entry.start)) };
                        }
                    }
                    return null;
                }
                const matches = [];
                for (const target of targets) {
                    let searchFrom = 0;
                    if (target.prefix && target.prefix.length) {
                        const prefixIndex = fullText.indexOf(target.prefix);
                        if (prefixIndex >= 0) searchFrom = prefixIndex + target.prefix.length;
                    }
                    let startIndex = -1;
                    let endIndex = -1;
                    while (true) {
                        startIndex = fullText.indexOf(target.textStart, searchFrom);
                        if (startIndex < 0) break;
                        endIndex = startIndex + target.textStart.length;
                        if (target.textEnd && target.textEnd.length) {
                            const textEndIndex = fullText.indexOf(target.textEnd, endIndex);
                            if (textEndIndex < 0) {
                                searchFrom = startIndex + 1;
                                continue;
                            }
                            endIndex = textEndIndex + target.textEnd.length;
                        }
                        const prefixMatches = !target.prefix || fullText.slice(0, startIndex).endsWith(target.prefix);
                        const suffixMatches = !target.suffix || fullText.slice(endIndex).startsWith(target.suffix);
                        if (prefixMatches && suffixMatches) break;
                        searchFrom = startIndex + 1;
                    }
                    if (startIndex < 0 || endIndex < 0) continue;
                    const start = locateOffset(startIndex);
                    const end = locateOffset(endIndex);
                    if (!start || !end) continue;
                    const range = document.createRange();
                    try {
                        range.setStart(start.node, start.offset);
                        range.setEnd(end.node, end.offset);
                        const rects = Array.from(range.getClientRects());
                        if (\(visibilityTest)) {
                            const first = rects[0];
                            matches.push({ index: target.index, top: first ? first.top : 0, left: first ? first.left : 0 });
                        }
                    } finally {
                        range.detach?.();
                    }
                }
                matches.sort((a, b) => Math.abs(a.top - b.top) > 1 ? a.top - b.top : a.left - b.left);
                return JSON.stringify(matches.map((match) => match.index));
            })();
            """

        guard case .success(let value) = await navigator.evaluateJavaScript(js),
            let result = value as? String,
            let resultData = result.data(using: .utf8),
            let indices = try? JSONDecoder().decode([Int].self, from: resultData)
        else { return [] }
        return indices
    }

    private func visibleOverlayFragmentIDs(in navigator: EPUBNavigatorViewController) async -> [String]? {
        let js = """
            (function() {
                const elements = Array.from(document.querySelectorAll('[id]'));
                const visible = elements.filter((el) => {
                    const r = el.getBoundingClientRect();
                    return r.bottom > 0 && r.top < window.innerHeight && r.right > 0 && r.left < window.innerWidth && (r.width > 0 || r.height > 0);
                }).sort((a, b) => {
                    const ar = a.getBoundingClientRect();
                    const br = b.getBoundingClientRect();
                    if (Math.abs(ar.top - br.top) > 1) return ar.top - br.top;
                    return ar.left - br.left;
                }).map((el) => el.id).slice(0, 32);
                return JSON.stringify(visible);
            })();
            """

        guard case .success(let value) = await navigator.evaluateJavaScript(js),
            let result = value as? String,
            let data = result.data(using: .utf8),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }

        let filtered = ids.filter { playback.overlayClipFragmentSet.contains($0) }
        return filtered.isEmpty ? nil : filtered
    }

    func captureVisibleOverlayPosition(
        in navigator: EPUBNavigatorViewController,
        locator suppliedLocator: Locator? = nil
    ) async -> Bool {
        guard let timeline = playback.overlayTimeline,
            let locator = suppliedLocator ?? navigator.currentLocation
        else { return false }
        guard let clipIndex = await firstVisibleOverlayClipIndex(in: navigator),
            let audioTime = timeline.audioTime(forClipIndex: clipIndex)
        else { return false }

        let totalProgression =
            locator.locations.totalProgression
            ?? observedProgression
            ?? currentProgress
            ?? timeline.spokenProgression(atAudioTime: audioTime, clipIndex: clipIndex)
        guard
            let locatorJSON = timeline.textLocatorJSONString(
                clipIndex: clipIndex,
                audioTime: audioTime,
                totalProgression: totalProgression
            )
        else { return false }

        normalReadingOverlayClipIndex = clipIndex
        locatorProgress.updateLocatorJSON(locatorJSON)
        return true
    }

    private func fullyVisibleOverlayFragmentIDs(in navigator: EPUBNavigatorViewController) async -> [String]? {
        let js = """
            (function() {
                const elements = Array.from(document.querySelectorAll('[id]'));
                const visible = elements.filter((el) => {
                    const r = el.getBoundingClientRect();
                    return r.top >= 0 && r.bottom <= window.innerHeight && r.left >= 0 && r.right <= window.innerWidth && (r.width > 0 || r.height > 0);
                }).sort((a, b) => {
                    const ar = a.getBoundingClientRect();
                    const br = b.getBoundingClientRect();
                    if (Math.abs(ar.top - br.top) > 1) return ar.top - br.top;
                    return ar.left - br.left;
                }).map((el) => el.id).slice(0, 32);
                return JSON.stringify(visible);
            })();
            """

        guard case .success(let value) = await navigator.evaluateJavaScript(js),
            let result = value as? String,
            let data = result.data(using: .utf8),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        let filtered = ids.filter { playback.overlayClipFragmentSet.contains($0) }
        return filtered.isEmpty ? nil : filtered
    }

    private func isOverlayFragmentVisible(_ fragmentId: String, in navigator: EPUBNavigatorViewController) async -> Bool {
        if fragmentId.hasPrefix(":~:text=") {
            return await isTextFragmentVisible(fragmentId, in: navigator)
        }

        let safeId = javascriptStringLiteral(fragmentId)
        let js = """
            (function() {
                const el = document.getElementById(\(safeId));
                if (!el) return false;
                const r = el.getBoundingClientRect();
                return r.bottom > 0 && r.top < window.innerHeight && r.right > 0 && r.left < window.innerWidth && (r.width > 0 || r.height > 0);
            })();
            """
        if case .success(let value) = await navigator.evaluateJavaScript(js),
            let isVisible = value as? Bool
        {
            return isVisible
        }
        return false
    }

    private func isTextFragmentVisible(_ directive: String, in navigator: EPUBNavigatorViewController) async -> Bool {
        guard
            let textFrag = TextFragment.parse(
                String(directive.dropFirst(":~:text=".count))
            )
        else { return false }

        let textStart = javascriptStringLiteral(textFrag.textStart)
        let textEnd = javascriptNullableStringLiteral(textFrag.textEnd)
        let prefix = javascriptNullableStringLiteral(textFrag.prefix)
        let suffix = javascriptNullableStringLiteral(textFrag.suffix)

        let js = """
            (function() {
                const target = { textStart: \(textStart), textEnd: \(textEnd), prefix: \(prefix), suffix: \(suffix) };
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                const nodes = [];
                let fullText = "";
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const value = node.textContent || "";
                    if (!value.length) continue;
                    nodes.push({ node, start: fullText.length, end: fullText.length + value.length, value });
                    fullText += value;
                }

                function locateOffset(globalOffset) {
                    for (const entry of nodes) {
                        if (globalOffset >= entry.start && globalOffset <= entry.end) {
                            return { node: entry.node, offset: Math.max(0, Math.min(entry.node.textContent.length, globalOffset - entry.start)) };
                        }
                    }
                    return null;
                }

                let searchFrom = 0;
                let startIndex = -1;
                let endIndex = -1;
                while (true) {
                    startIndex = fullText.indexOf(target.textStart, searchFrom);
                    if (startIndex < 0) return false;
                    endIndex = startIndex + target.textStart.length;
                    if (target.textEnd && target.textEnd.length) {
                        const textEndIndex = fullText.indexOf(target.textEnd, endIndex);
                        if (textEndIndex < 0) {
                            searchFrom = startIndex + 1;
                            continue;
                        }
                        endIndex = textEndIndex + target.textEnd.length;
                    }
                    const prefixMatches = !target.prefix || fullText.slice(0, startIndex).endsWith(target.prefix);
                    const suffixMatches = !target.suffix || fullText.slice(endIndex).startsWith(target.suffix);
                    if (prefixMatches && suffixMatches) break;
                    searchFrom = startIndex + 1;
                }

                const start = locateOffset(startIndex);
                const end = locateOffset(endIndex);
                if (!start || !end) return false;
                var range = document.createRange();
                try {
                    range.setStart(start.node, start.offset);
                    range.setEnd(end.node, end.offset);
                    const rects = Array.from(range.getClientRects());
                    for (const r of rects) {
                        if (r.bottom > 0 && r.top < window.innerHeight && r.right > 0 && r.left < window.innerWidth && r.width > 0 && r.height > 0) {
                            return true;
                        }
                    }
                } finally {
                    range.detach?.();
                }
                return false;
            })();
            """
        if case .success(let value) = await navigator.evaluateJavaScript(js),
            let isVisible = value as? Bool
        {
            return isVisible
        }
        return false
    }

    private func scrollToTextFragment(
        _ clip: AudioOverlayClip,
        in navigator: EPUBNavigatorViewController
    ) async -> Bool {
        guard let fragment = clip.textFragment else { return false }
        let target: [String: Any] = [
            "textStart": fragment.textStart,
            "textEnd": (fragment.textEnd as Any?) ?? NSNull(),
            "prefix": (fragment.prefix as Any?) ?? NSNull(),
            "suffix": (fragment.suffix as Any?) ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: target),
            let targetJSON = String(data: data, encoding: .utf8)
        else { return false }
        let js = """
            (function() {
                const target = \(targetJSON);
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                const nodes = [];
                let fullText = "";
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const value = node.textContent || "";
                    if (!value.length) continue;
                    nodes.push({ node, start: fullText.length, end: fullText.length + value.length });
                    fullText += value;
                }
                function locateOffset(offset) {
                    for (const entry of nodes) {
                        if (offset >= entry.start && offset <= entry.end) {
                            return { node: entry.node, offset: Math.max(0, Math.min(entry.node.textContent.length, offset - entry.start)) };
                        }
                    }
                    return null;
                }
                let searchFrom = 0;
                let startIndex = -1;
                let endIndex = -1;
                while (true) {
                    startIndex = fullText.indexOf(target.textStart, searchFrom);
                    if (startIndex < 0) return false;
                    endIndex = startIndex + target.textStart.length;
                    if (target.textEnd && target.textEnd.length) {
                        const textEndIndex = fullText.indexOf(target.textEnd, endIndex);
                        if (textEndIndex < 0) {
                            searchFrom = startIndex + 1;
                            continue;
                        }
                        endIndex = textEndIndex + target.textEnd.length;
                    }
                    const prefixMatches = !target.prefix || fullText.slice(0, startIndex).endsWith(target.prefix);
                    const suffixMatches = !target.suffix || fullText.slice(endIndex).startsWith(target.suffix);
                    if (prefixMatches && suffixMatches) break;
                    searchFrom = startIndex + 1;
                }
                const start = locateOffset(startIndex);
                const end = locateOffset(endIndex);
                if (!start || !end) return false;
                const range = document.createRange();
                try {
                    range.setStart(start.node, start.offset);
                    range.setEnd(end.node, end.offset);
                    const rect = range.getBoundingClientRect();
                    if (!rect || (!rect.width && !rect.height)) return false;
                    const safeAreaTop = parseInt(window.getComputedStyle(document.documentElement).paddingTop) || 0;
                    window.scrollTo({ top: Math.max(0, window.scrollY + rect.top - safeAreaTop), behavior: "auto" });
                    return true;
                } finally {
                    range.detach?.();
                }
            })();
            """
        if case .success(let value) = await navigator.evaluateJavaScript(js) {
            return value as? Bool == true
        }
        return false
    }

    private func javascriptStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    private func javascriptNullableStringLiteral(_ string: String?) -> String {
        guard let string else { return "null" }
        return javascriptStringLiteral(string)
    }

    private func startPositionSyncTimer() {
        playback.startPositionSyncTimer { [weak self] in
            self?.syncPositionNow()
        }
    }

    private func stopPositionSyncTimer() {
        playback.stopPositionSyncTimer()
    }

    func reconcileAfterForeground() {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else {
            MediaOverlayPlaybackService.shared.syncCurrentPlaybackPositionIfActive(for: book)
            return
        }

        player.syncToPlayhead()
        if player.isPlaying {
            startPositionSyncTimer()
        }
        syncPositionNow()

        guard let nav = navigator,
            let fragmentId = player.currentFragmentId
        else { return }

        playback.overlayFragmentUpdateTask?.cancel()
        playback.overlayFragmentUpdateTask = Task { @MainActor [weak self, weak nav] in
            guard let self, let nav, !Task.isCancelled else { return }
            let prog = self.currentProgress ?? self.book.canonicalEbookProgress
            await self.updateOverlayTimeEstimates(currentFrag: fragmentId, totalProgression: prog)
            guard !Task.isCancelled, self.playback.isReadAloudMode else { return }
            if self.appearance.readAloudHighlightEnabled {
                self.applyOverlayDecoration(fragmentId: fragmentId, navigator: nav)
            }
            await self.autoPageToFragmentIfNeeded(fragmentId: fragmentId, navigator: nav)
            guard !Task.isCancelled else { return }
            await self.schedulePagePreflipIfNeeded(fragmentId: fragmentId, navigator: nav)
            await self.host?.readAloudDidAdvanceHighlight()
        }
    }

    func syncPositionForUserAction() {
        if book.isStorytellerReadAloud {
            storytellerActivityAt = Date()
        }
        syncPositionNow(allowRegression: true)
        host?.readAloudRequestsProgressFlush(reason: "user-action")
    }

    func togglePlayback() {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else { return }
        player.togglePlayPause()
        if !player.isPlaying {
            syncPositionForUserAction()
        }
    }

    func previousSegment() {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else { return }
        player.previous()
        syncPositionForUserAction()
    }

    func nextSegment() {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else { return }
        player.next()
        syncPositionForUserAction()
    }

    func skipBackward(seconds: TimeInterval) {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else { return }
        player.remoteSkipBackward(by: seconds)
        syncPositionForUserAction()
    }

    func skipForward(seconds: TimeInterval) {
        guard playback.isReadAloudMode, let player = playback.overlayPlayer else { return }
        player.remoteSkipForward(by: seconds)
        syncPositionForUserAction()
    }

    func setSpeed(_ speed: Double) {
        guard let player = playback.overlayPlayer else { return }
        player.setSpeed(speed)
        if player.isPlaying {
            rescheduleCurrentPageFollow()
        }
    }

    func toggleHighlighting() {
        appearanceController.appearance.readAloudHighlightEnabled.toggle()
        if !appearance.readAloudHighlightEnabled {
            clearHighlight()
        } else if let navigator,
            let fragmentId = playback.overlayPlayer?.currentFragmentId
        {
            applyOverlayDecoration(fragmentId: fragmentId, navigator: navigator)
        }
    }

    func toggleSkipSkippables() {
        guard let player = playback.overlayPlayer else { return }
        player.skipSkippables.toggle()
    }

    private func presyncOverlayPlayerToReadingPosition(nav: EPUBNavigatorViewController) async {
        guard let player = playback.overlayPlayer, !playback.overlayClips.isEmpty else { return }

        if let first = await firstVisibleOverlayClipIndex(in: nav),
            playback.overlayClips.indices.contains(first)
        {
            let clip = playback.overlayClips[first]
            player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
            return
        }

        guard let locator = nav.currentLocation else { return }
        let href = locator.href.string
        if let matchIdx = playback.overlayClips.firstIndex(where: {
            ReadAloudOverlayTransform.hrefMatches($0.textHref, href)
        }) {
            let chapterClips = playback.overlayClips.filter { ReadAloudOverlayTransform.hrefMatches($0.textHref, href) }
            if let prog = locator.locations.progression, prog > 0.001, !chapterClips.isEmpty {
                let clipIdx = min(Int(prog * Double(chapterClips.count)), chapterClips.count - 1)
                let clip = chapterClips[clipIdx]
                player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
            } else {
                let clip = playback.overlayClips[matchIdx]
                player.seekToFragment(clip.fragmentId, preferredHref: clip.textHref)
            }
        }
    }

    func syncPositionNow(
        allowRegression: Bool = false,
        scheduleRemoteSync: Bool = true
    ) {
        playback.overlayPlayer?.refreshPositionFromPlayhead()
        guard let player = playback.overlayPlayer,
            let timeline = playback.overlayTimeline,
            let fragmentId = player.currentFragmentId,
            player.currentClipIndex >= 0,
            player.currentClipIndex < playback.overlayClips.count
        else { return }
        let clipIdx = player.currentClipIndex
        let audioTime = player.currentTime

        guard
            fragmentId != playback.lastSyncedFragmentId
                || clipIdx != playback.lastSyncedClipIndex
                || abs(audioTime - playback.lastSyncedAudioTime) >= 1
        else { return }

        if !allowRegression, !player.isPlaying, clipIdx < playback.lastSyncedClipIndex { return }

        let computedDuration = timeline.totalAudioDuration
        let totalProgression = timeline.spokenProgression(atAudioTime: audioTime, clipIndex: clipIdx)
        let existingProgress = book.canonicalEbookProgress
        if !allowRegression, totalProgression < 0.001 && existingProgress > 0.01 {
            AppLogger.library.info("Skipping read-aloud sync at 0%. Preserving existing \(Int(existingProgress * 100))%")
            return
        }
        if book.isStorytellerReadAloud, player.isPlaying {
            storytellerActivityAt = Date()
        }
        guard !book.isStorytellerReadAloud || storytellerActivityAt != nil else { return }
        let observedAt = storytellerActivityAt ?? Date()
        storytellerActivityAt = nil

        playback.lastSyncedFragmentId = fragmentId
        playback.lastSyncedClipIndex = clipIdx
        playback.lastSyncedAudioTime = audioTime

        let readiumLocatorJSON = navigator?.currentLocation.flatMap { try? $0.jsonString() }

        let overlayLocatorString = timeline.textLocatorJSONString(
            clipIndex: clipIdx,
            audioTime: audioTime,
            totalProgression: totalProgression
        )

        host?.readAloudDidCommitPosition(
            ReaderReadAloudPositionCommit(
                progression: totalProgression,
                locatorJSON: overlayLocatorString ?? readiumLocatorJSON,
                audioTime: audioTime,
                audioDuration: computedDuration,
                observedAt: observedAt,
                isAuthoritative: allowRegression || !scheduleRemoteSync,
                schedulesRemoteSync: scheduleRemoteSync
            )
        )
    }

    func clearHighlight() {
        guard let navigator else { return }
        navigator.apply(decorations: [], in: "read-aloud-overlay")
    }

    private func preferredOverlayHref(for fragmentId: String, navigator: EPUBNavigatorViewController) -> String? {
        if let idx = playback.playingClipIndex(matching: fragmentId) {
            return playback.overlayClips[idx].textHref
        }
        return navigator.currentLocation?.href.string
    }

    private func updateOverlayTimeEstimates(currentFrag: String, totalProgression: Double) async {
        guard !playback.overlayClips.isEmpty else { return }

        let currentIdx =
            playback.playingClipIndex(matching: currentFrag)
            ?? playback.bestClipIndex(for: currentFrag, preferredHref: nil)
            ?? 0
        let currentClip = playback.overlayClips[currentIdx]
        let currentHref = currentClip.textHref

        let chapterSecsLeft =
            playback.overlayRemainingChapterSecondsByClipIndex.indices.contains(currentIdx)
            ? playback.overlayRemainingChapterSecondsByClipIndex[currentIdx]
            : currentClip.duration

        var bookSecsLeft =
            playback.overlayRemainingBookSecondsByClipIndex.indices.contains(currentIdx)
            ? playback.overlayRemainingBookSecondsByClipIndex[currentIdx]
            : chapterSecsLeft
        if !playback.overlayChapterDurations.isEmpty {
            bookSecsLeft = chapterSecsLeft
            var pastCurrent = false
            for href in playback.orderedOverlayChapterHrefs {
                if href == currentHref { pastCurrent = true; continue }
                guard pastCurrent else { continue }
                let dur =
                    playback.overlayChapterDurations[href]
                    ?? playback.overlayChapterDurations.first(where: { href.hasSuffix($0.key) || $0.key.hasSuffix(href) })?.value
                    ?? 0
                bookSecsLeft += dur
            }
        }

        let chapterMin = chapterSecsLeft > 0 ? max(1, Int(ceil(chapterSecsLeft / 60))) : nil
        let bookMin = bookSecsLeft > 0 ? max(1, Int(ceil(bookSecsLeft / 60))) : nil

        host?.readAloudDidUpdateTimeEstimates(chapterMinutes: chapterMin, bookMinutes: bookMin)
    }

    func resolvedInitialLocation(
        rawLocator: String,
        parsed: Locator,
        publication: Publication
    ) async -> Locator? {
        guard let clips = try? await EPUB3SMILParser.parse(publication: publication, epubFileURL: publicationFileURL),
            !clips.isEmpty
        else { return nil }
        let timeline = MediaOverlayTimeline(
            clips: clips,
            orderedAudioDurations: orderedBookAudioDurations()
        )

        if let resolved = timeline.resolveEPUB3Locator(locatorJSON: rawLocator) {
            let totalProgression =
                parsed.locations.totalProgression
                ?? timeline.spokenProgression(atAudioTime: resolved.audioTime, clipIndex: resolved.clipIndex)
            primeInitialPosition(clipIndex: resolved.clipIndex, in: clips)
            guard
                let json = timeline.textLocatorJSONString(
                    clipIndex: resolved.clipIndex,
                    audioTime: resolved.audioTime,
                    totalProgression: totalProgression
                )
            else { return nil }

            let candidateHrefs = (publication.readingOrder + publication.resources).map(\.href)
            return try? Locator(
                jsonString: ReaderLocationController.retargetingHref(json, candidateHrefs: candidateHrefs)
            )
        }

        return nil
    }

    private func primeInitialPosition(clipIndex: Int, in clips: [AudioOverlayClip]) {
        guard clips.indices.contains(clipIndex) else { return }
        let clip = clips[clipIndex]
        playback.pendingInitialFragmentId = clip.fragmentId
        playback.pendingInitialHref = clip.textHref
        playback.pendingInitialSetAt = CFAbsoluteTimeGetCurrent()
    }

    private func clearPendingInitialPosition() {
        playback.pendingInitialFragmentId = nil
        playback.pendingInitialHref = nil
        playback.pendingInitialSetAt = 0
    }

    func overlayLocatorForCurrentReadingPosition(progression: Double) -> (locatorJSON: String, audioTime: TimeInterval)? {
        guard let timeline = playback.overlayTimeline,
            !playback.overlayClips.isEmpty,
            let locator = navigator?.currentLocation
        else { return nil }

        let href = locator.href.string
        let textFragment = locator.locations.fragments.first {
            !$0.hasPrefix("epubcfi(") && !$0.hasPrefix("t=")
        }

        let cachedClipIndex = normalReadingOverlayClipIndex.flatMap { index in
            playback.overlayClips.indices.contains(index) && ReadAloudOverlayTransform.hrefMatches(playback.overlayClips[index].textHref, href)
                ? index
                : nil
        }
        let clipIndex =
            cachedClipIndex ?? textFragment.flatMap {
                ReadAloudOverlayTransform.bestClipIndex(in: playback.overlayClips, fragmentId: $0, preferredHref: href)
            } ?? locator.locations.progression.flatMap {
                timeline.clipIndex(atChapterProgression: $0, href: href)
            } ?? timeline.clipIndex(atChapterProgression: 0, href: href)

        guard let clipIndex,
            let audioTime = timeline.audioTime(forClipIndex: clipIndex),
            let locatorJSON = timeline.textLocatorJSONString(
                clipIndex: clipIndex,
                audioTime: audioTime,
                totalProgression: progression
            )
        else { return nil }

        return (locatorJSON, audioTime)
    }

    private func overlayLocator(
        for clipIndex: Int,
        in clips: [AudioOverlayClip],
        totalProgression: Double? = nil
    ) -> Locator? {
        guard clips.indices.contains(clipIndex) else { return nil }
        let timeline =
            playback.overlayTimeline?.clips.count == clips.count
            ? playback.overlayTimeline
            : MediaOverlayTimeline(clips: clips, orderedAudioDurations: orderedBookAudioDurations())
        guard let timeline,
            let audioTime = timeline.audioTime(forClipIndex: clipIndex),
            let json = timeline.textLocatorJSONString(
                clipIndex: clipIndex,
                audioTime: audioTime,
                totalProgression: totalProgression
            )
        else { return nil }
        return try? Locator(jsonString: json)
    }

    func currentArtifactLocation(chapterTitle: String?) -> ReaderArtifactLocation? {
        guard playback.isReadAloudMode,
            let player = playback.overlayPlayer,
            let timeline = playback.overlayTimeline,
            player.currentClipIndex >= 0,
            player.currentClipIndex < playback.overlayClips.count
        else { return nil }

        let clipIdx = player.currentClipIndex
        let audioTime = player.currentTime
        let totalProgression = timeline.spokenProgression(atAudioTime: audioTime, clipIndex: clipIdx)
        let locator = timeline.textLocatorJSONString(
            clipIndex: clipIdx,
            audioTime: audioTime,
            totalProgression: totalProgression
        )
        return ReaderArtifactLocation(
            position: totalProgression,
            locator: locator,
            chapterTitle: chapterTitle
        )
    }

    private struct OverlayFragmentSplit: Decodable {
        let visibleRatio: Double
        let offScreenRatio: Double
    }
}
