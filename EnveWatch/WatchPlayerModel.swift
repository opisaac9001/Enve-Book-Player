import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class WatchPlayerModel {
    static let shared = WatchPlayerModel()

    private(set) var descriptor: WatchPlaybackDescriptor?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var position: TimeInterval = 0
    private(set) var sleepRemaining: TimeInterval = 0
    private(set) var sleepUntilChapterEnd = false
    var playbackError: String?

    var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: "watchPlaybackSpeed")
            engine.setRate(Float(speed))
            updateNowPlayingInfo()
        }
    }

    private let engine = WatchAudioPlayer()
    private var sleepTimer: Timer?
    private var lastReportedAt = Date.distantPast
    private var lastReportedPosition: TimeInterval = 0
    private var remoteCommandsConfigured = false

    private init() {
        let stored = UserDefaults.standard.double(forKey: "watchPlaybackSpeed")
        speed = stored > 0 ? stored : 1.0

        engine.onTimeUpdate = { [weak self] time in self?.timeAdvanced(to: time) }
        engine.onPlayStateChange = { [weak self] playing in
            self?.isPlaying = playing
            self?.updateNowPlayingInfo()
            if !playing { self?.reportProgress(force: true) }
        }
        engine.onBookFinished = { [weak self] in self?.bookFinished() }
        engine.onError = { [weak self] message in
            self?.playbackError = message
            self?.reportProgress(force: true)
        }
    }

    var duration: TimeInterval { descriptor?.duration ?? 0 }

    var currentChapter: WatchChapterPayload? {
        descriptor?.chapters.last { position >= $0.start && position < $0.end }
    }

    var chapters: [WatchChapterPayload] { descriptor?.chapters ?? [] }

    func isCurrent(_ stableId: String) -> Bool {
        descriptor?.stableId == stableId
    }

    func play(stableId: String) async {
        guard !isLoading else { return }
        if isCurrent(stableId) {
            togglePlay()
            return
        }

        isLoading = true
        playbackError = nil
        defer { isLoading = false }

        stopCurrent()

        do {
            let local = WatchLocalStore.shared.book(stableId: stableId)
            let resolved: (WatchPlaybackDescriptor, [WatchResolvedTrack])
            let playingLocal = local?.isComplete == true
            if let local, playingLocal {
                resolved = (local.descriptor, localTracks(for: local))
            } else {
                let fresh = try await PhoneLink.shared.request(
                    .requestDescriptor,
                    WatchDescriptorRequest(stableId: stableId),
                    as: WatchPlaybackDescriptor.self
                )
                let remote = fresh.tracks.compactMap { track -> WatchResolvedTrack? in
                    guard let url = URL(string: track.url) else { return nil }
                    return WatchResolvedTrack(
                        index: track.index,
                        url: url,
                        headers: fresh.headers,
                        startOffset: track.startOffset,
                        duration: track.duration
                    )
                }
                resolved = (fresh, remote)
            }

            guard !resolved.1.isEmpty else {
                playbackError = "No playable audio tracks."
                return
            }

            try await activateAudioSession()

            let start = playingLocal ? (local?.savedPosition ?? 0) : resolved.0.startTime

            let startPosition = min(start, max(resolved.0.duration - 1, 0))
            try await engine.load(tracks: resolved.1, startAt: startPosition, rate: Float(speed))
            descriptor = resolved.0
            position = startPosition
            configureRemoteCommands()

            if PhoneLink.shared.nowPlayingIsLive {
                PhoneLink.shared.sendCommand(WatchCommandPayload(action: .pause))
            }
            engine.play()
            updateNowPlayingInfo()
            Task { _ = await WatchCoverStore.shared.image(for: stableId) }
            if playingLocal {
                reconcileLocalPosition(stableId: stableId, localSavedAt: local?.savedAt ?? .distantPast)
            }
        } catch {
            descriptor = nil
            position = 0
            playbackError = error.localizedDescription
        }
    }

    private func reconcileLocalPosition(stableId: String, localSavedAt: Date) {
        guard PhoneLink.shared.isReachable else { return }
        Task {
            guard
                let reply = try? await PhoneLink.shared.request(
                    .requestPosition,
                    WatchDescriptorRequest(stableId: stableId),
                    as: WatchPositionReply.self
                )
            else { return }
            guard isCurrent(stableId),
                reply.updatedAt > localSavedAt.addingTimeInterval(2),
                abs(reply.position - position) > 30
            else { return }
            seek(to: reply.position)
        }
    }

    private func localTracks(for book: WatchLocalBook) -> [WatchResolvedTrack] {
        book.descriptor.tracks.compactMap { track in
            guard let fileName = book.completedTracks[track.index] else { return nil }
            let url = WatchLocalStore.shared.trackFileURL(stableId: book.descriptor.stableId, fileName: fileName)
            return WatchResolvedTrack(
                index: track.index,
                url: url,
                headers: [:],
                startOffset: track.startOffset,
                duration: track.duration
            )
        }
    }

    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])

        try await session.activate()
    }

    func togglePlay() {
        if isPlaying {
            engine.pause()
        } else {
            Task {
                do {
                    try await activateAudioSession()
                    engine.play()
                } catch {
                    playbackError = error.localizedDescription
                }
            }
        }
    }

    func skipForward() {
        engine.seek(to: position + 30)
        reportProgress(force: true)
    }

    func skipBackward() {
        engine.seek(to: max(position - 15, 0))
        reportProgress(force: true)
    }

    func seek(to time: TimeInterval) {
        engine.seek(to: time)
        reportProgress(force: true)
    }

    func seekToChapter(_ chapter: WatchChapterPayload) {
        engine.seek(to: chapter.start + 0.05)
        reportProgress(force: true)
    }

    func stopCurrent() {
        guard descriptor != nil else { return }
        reportProgress(force: true)
        engine.stop()
        cancelSleepTimer()
        descriptor = nil
        position = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepRemaining = TimeInterval(minutes * 60)
        sleepUntilChapterEnd = false
        scheduleSleepTick()
    }

    func startSleepTimerToChapterEnd() {
        cancelSleepTimer()
        sleepUntilChapterEnd = true

        let target = currentChapter?.end ?? duration
        sleepRemaining = max(target - position, 0)
        scheduleSleepTick()
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepRemaining = 0
        sleepUntilChapterEnd = false
    }

    private func scheduleSleepTick() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in WatchPlayerModel.shared.sleepTick() }
        }
    }

    private func sleepTick() {
        if sleepUntilChapterEnd {
            sleepRemaining = max((currentChapter?.end ?? duration) - position, 0)
        } else {
            sleepRemaining = max(sleepRemaining - 1, 0)
        }
        guard sleepRemaining <= 0 else { return }
        cancelSleepTimer()
        if isPlaying {
            engine.pause()
        }
    }

    private func timeAdvanced(to time: TimeInterval) {
        position = time
        if sleepUntilChapterEnd {
            sleepRemaining = max((currentChapter?.end ?? duration) - time, 0)
        }
        reportProgress(force: false)
        updateNowPlayingElapsed()
    }

    private func reportProgress(force: Bool) {
        guard let descriptor else { return }
        let now = Date()
        let moved = abs(position - lastReportedPosition) > 1
        guard moved, force || now.timeIntervalSince(lastReportedAt) > 30 else { return }
        lastReportedAt = now
        lastReportedPosition = position

        WatchLocalStore.shared.savePosition(stableId: descriptor.stableId, position: position)
        PhoneLink.shared.reportProgress(
            WatchProgressReport(
                stableId: descriptor.stableId,
                position: position,
                duration: descriptor.duration,
                isFinished: false,
                timestamp: now
            )
        )
    }

    private func bookFinished() {
        guard let descriptor else { return }
        PhoneLink.shared.reportProgress(
            WatchProgressReport(
                stableId: descriptor.stableId,
                position: descriptor.duration,
                duration: descriptor.duration,
                isFinished: true,
                timestamp: Date()
            )
        )
        WatchLocalStore.shared.savePosition(stableId: descriptor.stableId, position: descriptor.duration)
        updateNowPlayingInfo()
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                let model = WatchPlayerModel.shared
                if !model.isPlaying { model.togglePlay() }
            }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                let model = WatchPlayerModel.shared
                if model.isPlaying { model.togglePlay() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable _ in
            Task { @MainActor in WatchPlayerModel.shared.togglePlay() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { @Sendable _ in
            Task { @MainActor in WatchPlayerModel.shared.skipForward() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { @Sendable _ in
            Task { @MainActor in WatchPlayerModel.shared.skipBackward() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in WatchPlayerModel.shared.seek(to: target) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let descriptor else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? descriptor.title,
            MPMediaItemPropertyArtist: descriptor.title,
            MPMediaItemPropertyAlbumTitle: descriptor.author,
            MPMediaItemPropertyPlaybackDuration: descriptor.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
        ]
        if let image = WatchCoverStore.shared.cachedImage(for: descriptor.stableId) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private var lastNowPlayingElapsedPush = Date.distantPast

    private func updateNowPlayingElapsed() {
        guard Date().timeIntervalSince(lastNowPlayingElapsedPush) > 5 else { return }
        lastNowPlayingElapsedPush = Date()
        updateNowPlayingInfo()
    }
}
