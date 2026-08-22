import Foundation
import MediaPlayer
import os

#if os(iOS)
import UIKit
#endif

@MainActor
final class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()
    private init() {}

    private weak var activeTarget: (any RemoteCommandTarget)?
    #if os(iOS)
    private var nowPlayingSession: MPNowPlayingSession?
    #endif

    private var lastInfo: NowPlayingInfo?
    private var lastArtworkURL: URL?

    private nonisolated static let lastRate = OSAllocatedUnfairLock<Double>(initialState: 0)

    nonisolated static func currentPlaybackRate() -> Double {
        lastRate.withLock { $0 }
    }

    func setActive(_ target: any RemoteCommandTarget) {
        activeTarget = target
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        armCommands()
        applySkipIntervals(
            forward: target.remoteSkipForwardInterval,
            backward: target.remoteSkipBackwardInterval
        )
    }

    #if os(iOS)
    func setNowPlayingSession(_ session: MPNowPlayingSession?) {
        nowPlayingSession = session
        if activeTarget != nil {
            armCommands()
        }
    }
    #endif

    func resignIfActive(_ target: any RemoteCommandTarget) {
        if activeTarget === target {
            activeTarget = nil
        }
    }

    func isActive(_ target: any RemoteCommandTarget) -> Bool {
        activeTarget === target
    }

    func isAnotherTargetActive(than target: any RemoteCommandTarget) -> Bool {
        activeTarget != nil && activeTarget !== target
    }

    func toggleActivePlayback() {
        activeTarget?.remoteToggle()
    }

    func updateNowPlaying(_ info: NowPlayingInfo) {
        lastInfo = info
        Self.lastRate.withLock { $0 = info.rate }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: info.defaultRate,
            MPNowPlayingInfoPropertyIsLiveStream: !info.showsProgress,
        ]
        if let artist = info.artist { dict[MPMediaItemPropertyArtist] = artist }
        if let albumTitle = info.albumTitle { dict[MPMediaItemPropertyAlbumTitle] = albumTitle }
        if info.showsProgress {
            if let duration = info.duration { dict[MPMediaItemPropertyPlaybackDuration] = duration }
            dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = info.elapsed
        }
        if let mediaType = info.mediaType {
            dict[MPNowPlayingInfoPropertyMediaType] = mediaType.rawValue
        }
        if let contentIdentifier = info.contentIdentifier {
            dict[MPNowPlayingInfoPropertyExternalContentIdentifier] = contentIdentifier
        }
        if let collectionIdentifier = info.collectionIdentifier {
            dict[MPNowPlayingInfoCollectionIdentifier] = collectionIdentifier
        }
        if let serviceIdentifier = info.serviceIdentifier {
            dict[MPNowPlayingInfoPropertyServiceIdentifier] = serviceIdentifier
        }
        if let queueIndex = info.playbackQueueIndex {
            dict[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
        }
        if let queueCount = info.playbackQueueCount {
            dict[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }
        if let chapterNumber = info.chapterNumber {
            dict[MPNowPlayingInfoPropertyChapterNumber] = chapterNumber
        }
        if let chapterCount = info.chapterCount {
            dict[MPNowPlayingInfoPropertyChapterCount] = chapterCount
        }
        commandCenter.changePlaybackPositionCommand.isEnabled = info.showsProgress
        let center = infoCenter
        if info.artworkImage == nil,
            info.artworkURL == lastArtworkURL,
            let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork]
        {
            dict[MPMediaItemPropertyArtwork] = existing
        }
        center.nowPlayingInfo = dict
        #if os(iOS)
        center.playbackState = info.rate > 0 ? .playing : .paused
        #endif

        if let image = info.artworkImage {
            lastArtworkURL = nil
            attachArtwork(image)
        } else if let url = info.artworkURL {
            guard url != lastArtworkURL || center.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil else { return }
            lastArtworkURL = url
            loadArtwork(from: url)
        }
    }

    func clearNowPlaying(if target: any RemoteCommandTarget) {
        guard activeTarget === target || activeTarget == nil else { return }
        lastInfo = nil
        lastArtworkURL = nil
        Self.lastRate.withLock { $0 = 0 }
        let center = infoCenter
        center.nowPlayingInfo = nil
        #if os(iOS)
        center.playbackState = .stopped
        #endif
    }

    func updateSkipIntervals(forward: TimeInterval, backward: TimeInterval) {
        applySkipIntervals(forward: forward, backward: backward)
    }

    private func attachArtwork(_ image: UIImage) {
        let handler: @Sendable (CGSize) -> UIImage = { _ in image }
        let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        infoCenter.nowPlayingInfo = info
    }

    private func loadArtwork(from url: URL) {
        if let cached = DiskImageCache.shared.memoryImage(for: url) {
            attachArtwork(cached)
            return
        }

        Task.detached(priority: .userInitiated) {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                let isConnected = await MainActor.run { NetworkPolicyService.shared.isConnected }
                guard isConnected else { return }
                data = try? await URLSession.shared.data(from: url).0
            }
            guard let data, let image = UIImage(data: data) else { return }
            await MainActor.run {
                DiskImageCache.shared.save(image, for: url)
                self.attachArtwork(image)
            }
        }
    }

    private var infoCenter: MPNowPlayingInfoCenter {
        #if os(iOS)
        if let nowPlayingSession {
            return nowPlayingSession.nowPlayingInfoCenter
        }
        #endif
        return .default()
    }

    private var commandCenter: MPRemoteCommandCenter {
        #if os(iOS)
        if let nowPlayingSession {
            return nowPlayingSession.remoteCommandCenter
        }
        #endif
        return .shared()
    }

    private func applySkipIntervals(forward: TimeInterval, backward: TimeInterval) {
        let center = commandCenter
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
    }

    private func armCommands() {
        let center = commandCenter

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeTarget?.remotePlay()
            }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeTarget?.remotePause()
            }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeTarget?.remoteToggle()
            }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeTarget?.remoteNext()
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeTarget?.remotePrevious()
            }
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            Task { @MainActor [weak self] in
                self?.activeTarget?.remoteSkipForward(by: interval)
            }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            Task { @MainActor [weak self] in
                self?.activeTarget?.remoteSkipBackward(by: interval)
            }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = lastInfo?.showsProgress ?? true
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.activeTarget?.remoteSeek(to: positionTime)
            }
            return .success
        }
    }
}

@MainActor
protocol RemoteCommandTarget: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteToggle()
    func remoteNext()
    func remotePrevious()
    func remoteSkipForward(by seconds: TimeInterval?)
    func remoteSkipBackward(by seconds: TimeInterval?)
    func remoteSeek(to positionTime: TimeInterval)
    var remoteSkipForwardInterval: TimeInterval { get }
    var remoteSkipBackwardInterval: TimeInterval { get }
}

extension RemoteCommandTarget {
    var remoteSkipForwardInterval: TimeInterval { 30 }
    var remoteSkipBackwardInterval: TimeInterval { 15 }
}

@MainActor
struct NowPlayingInfo {
    var title: String
    var artist: String?
    var albumTitle: String?
    var duration: TimeInterval?
    var elapsed: TimeInterval
    var showsProgress: Bool
    var rate: Double
    var defaultRate: Double
    var mediaType: MPNowPlayingInfoMediaType?
    var contentIdentifier: String?
    var collectionIdentifier: String?
    var serviceIdentifier: String?
    var playbackQueueIndex: Int?
    var playbackQueueCount: Int?
    var chapterNumber: Int?
    var chapterCount: Int?
    var artworkImage: UIImage?
    var artworkURL: URL?

    init(
        title: String,
        artist: String? = nil,
        albumTitle: String? = nil,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval = 0,
        showsProgress: Bool = true,
        rate: Double = 0,
        defaultRate: Double = 1,
        mediaType: MPNowPlayingInfoMediaType? = nil,
        contentIdentifier: String? = nil,
        collectionIdentifier: String? = nil,
        serviceIdentifier: String? = nil,
        playbackQueueIndex: Int? = nil,
        playbackQueueCount: Int? = nil,
        chapterNumber: Int? = nil,
        chapterCount: Int? = nil,
        artworkImage: UIImage? = nil,
        artworkURL: URL? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.duration = duration
        self.elapsed = elapsed
        self.showsProgress = showsProgress
        self.rate = rate
        self.defaultRate = defaultRate
        self.mediaType = mediaType
        self.contentIdentifier = contentIdentifier
        self.collectionIdentifier = collectionIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.playbackQueueIndex = playbackQueueIndex
        self.playbackQueueCount = playbackQueueCount
        self.chapterNumber = chapterNumber
        self.chapterCount = chapterCount
        self.artworkImage = artworkImage
        self.artworkURL = artworkURL
    }
}
