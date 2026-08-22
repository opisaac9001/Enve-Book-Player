import Combine
import Foundation

enum ReaderPageTurnTiming {
    nonisolated static func delay(
        clipDuration: TimeInterval,
        elapsedClipTime: TimeInterval,
        visibleRatio: Double,
        playbackRate: Double,
        lead: TimeInterval
    ) -> TimeInterval {
        let mediaTimeUntilSplit = max(
            0,
            clipDuration * min(max(visibleRatio, 0), 1) - max(elapsedClipTime, 0)
        )
        return max(0, mediaTimeUntilSplit / min(max(playbackRate, 0.5), 3.0) - max(lead, 0))
    }
}

@MainActor
final class ReadAloudPlaybackCoordinator {
    var onChange: (() -> Void)?
    var onPlayerStateChange: (() -> Void)?
    var onPlaybackChange: ((Bool) -> Void)?
    var onFragmentChange: ((String) -> Void)?

    var overlayPlayer: MediaOverlayPlayer? {
        willSet { notifyIfNeeded(overlayPlayer !== newValue) }
    }
    var isReadAloudMode = false {
        willSet { notifyIfNeeded(isReadAloudMode != newValue) }
    }
    var autoStartReadAloud = false
    var detectedEPUB3Features: EPUB3Features? {
        willSet { notifyIfNeeded(detectedEPUB3Features != newValue) }
    }
    var overlayClips: [AudioOverlayClip] = []
    var overlayTimeline: MediaOverlayTimeline?
    var overlayChapterDurations: [String: TimeInterval] = [:]
    var orderedOverlayChapterHrefs: [String] = []
    var overlayRemainingChapterSecondsByClipIndex: [TimeInterval] = []
    var overlayRemainingBookSecondsByClipIndex: [TimeInterval] = []
    var overlayCumulativeStartSecondsByClipIndex: [TimeInterval] = []
    var overlayChapterStartSecondsByHref: [String: TimeInterval] = [:]
    var overlayChapterEndSecondsByHref: [String: TimeInterval] = [:]
    var overlayFragmentCancellable: AnyCancellable?
    var overlayFragmentUpdateTask: Task<Void, Never>?
    var overlayPlayerStateCancellable: AnyCancellable?
    var overlayPlaybackCancellable: AnyCancellable?
    var positionSyncTimer: Timer?
    var lastSyncedFragmentId: String?
    var lastSyncedClipIndex = -1
    var lastSyncedAudioTime: TimeInterval = -1
    var pendingInitialFragmentId: String?
    var pendingInitialHref: String?
    var pendingInitialSetAt: TimeInterval = 0
    var userDidPageTurn = false
    var userPageTurnResetTask: Task<Void, Never>?
    var audioIsNavigating = false
    var pendingPreflipTask: Task<Void, Never>?
    var lastPagePreflipAt: TimeInterval = 0
    var manualNavigationGeneration: Int = 0
    var lastManualNavigationDocumentHref: String?
    private(set) var overlayClipFragmentSet: Set<String> = []
    private(set) var overlayClipIndexMap: [String: Int] = [:]
    private var overlayClipIndicesMap: [String: [Int]] = [:]
    private var overlayClipIndicesByParentGroup: [String: [Int]] = [:]
    private var lastPageFollowCheckAt: TimeInterval = 0
    private var lastOverlayDecorationAppliedAt: TimeInterval = 0
    private var lastOverlayDecorationKey: String?

    func load(
        clips: [AudioOverlayClip],
        timeline: MediaOverlayTimeline,
        chapterDurations: [String: TimeInterval],
        audioDir: URL,
        syncOffset: TimeInterval,
        book: Book
    ) {
        configureMapping(clips: clips, timeline: timeline, chapterDurations: chapterDurations)

        let player = MediaOverlayPlayer()
        player.load(clips: clips, timeline: timeline, audioDir: audioDir)
        player.syncOffset = syncOffset
        player.bookTitle = book.title
        player.bookAuthor = book.author
        player.bookCoverURL = book.coverURL
        player.bookContentIdentifier = book.stableId
        overlayPlayer = player
        bindPlayer(player)
    }

    func publishMapping(
        clips: [AudioOverlayClip],
        timeline: MediaOverlayTimeline,
        chapterDurations: [String: TimeInterval] = [:]
    ) {
        configureMapping(clips: clips, timeline: timeline, chapterDurations: chapterDurations)
    }

    private func configureMapping(
        clips: [AudioOverlayClip],
        timeline: MediaOverlayTimeline,
        chapterDurations: [String: TimeInterval]
    ) {
        onChange?()
        overlayClips = clips
        overlayTimeline = timeline
        overlayChapterDurations = chapterDurations
        lastOverlayDecorationAppliedAt = 0
        lastOverlayDecorationKey = nil
        var seenHrefs = Set<String>()
        orderedOverlayChapterHrefs = clips.compactMap { clip in
            seenHrefs.insert(clip.textHref).inserted ? clip.textHref : nil
        }
        overlayRemainingChapterSecondsByClipIndex = Array(repeating: 0, count: clips.count)
        overlayRemainingBookSecondsByClipIndex = Array(repeating: 0, count: clips.count)
        overlayCumulativeStartSecondsByClipIndex = Array(repeating: 0, count: clips.count)
        overlayChapterStartSecondsByHref = [:]
        overlayChapterEndSecondsByHref = [:]
        var runningBookSeconds: TimeInterval = 0
        for index in clips.indices.reversed() {
            let clip = clips[index]
            runningBookSeconds += clip.duration
            overlayRemainingBookSecondsByClipIndex[index] = runningBookSeconds
            let timing = timeline.clipTimings[index]
            let cumulativeStart = timing.audioStart
            overlayCumulativeStartSecondsByClipIndex[index] = cumulativeStart
            overlayChapterStartSecondsByHref[clip.textHref] = min(
                overlayChapterStartSecondsByHref[clip.textHref] ?? cumulativeStart,
                cumulativeStart
            )
            overlayChapterEndSecondsByHref[clip.textHref] = max(
                overlayChapterEndSecondsByHref[clip.textHref] ?? cumulativeStart,
                timing.audioEnd
            )
            if index < clips.index(before: clips.endIndex),
                clips[clips.index(after: index)].textHref == clip.textHref
            {
                overlayRemainingChapterSecondsByClipIndex[index] =
                    clip.duration + overlayRemainingChapterSecondsByClipIndex[clips.index(after: index)]
            } else {
                overlayRemainingChapterSecondsByClipIndex[index] = clip.duration
            }
        }
        overlayClipFragmentSet = Set(clips.map(\.fragmentId))
        overlayClipIndexMap = Dictionary(clips.enumerated().map { ($1.fragmentId, $0) }, uniquingKeysWith: { first, _ in first })
        overlayClipIndicesMap = Dictionary(grouping: clips.enumerated(), by: { $0.element.fragmentId })
            .mapValues { $0.map(\.offset) }
        overlayClipIndicesByParentGroup = Dictionary(
            grouping: clips.enumerated().compactMap { index, clip -> (key: String, index: Int)? in
                guard let groupIndex = clip.parentGroupIndex else { return nil }
                return ("\(groupIndex)|\(clip.textHref)", index)
            },
            by: \.key
        )
        .mapValues { $0.map(\.index) }
    }

    func bestClipIndex(for fragmentId: String, preferredHref: String?) -> Int? {
        guard let candidates = overlayClipIndicesMap[fragmentId], !candidates.isEmpty else {
            return overlayClipIndexMap[fragmentId]
        }
        if candidates.count == 1 {
            return candidates[0]
        }

        if let preferredHref, !preferredHref.isEmpty,
            let hrefMatch = candidates.first(where: { idx in
                ReadAloudOverlayTransform.hrefMatches(overlayClips[idx].textHref, preferredHref)
            })
        {
            return hrefMatch
        }

        if let currentIdx = overlayPlayer?.currentClipIndex {
            return candidates.min(by: { abs($0 - currentIdx) < abs($1 - currentIdx) })
        }

        return candidates[0]
    }

    func playingClipIndex(matching fragmentId: String? = nil) -> Int? {
        guard let player = overlayPlayer else { return nil }
        let idx = player.currentClipIndex
        guard overlayClips.indices.contains(idx) else { return nil }
        if let fragmentId, overlayClips[idx].fragmentId != fragmentId {
            return nil
        }
        return idx
    }

    func siblingClips(groupIndex: Int, textHref: String) -> [AudioOverlayClip] {
        let key = "\(groupIndex)|\(textHref)"
        return overlayClipIndicesByParentGroup[key]?.compactMap { index in
            overlayClips.indices.contains(index) ? overlayClips[index] : nil
        } ?? []
    }

    func shouldRunPageFollowWork(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard now - lastPageFollowCheckAt >= 0.35 else { return false }
        lastPageFollowCheckAt = now
        return true
    }

    func shouldApplyOverlayDecoration(key: String, now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        if key == lastOverlayDecorationKey { return false }
        if now - lastOverlayDecorationAppliedAt < 0.5 { return false }
        lastOverlayDecorationKey = key
        lastOverlayDecorationAppliedAt = now
        return true
    }

    func startPositionSyncTimer(_ tick: @escaping @MainActor () -> Void) {
        positionSyncTimer?.invalidate()
        positionSyncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                tick()
            }
        }
    }

    func stopPositionSyncTimer() {
        positionSyncTimer?.invalidate()
        positionSyncTimer = nil
    }

    private func bindPlayer(_ player: MediaOverlayPlayer) {
        overlayPlayerStateCancellable = player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onPlayerStateChange?()
            }

        overlayPlaybackCancellable = player.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.onPlaybackChange?(isPlaying)
            }

        overlayFragmentCancellable = player.$currentFragmentIdentity
            .removeDuplicates()
            .sink { [weak self, weak player] identity in
                guard identity != nil, let fragmentId = player?.currentFragmentId else { return }
                self?.onFragmentChange?(fragmentId)
            }
    }

    func resetAfterCleanup() {
        overlayPlayer = nil
        overlayFragmentCancellable?.cancel()
        overlayFragmentCancellable = nil
        overlayFragmentUpdateTask?.cancel()
        overlayFragmentUpdateTask = nil
        overlayPlayerStateCancellable?.cancel()
        overlayPlayerStateCancellable = nil
        overlayPlaybackCancellable?.cancel()
        overlayPlaybackCancellable = nil
        overlayClips = []
        overlayTimeline = nil
        overlayChapterDurations = [:]
        orderedOverlayChapterHrefs = []
        overlayRemainingChapterSecondsByClipIndex = []
        overlayRemainingBookSecondsByClipIndex = []
        overlayCumulativeStartSecondsByClipIndex = []
        overlayChapterStartSecondsByHref = [:]
        overlayChapterEndSecondsByHref = [:]
        overlayClipFragmentSet = []
        overlayClipIndexMap = [:]
        overlayClipIndicesMap = [:]
        overlayClipIndicesByParentGroup = [:]
        lastPageFollowCheckAt = 0
        lastOverlayDecorationAppliedAt = 0
        lastOverlayDecorationKey = nil
        isReadAloudMode = false
        lastSyncedFragmentId = nil
        lastSyncedClipIndex = -1
        lastSyncedAudioTime = -1
        pendingInitialFragmentId = nil
        pendingInitialHref = nil
        pendingInitialSetAt = 0
        userDidPageTurn = false
        audioIsNavigating = false
        pendingPreflipTask?.cancel()
        pendingPreflipTask = nil
        lastPagePreflipAt = 0
        manualNavigationGeneration = 0
        lastManualNavigationDocumentHref = nil
        userPageTurnResetTask?.cancel()
        userPageTurnResetTask = nil
        positionSyncTimer?.invalidate()
        positionSyncTimer = nil
        onFragmentChange = nil
    }

    private func notifyIfNeeded(_ shouldNotify: Bool) {
        if shouldNotify {
            onChange?()
        }
    }
}
