import AVFoundation
import Foundation

struct WatchResolvedTrack: Sendable {
    let index: Int
    let url: URL
    let headers: [String: String]
    let startOffset: TimeInterval
    let duration: TimeInterval
}

@MainActor
final class WatchAudioPlayer: NSObject {
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?
    var onBookFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isPlaying = false
    private(set) var currentTrackIndex = 0

    private var player = AVPlayer()
    private var tracks: [WatchResolvedTrack] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var rate: Float = 1.0
    private var totalDuration: TimeInterval = 0

    private var loadGeneration = 0

    var currentGlobalTime: TimeInterval {
        guard tracks.indices.contains(currentTrackIndex) else { return 0 }
        let local = player.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        return tracks[currentTrackIndex].startOffset + max(local, 0)
    }

    func load(tracks: [WatchResolvedTrack], startAt globalTime: TimeInterval, rate: Float) async throws {
        self.tracks = tracks.sorted { $0.startOffset < $1.startOffset }
        self.rate = rate
        totalDuration = self.tracks.reduce(0) { max($0, $1.startOffset + $1.duration) }
        installTimeObserver()

        let (index, localTime) = trackAndOffset(for: globalTime)
        try await loadTrack(at: index, seekTo: localTime)
    }

    func play() {
        player.defaultRate = rate
        player.playImmediately(atRate: rate)
        setPlaying(true)
    }

    func pause() {
        player.pause()
        setPlaying(false)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if isPlaying {
            player.rate = newRate
        }
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func seek(to globalTime: TimeInterval) {

        let clamped =
            totalDuration > 0
            ? min(max(globalTime, 0), max(totalDuration - 0.5, 0))
            : max(globalTime, 0)
        let (index, localTime) = trackAndOffset(for: clamped)
        if index == currentTrackIndex, player.currentItem != nil {
            player.seek(to: CMTime(seconds: localTime, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            onTimeUpdate?(clamped)
        } else {
            let wasPlaying = isPlaying
            Task {
                do {
                    try await loadTrack(at: index, seekTo: localTime)
                    if wasPlaying { play() }
                } catch is CancellationError {
                } catch {
                    if !(error is StaleLoadError) {
                        onError?(error.localizedDescription)
                    }
                }
            }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        setPlaying(false)
    }

    private func trackAndOffset(for globalTime: TimeInterval) -> (Int, TimeInterval) {
        for (index, track) in tracks.enumerated() {
            if globalTime < track.startOffset + track.duration || index == tracks.count - 1 {
                return (index, max(globalTime - track.startOffset, 0))
            }
        }
        return (0, globalTime)
    }

    private struct StaleLoadError: Error {}

    private func loadTrack(at index: Int, seekTo localTime: TimeInterval) async throws {
        guard tracks.indices.contains(index) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let track = tracks[index]

        let asset: AVURLAsset
        if track.url.isFileURL || track.headers.isEmpty {
            asset = AVURLAsset(url: track.url)
        } else {
            asset = AVURLAsset(url: track.url, options: ["AVURLAssetHTTPHeaderFieldsKey": track.headers])
        }

        let playable = try await asset.load(.isPlayable)
        guard generation == loadGeneration else { throw StaleLoadError() }
        guard playable else {
            throw NSError(domain: "WatchAudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio format not playable on watch"])
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        observeItem(item)
        player.replaceCurrentItem(with: item)
        currentTrackIndex = index
        if localTime > 0.1 {
            await player.seek(to: CMTime(seconds: localTime, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard generation == loadGeneration else { throw StaleLoadError() }
        }
        onTimeUpdate?(currentGlobalTime)
    }

    private func advanceToNextTrack() {
        let next = currentTrackIndex + 1
        guard tracks.indices.contains(next) else {
            setPlaying(false)
            onBookFinished?()
            return
        }
        Task {
            do {
                try await loadTrack(at: next, seekTo: 0)
                play()
            } catch is StaleLoadError {
            } catch {
                onError?(error.localizedDescription)
                setPlaying(false)
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceToNextTrack() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                self?.onError?(message ?? "Playback failed")
                self?.setPlaying(false)
            }
        }
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onTimeUpdate?(self.currentGlobalTime)
                let actuallyPlaying = self.player.timeControlStatus == .playing
                if actuallyPlaying != self.isPlaying {
                    self.setPlaying(actuallyPlaying)
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        onPlayStateChange?(playing)
    }
}
