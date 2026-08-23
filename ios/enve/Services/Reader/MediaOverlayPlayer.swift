import AVFoundation
import Combine
import Logging
import MediaPlayer
import QuartzCore
import UIKit

@MainActor
final class MediaOverlayPlayer: NSObject, ObservableObject {

    @Published var currentFragmentId: String?
    @Published private(set) var currentFragmentIdentity: String?
    @Published var isPlaying: Bool = false
    @Published var playbackRate: Double = 1.0
    @Published var skipSkippables: Bool = true

    var currentClipIndex: Int { currentClipIdx }
    var currentTime: TimeInterval { globalElapsed() }
    var totalDuration: TimeInterval { totalAudioDuration }
    var currentClipElapsedTime: TimeInterval? {
        guard clips.indices.contains(currentClipIdx),
            let timeline,
            timeline.clipTimings.indices.contains(currentClipIdx)
        else { return nil }
        let timing = timeline.clipTimings[currentClipIdx]
        return min(max(globalElapsed() - timing.audioStart, 0), max(0, clips[currentClipIdx].duration))
    }

    var syncOffset: TimeInterval = 0.0 {
        didSet { if oldValue != syncOffset { reinstallBoundaryObserver() } }
    }

    private var clips: [AudioOverlayClip] = []
    private var timeline: MediaOverlayTimeline?
    private var clipIndex: [String: Int] = [:]
    private var clipIndicesByFragment: [String: [Int]] = [:]
    private var audioDir: URL?
    private var currentClipIdx: Int = 0

    private var player: AVQueuePlayer?
    private var boundaryObserver: Any?
    private var periodicObserver: Any?
    private var displayTimer: Timer?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?

    private var audioFileGroups: [(audioSrc: String, startIdx: Int, endIdx: Int)] = []
    private var clipToGroupIdx: [Int] = []
    private var groupItems: [AVPlayerItem?] = []
    private var itemToGroup: [ObjectIdentifier: Int] = [:]
    private var groupDurations: [Double] = []
    private var groupCumulativeStarts: [Double] = []
    private var totalAudioDuration: Double = 0
    private var lastNowPlayingPushAt: TimeInterval = 0
    private var lastFragmentPublishAt: TimeInterval = 0
    private var frozenElapsed: TimeInterval?
    private var reachedEnd = false
    private var handledFailedItems: Set<ObjectIdentifier> = []

    var bookTitle: String?
    var bookAuthor: String?
    var bookCoverURL: URL?
    var bookContentIdentifier: String?

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    #if os(iOS)
    private var nowPlayingSession: MPNowPlayingSession?
    #endif

    private static let speedDefaultsKey = "readAloud.speed"
    private static let maxBoundaryObserverTimes = 160

    func load(clips: [AudioOverlayClip], timeline: MediaOverlayTimeline, audioDir: URL) {
        self.clips = clips
        self.timeline = timeline
        self.audioDir = audioDir
        self.clipIndicesByFragment = Dictionary(grouping: clips.enumerated(), by: { $0.element.fragmentId })
            .mapValues { $0.map(\.offset) }
        self.clipIndex = clipIndicesByFragment.compactMapValues(\.first)
        currentClipIdx = 0
        frozenElapsed = nil
        reachedEnd = false
        publishCurrentFragment(force: true)
        buildAudioFileGroups()
        buildQueue(startingAtGroup: 0)
    }

    func play(fromFragment fragmentId: String? = nil) {
        if let frag = fragmentId, let idx = bestClipIndex(for: frag, preferredHref: nil) {
            currentClipIdx = idx
        }
        loadPersistedSpeed()
        activateAudioSession()
        reactivateNowPlayingSessionIfNeeded()
        NowPlayingCoordinator.shared.setActive(self)
        beginBackgroundTask()
        startPlayback()
        updateNowPlayingInfo()
    }

    func pause() {
        resyncClipFromPlayhead(forcePublish: true)
        player?.pause()
        isPlaying = false
        endBackgroundTask()
        updateNowPlayingInfo()
    }

    func resume() {
        if player == nil {
            if reachedEnd {
                currentClipIdx = 0
                frozenElapsed = nil
                reachedEnd = false
            }
            guard clips.indices.contains(currentClipIdx) else { return }
            buildQueue(startingAtGroup: clipToGroupIdx[currentClipIdx])
            seekToCurrentClip()
        }
        guard player != nil else { return }
        activateAudioSession()
        reactivateNowPlayingSessionIfNeeded()
        NowPlayingCoordinator.shared.setActive(self)
        beginBackgroundTask()
        isPlaying = true
        applyRate()
        startDisplayObservers()
        updateNowPlayingInfo()
    }

    func syncToPlayhead() {
        resyncClipFromPlayhead(forcePublish: true)
        reinstallBoundaryObserver()
        updateNowPlayingInfo()
    }

    func refreshPositionFromPlayhead() {
        resyncClipFromPlayhead(forcePublish: true)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func seekToFragment(_ fragmentId: String) {
        seekToFragment(fragmentId, preferredHref: nil)
    }

    func seekToFragment(_ fragmentId: String, preferredHref: String?) {
        guard let idx = bestClipIndex(for: fragmentId, preferredHref: preferredHref) else { return }
        currentClipIdx = idx
        prepareForManualSelection()
        if isPlaying {
            startPlayback()
        } else {
            seekToCurrentClip()
            publishCurrentFragment(force: true)
        }
    }

    func next() {
        guard currentClipIdx + 1 < clips.count else {
            completePlayback()
            return
        }
        currentClipIdx += 1
        guard advancePastSkippables() else {
            completePlayback()
            return
        }
        if isPlaying { startPlayback() } else { seekToCurrentClip(); publishCurrentFragment(force: true) }
    }

    func previous() {
        guard currentClipIdx > 0 else { return }
        currentClipIdx -= 1
        prepareForManualSelection()
        if isPlaying { startPlayback() } else { seekToCurrentClip(); publishCurrentFragment(force: true) }
    }

    func setSpeed(_ rate: Double) {
        let clamped = min(max(rate, 0.5), 3.0)
        playbackRate = clamped
        applyRate()
        UserDefaults.standard.set(clamped, forKey: Self.speedDefaultsKey)
        updateNowPlayingInfo()
    }

    func loadPersistedSpeed() {
        let stored = UserDefaults.standard.double(forKey: Self.speedDefaultsKey)
        if stored > 0 { setSpeed(stored) }
    }

    func stop() {
        frozenElapsed = globalElapsed()
        teardownObservers()
        player?.pause()
        player = nil
        isPlaying = false
        endBackgroundTask()
        NowPlayingCoordinator.shared.resignIfActive(self)
        updateNowPlayingInfo()
    }

    func cleanup() {
        stop()
        NowPlayingCoordinator.shared.clearNowPlaying(if: self)
        clearNowPlayingSession()
        deactivateAudioSession()
        if let dir = audioDir {
            try? FileManager.default.removeItem(at: dir)
        }
        clips = []
        timeline = nil
        clipIndex = [:]
        clipIndicesByFragment = [:]
        audioDir = nil
        currentFragmentId = nil
        currentFragmentIdentity = nil
        audioFileGroups = []
        clipToGroupIdx = []
        groupItems = []
        itemToGroup = [:]
        groupDurations = []
        groupCumulativeStarts = []
        totalAudioDuration = 0
        lastNowPlayingPushAt = 0
        lastFragmentPublishAt = 0
        frozenElapsed = nil
        reachedEnd = false
        handledFailedItems = []
    }

    @discardableResult
    private func advancePastSkippables() -> Bool {
        guard skipSkippables else { return clips.indices.contains(currentClipIdx) }
        while currentClipIdx < clips.count,
            let role = clips[currentClipIdx].skippableRole, !role.isEmpty
        {
            currentClipIdx += 1
        }
        return clips.indices.contains(currentClipIdx)
    }

    private func bestClipIndex(for fragmentId: String, preferredHref: String?) -> Int? {
        guard let candidates = clipIndicesByFragment[fragmentId], !candidates.isEmpty else {
            return clipIndex[fragmentId]
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        if let preferredHref, !preferredHref.isEmpty,
            let hrefMatch = candidates.first(where: { overlayHrefMatches(clips[$0].textHref, preferredHref) })
        {
            return hrefMatch
        }
        return candidates.min(by: { abs($0 - currentClipIdx) < abs($1 - currentClipIdx) }) ?? candidates[0]
    }

    private func overlayHrefMatches(_ smilHref: String, _ readiumHref: String) -> Bool {
        if smilHref == readiumHref { return true }

        let a = smilHref.hasPrefix("/") ? String(smilHref.dropFirst()) : smilHref
        let b = readiumHref.hasPrefix("/") ? String(readiumHref.dropFirst()) : readiumHref
        if a == b { return true }
        if a.hasSuffix(b) || b.hasSuffix(a) { return true }

        let fileA = (a as NSString).lastPathComponent
        let fileB = (b as NSString).lastPathComponent
        return fileA == fileB && !fileA.isEmpty
    }

    private func buildAudioFileGroups() {
        audioFileGroups = []
        clipToGroupIdx = Array(repeating: 0, count: clips.count)
        groupDurations = []
        groupCumulativeStarts = []
        totalAudioDuration = 0
        guard !clips.isEmpty else { return }

        var groupStart = 0
        var currentSrc = clips[0].audioSrc

        for i in 1..<clips.count {
            if clips[i].audioSrc != currentSrc {
                let groupIdx = audioFileGroups.count
                audioFileGroups.append((audioSrc: currentSrc, startIdx: groupStart, endIdx: i - 1))
                for j in groupStart...(i - 1) { clipToGroupIdx[j] = groupIdx }
                groupStart = i
                currentSrc = clips[i].audioSrc
            }
        }
        let groupIdx = audioFileGroups.count
        audioFileGroups.append((audioSrc: currentSrc, startIdx: groupStart, endIdx: clips.count - 1))
        for j in groupStart...(clips.count - 1) { clipToGroupIdx[j] = groupIdx }

        for group in audioFileGroups {
            groupCumulativeStarts.append(timeline?.audioStart(forAudioSource: group.audioSrc) ?? 0)
            groupDurations.append(timeline?.duration(forAudioSource: group.audioSrc) ?? 0)
        }
        totalAudioDuration = timeline?.totalAudioDuration ?? 0
    }

    private func buildQueue(startingAtGroup startingGroup: Int) {
        teardownObservers()
        guard let audioDir, !audioFileGroups.isEmpty else {
            player = nil
            return
        }

        groupItems = Array(repeating: nil, count: audioFileGroups.count)
        itemToGroup = [:]
        var items: [AVPlayerItem] = []

        for groupIdx in startingGroup..<audioFileGroups.count {
            let group = audioFileGroups[groupIdx]
            let fileURL = EPUB3SMILParser.localAudioURL(for: group.audioSrc, in: audioDir)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                AppLogger.library.error(
                    "Audio file missing pathId=\(DiagnosticLogSanitizer.identifier(for: fileURL.standardizedFileURL.path)) sourceId=\(DiagnosticLogSanitizer.identifier(for: group.audioSrc))"
                )
                continue
            }
            let item = AVPlayerItem(asset: AVURLAsset(url: fileURL))
            item.audioTimePitchAlgorithm = .timeDomain
            groupItems[groupIdx] = item
            itemToGroup[ObjectIdentifier(item)] = groupIdx
            items.append(item)
        }

        guard !items.isEmpty else {
            player = nil
            return
        }

        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        queue.automaticallyWaitsToMinimizeStalling = false
        player = queue
        observeCurrentItem()
        observeItemStatus()
        activateNowPlayingSession(for: queue)
    }

    private func activateNowPlayingSession(for player: AVPlayer) {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            if nowPlayingSession?.players.contains(where: { $0 === player }) != true {
                let session = MPNowPlayingSession(players: [player])
                session.automaticallyPublishesNowPlayingInfo = false
                nowPlayingSession = session
                NowPlayingCoordinator.shared.setNowPlayingSession(session)
            }
            nowPlayingSession?.becomeActiveIfPossible { _ in }
        }
        #endif
    }

    private func reactivateNowPlayingSessionIfNeeded() {
        guard let player else { return }
        activateNowPlayingSession(for: player)
    }

    private func clearNowPlayingSession() {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            nowPlayingSession = nil
            NowPlayingCoordinator.shared.setNowPlayingSession(nil)
        }
        #endif
    }

    private func startPlayback() {
        guard currentClipIdx < clips.count, audioDir != nil else {
            stop()
            return
        }
        let targetGroup = clipToGroupIdx[currentClipIdx]

        if currentGroupIndex() != targetGroup || player == nil {
            buildQueue(startingAtGroup: targetGroup)
        }
        guard player != nil else {
            advanceToNextGroup()
            return
        }
        frozenElapsed = nil
        reachedEnd = false

        publishCurrentFragment(force: true)
        seekToCurrentClip()
        isPlaying = true
        applyRate()
        startDisplayObservers()
    }

    private func seekToCurrentClip() {
        guard let player, currentClipIdx < clips.count else { return }
        let clip = clips[currentClipIdx]
        let time = CMTime(seconds: clip.clipBegin, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func currentGroupIndex() -> Int? {
        guard let item = player?.currentItem else { return nil }
        return itemToGroup[ObjectIdentifier(item)]
    }

    private func applyRate() {
        guard let player else { return }
        player.rate = isPlaying ? Float(playbackRate) : 0
    }

    private func advanceToNextGroup() {
        guard currentClipIdx < clips.count else { stop(); return }
        let groupIdx = clipToGroupIdx[currentClipIdx]
        guard groupIdx + 1 < audioFileGroups.count else { stop(); return }
        currentClipIdx = audioFileGroups[groupIdx + 1].startIdx
        guard advancePastSkippables() else {
            completePlayback()
            return
        }
        startPlayback()
    }

    private func startDisplayObservers() {
        startDisplayTimer()
        startPeriodicObserver()
        reinstallBoundaryObserver()
    }

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.resyncClipFromPlayhead()
                if CACurrentMediaTime() - self.lastNowPlayingPushAt >= 1.0 {
                    self.updateNowPlayingInfo()
                }
            }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reinstallBoundaryObserver() {
        guard let player else { return }
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        guard let groupIdx = currentGroupIndex() else { return }
        let group = audioFileGroups[groupIdx]
        let firstBoundaryIndex: Int
        if currentClipIdx >= group.startIdx, currentClipIdx <= group.endIdx {
            firstBoundaryIndex = currentClipIdx + 1
        } else {
            firstBoundaryIndex = group.startIdx
        }
        guard firstBoundaryIndex <= group.endIdx else { return }

        var times: [NSValue] = []
        for idx in firstBoundaryIndex...group.endIdx {
            let boundary = max(0, clips[idx - 1].clipEnd - syncOffset)
            times.append(NSValue(time: CMTime(seconds: boundary, preferredTimescale: 600)))
        }
        guard !times.isEmpty else { return }
        guard times.count <= Self.maxBoundaryObserverTimes else {
            AppLogger.library.info("MediaOverlayPlayer: Skipping \(times.count) boundary observers for dense Read Aloud group")
            return
        }

        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: times,
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.boundaryCrossed() }
        }
    }

    private func boundaryCrossed() {
        guard isPlaying else { return }
        resyncClipFromPlayhead(forcePublish: true)
    }

    private func publishCurrentFragment(force: Bool = false) {
        guard currentClipIdx >= 0, currentClipIdx < clips.count else { return }
        let clip = clips[currentClipIdx]
        let fragmentId = clip.fragmentId
        let identity = "\(clip.textHref)#\(fragmentId)#\(currentClipIdx)"
        guard force || identity != currentFragmentIdentity else { return }
        currentFragmentId = fragmentId
        currentFragmentIdentity = identity
        lastFragmentPublishAt = CACurrentMediaTime()
    }

    private func startPeriodicObserver() {
        guard let player, periodicObserver == nil else { return }
        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resyncClipFromPlayhead()
                if CACurrentMediaTime() - self.lastNowPlayingPushAt >= 1.0 {
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    private func resyncClipFromPlayhead(forcePublish: Bool = false) {
        guard let timeline,
            let idx = timeline.clipIndex(atAudioTime: globalElapsed() + syncOffset)
        else { return }
        if idx != currentClipIdx {
            currentClipIdx = idx
            guard advancePastSkippables() else {
                completePlayback()
                return
            }
            if currentClipIdx != idx {
                if isPlaying { startPlayback() } else { seekToCurrentClip() }
            }
            publishCurrentFragment(force: forcePublish)
        } else if forcePublish {
            publishCurrentFragment(force: true)
        }
    }

    private func observeCurrentItem() {
        currentItemObservation = player?.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.currentItemChanged() }
        }
    }

    private func currentItemChanged() {
        guard currentGroupIndex() != nil else {
            if isPlaying { completePlayback() }
            return
        }
        resyncClipFromPlayhead(forcePublish: true)
        applyRate()
        reinstallBoundaryObserver()
        updateNowPlayingInfo()
    }

    private func observeItemStatus() {
        itemStatusObservation = player?.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed, let item = player.currentItem else { return }
            let itemIdentifier = ObjectIdentifier(item)
            let errorDescription = player.currentItem?.error?.localizedDescription ?? "unknown"
            Task { @MainActor [weak self] in
                AppLogger.library.error("Media overlay item failed: \(errorDescription)")
                self?.handleFailedItem(itemIdentifier)
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let object = notification.object as AnyObject? else { return }
            let itemIdentifier = ObjectIdentifier(object)
            Task { @MainActor [weak self] in
                self?.handleFailedItem(itemIdentifier)
            }
        }
    }

    private func handleFailedItem(_ identifier: ObjectIdentifier) {
        guard handledFailedItems.insert(identifier).inserted,
            let failedGroup = itemToGroup[identifier],
            failedGroup == currentGroupIndex()
        else { return }
        advanceToNextGroup()
    }

    private func teardownObservers() {
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        boundaryObserver = nil
        periodicObserver = nil
        displayTimer?.invalidate()
        displayTimer = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        failedToEndObserver = nil
    }

    private func activateAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            AppLogger.library.error("MediaOverlayPlayer: Failed to activate audio session: \(error)")
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        guard !ActivePlayback.controller.snapshot.isLoaded else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            AppLogger.library.error("MediaOverlayPlayer: Failed to deactivate audio session: \(error)")
        }
        #endif
    }

    private func beginBackgroundTask() {
        #if os(iOS)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
    }

    private func endBackgroundTask() {
        #if os(iOS)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }

    private func globalElapsed() -> Double {
        if player == nil, let frozenElapsed { return frozenElapsed }
        guard let groupIdx = currentGroupIndex(),
            groupIdx < groupCumulativeStarts.count
        else {
            if currentClipIdx < clips.count, !groupCumulativeStarts.isEmpty {
                let g = clipToGroupIdx[currentClipIdx]
                let base = g < groupCumulativeStarts.count ? groupCumulativeStarts[g] : 0
                return base + clips[currentClipIdx].clipBegin
            }
            return 0
        }
        let base = groupCumulativeStarts[groupIdx]
        let t = player?.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        let withinFile = (t.isFinite && t > 0) ? t : 0
        return base + withinFile
    }

    private func completePlayback() {
        frozenElapsed = totalAudioDuration
        reachedEnd = true
        currentClipIdx = max(clips.count - 1, 0)
        publishCurrentFragment(force: true)
        teardownObservers()
        player?.pause()
        player = nil
        isPlaying = false
        endBackgroundTask()
        NowPlayingCoordinator.shared.resignIfActive(self)
        updateNowPlayingInfo()
    }

    private func prepareForManualSelection() {
        guard reachedEnd || player == nil else { return }
        reachedEnd = false
        frozenElapsed = nil
        guard clips.indices.contains(currentClipIdx) else { return }
        buildQueue(startingAtGroup: clipToGroupIdx[currentClipIdx])
        seekToCurrentClip()
    }

    private func seekToGlobalTime(_ seconds: Double) {
        guard !audioFileGroups.isEmpty else { return }
        let clamped = max(0, min(seconds, totalAudioDuration))
        var targetGroup = 0
        for i in 0..<groupCumulativeStarts.count {
            let end = groupCumulativeStarts[i] + groupDurations[i]
            if clamped < end { targetGroup = i; break }
            targetGroup = i
        }
        let within = clamped - groupCumulativeStarts[targetGroup]
        let group = audioFileGroups[targetGroup]
        var newIdx = group.startIdx
        for idx in group.startIdx...group.endIdx where within >= clips[idx].clipBegin {
            newIdx = idx
        }
        currentClipIdx = newIdx

        if currentGroupIndex() != targetGroup || player == nil {
            buildQueue(startingAtGroup: targetGroup)
        }
        guard let player else { return }
        let time = CMTime(seconds: within, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        publishCurrentFragment(force: true)
        if isPlaying {
            applyRate()
            startDisplayObservers()
        }
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        let duration = totalAudioDuration > 0 ? totalAudioDuration : nil
        let elapsed = globalElapsed()
        NowPlayingCoordinator.shared.updateNowPlaying(
            NowPlayingInfo(
                title: bookTitle ?? "Read Aloud",
                artist: bookAuthor,
                albumTitle: bookAuthor,
                duration: duration,
                elapsed: elapsed,
                rate: isPlaying ? playbackRate : 0,
                defaultRate: 1.0,
                mediaType: .audio,
                contentIdentifier: bookContentIdentifier,
                serviceIdentifier: Bundle.main.bundleIdentifier ?? "com.enve.enve",
                playbackQueueIndex: 0,
                playbackQueueCount: 1,
                artworkURL: bookCoverURL
            )
        )
        lastNowPlayingPushAt = CACurrentMediaTime()
    }
}

extension MediaOverlayPlayer: RemoteCommandTarget {
    func remotePlay() { resume() }
    func remotePause() { pause() }
    func remoteToggle() { togglePlayPause() }
    func remoteNext() { next() }
    func remotePrevious() { previous() }
    func remoteSkipForward(by seconds: TimeInterval?) {
        seekToGlobalTime(globalElapsed() + (seconds ?? remoteSkipForwardInterval))
    }
    func remoteSkipBackward(by seconds: TimeInterval?) {
        seekToGlobalTime(globalElapsed() - (seconds ?? remoteSkipBackwardInterval))
    }
    func remoteSeek(to positionTime: TimeInterval) {
        seekToGlobalTime(positionTime)
    }
}
