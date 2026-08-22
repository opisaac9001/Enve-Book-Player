import AVFoundation
import Combine
import Logging

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class AudioService: NSObject, ObservableObject {

    public static let shared = AudioService()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var playbackRate: Double = 1.0 {
        didSet { applyPlaybackRate() }
    }
    @Published var volume: Double = 1.0 {
        didSet { applyVolume() }
    }
    @Published private(set) var error: Error?
    @Published var currentBookId: String?
    @Published private(set) var currentTrackIndex: Int = 0
    @Published private(set) var trackCount: Int = 0
    @Published private(set) var isReady = false

    // Emits the book ID when the final queued track finishes.
    let playbackDidFinishSubject = PassthroughSubject<String, Never>()

    private var nowPlayingBook: Book?
    private var nowPlayingOverrideTitle: String?
    private var nowPlayingOverrideArtist: String?
    private var nowPlayingOverrideArtwork: UIImage?

    @Published var voiceBoostEnabled = false
    @Published var voiceBoostPreset: VoiceBoostPreset = .neutral
    @Published var basicVoiceMode: BasicVoiceMode = .off
    @Published var eqEnabled = false
    @Published var eqBands: [Float] = Array(repeating: 0.0, count: 10)

    enum PauseSource {
        case user
        case routeChange
        case interruption
    }

    private var lastPauseSource: PauseSource?

    private var player: AVQueuePlayer?
    private var playerItems: [AVPlayerItem] = []
    private var audioTracks: [AudioTrack] = []
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var isAudioSessionConfigured = false
    private var lastPausedTime: TimeInterval?
    private var lastPausedBookId: String?
    private var lastPausedDate: Date?
    private var pendingStartTime: TimeInterval?
    private var pendingPlayAfterReady = false
    private var uiHeldTime: TimeInterval?
    private var suppressTimeUpdates = false
    private var uiHoldExpiresAt: Date?
    private var lastEmittedTime: TimeInterval = 0
    private var ignoreLargeJumpsUntil: Date?

    private var securityScopedURLs: [URL] = []

    private var currentItemObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var endOfPlaybackObserver: NSObjectProtocol?

    private var eqProcessor: EQTapProcessor?

    private let sessionManager = SessionManager.shared

    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private override init() {
        super.init()
        setupNotifications()
        setupSessionManager()
    }

    private func setupSessionManager() {
        sessionManager.onSessionTimeout = { [weak self] in
            self?.pause()
            AppLogger.player.info("Session timed out, playback paused")
        }
    }

    func load(url: URL, bookId: String? = nil, startingAt startTime: TimeInterval = 0) {
        let track = AudioTrack(
            index: 0,
            title: url.deletingPathExtension().lastPathComponent,
            filePath: url.isFileURL ? url.path : nil,
            contentUrl: url.isFileURL ? nil : url.absoluteString,
            duration: 0,
            startOffset: 0
        )
        loadTracks([track], bookId: bookId, startingAt: startTime)
    }

    func loadTracks(_ tracks: [AudioTrack], bookId: String? = nil, startingAt globalPosition: TimeInterval = 0) {
        AppLogger.player.debug("Loading \(tracks.count) tracks")
        AppLogger.player.debug(
            "EQ state: eqEnabled=\(eqEnabled), voiceBoostEnabled=\(voiceBoostEnabled), preset=\(voiceBoostPreset.displayName)"
        )

        if globalPosition > 0 {
            holdUI(at: globalPosition)
        }

        cleanup()

        audioTracks = tracks
        trackCount = tracks.count
        currentBookId = bookId
        duration = tracks.reduce(0) { $0 + $1.duration }

        guard !tracks.isEmpty else {
            AppLogger.player.info("No tracks to load")
            return
        }

        if eqEnabled || voiceBoostEnabled {
            if eqProcessor == nil {
                eqProcessor = EQTapProcessor()
                AppLogger.player.info("EQ processor initialized for loading")
            }
            let bands = voiceBoostPreset.toEQBands()
            eqProcessor?.setBands(bands)
        }

        setupAudioSession()

        playerItems = tracks.compactMap { track -> AVPlayerItem? in
            guard let url = resolveTrackURL(track) else {
                let source = track.filePath ?? track.contentUrl ?? "missing"
                AppLogger.player.error(
                    "Failed to resolve audio track diagnosticID=\(DiagnosticLogSanitizer.identifier(for: source))"
                )
                return nil
            }

            if url.isFileURL {
                let exists = FileManager.default.fileExists(atPath: url.path)
                let readable = FileManager.default.isReadableFile(atPath: url.path)
                AppLogger.player.debug(
                    "File check: exists=\(exists), readable=\(readable), \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
                )
            }

            let asset: AVURLAsset
            if let headers = track.headers, !headers.isEmpty {
                asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            } else {
                asset = AVURLAsset(url: url)
            }
            let item = AVPlayerItem(asset: asset)

            if eqEnabled || voiceBoostEnabled, let processor = eqProcessor {
                processor.attachTap(to: item)
                AppLogger.player.info("EQ tap attached to item")
            }

            return item
        }

        guard !playerItems.isEmpty else {
            AppLogger.player.error("Failed to create player items")
            error = NSError(domain: "AudioService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load audio files"])
            return
        }

        player = AVQueuePlayer(items: playerItems)
        player?.actionAtItemEnd = .advance
        player?.automaticallyWaitsToMinimizeStalling = false

        if duration == 0, let firstItem = playerItems.first {
            setupDurationObserver(for: firstItem)
        }

        applyPlaybackRate()
        applyVolume()

        setupTimeObserver()
        setupItemObservers()

        if globalPosition > 0 {
            pendingStartTime = globalPosition
            applyPendingStartTimeIfPossible()
        }

        error = nil

        AppLogger.player.debug("Loaded \(playerItems.count) tracks, duration: \(duration)s, waiting for item to be ready...")
    }

    func play() {
        guard let player = player else {
            AppLogger.player.info("No player to play")
            return
        }

        setupAudioSession()

        if let paused = lastPausedTime,
            let pausedBookId = lastPausedBookId,
            let pausedDate = lastPausedDate,
            let currentBookId,
            pausedBookId == currentBookId
        {
            let current = currentGlobalTime()
            if paused > 0.25 && abs(current - paused) > 0.5 {
                let pauseDuration = Date().timeIntervalSince(pausedDate)
                let smartRewindSeconds = calculateSmartRewindSeconds(pauseDuration: pauseDuration)
                let rewindedTime = max(0, paused - smartRewindSeconds)

                AppLogger.player.info(
                    "⏪ [AudioService] Smart rewind: paused for \(Int(pauseDuration))s, rewinding \(Int(smartRewindSeconds))s from \(Int(paused)) to \(Int(rewindedTime))"
                )
                resumeBySeeking(to: rewindedTime)
                return
            }
        }

        guard let currentItem = player.currentItem else {
            AppLogger.player.info("No current item to play")
            return
        }

        let itemStatus = currentItem.status
        AppLogger.player.debug("Current item status: \(itemStatus.rawValue) (0=unknown, 1=readyToPlay, 2=failed)")

        if itemStatus != .readyToPlay {
            AppLogger.player.info("[AudioService] Waiting for player item to be ready (status=\(itemStatus.rawValue))...")
            pendingPlayAfterReady = true
            return
        }

        startPlaybackNow()
    }

    private func startPlaybackNow() {
        guard let player = player else {
            AppLogger.player.info("startPlaybackNow: No player!")
            return
        }

        AppLogger.player.info(
            "Before play: rate=\(player.rate), status=\(player.status.rawValue), currentItem=\(player.currentItem != nil)"
        )

        player.play()

        AppLogger.player.info("After play: rate=\(player.rate), timeControlStatus=\(player.timeControlStatus.rawValue)")

        isPlaying = true
        applyPlaybackRate()

        AppLogger.player.info("After applyPlaybackRate: rate=\(player.rate)")

        pendingPlayAfterReady = false
        lastPausedTime = nil
        lastPausedDate = nil
        lastPauseSource = nil

        if let bookId = currentBookId {
            if sessionManager.activeSessionId != bookId {
                sessionManager.startSession(bookId: bookId)
            } else {
                sessionManager.recordActivity()
            }
        }

        #if os(iOS)
        beginBackgroundTask()
        #endif
        pushNowPlaying()

        AppLogger.player.info("Play")
    }

    private func calculateSmartRewindSeconds(pauseDuration: TimeInterval) -> TimeInterval {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()

        guard prefs.smartRewindEnabled else { return 0 }

        let shortThreshold = max(0, prefs.smartRewindShortPauseThreshold)
        let longThreshold = max(shortThreshold, prefs.smartRewindLongPauseThreshold)
        let shortAmount = max(0, prefs.smartRewindShortAmount)
        let longAmount = max(0, prefs.smartRewindLongAmount)

        switch pauseDuration {
        case 0..<shortThreshold:
            return 0
        case shortThreshold..<longThreshold:
            return shortAmount
        default:
            return longAmount
        }
    }

    func pause() {
        pause(source: .user)
    }

    private func pause(source: PauseSource) {
        guard isPlaying else { return }

        player?.pause()
        isPlaying = false
        lastPausedTime = currentGlobalTime()
        lastPausedBookId = currentBookId
        lastPausedDate = Date()
        lastPauseSource = source

        #if os(iOS)
        endBackgroundTask()
        #endif
        pushNowPlaying()

        AppLogger.player.info("Pause (source: \(source))")
    }

    func togglePlayPause() {
        AppLogger.player.info("togglePlayPause - isPlaying: \(isPlaying)")

        if isPlaying {
            pause(source: .user)
        } else {
            if lastPauseSource == .routeChange {
                AppLogger.player.info("Clearing route change block for user action")
            }
            lastPauseSource = nil
            play()
        }
    }

    func togglePlay() {
        togglePlayPause()
    }

    func stop() {
        pause()
        lastPausedDate = nil
        seek(to: 0)
    }

    func seek(to time: TimeInterval) {
        let clampedTime: TimeInterval
        if duration > 0 {
            clampedTime = max(0, min(time, duration))
        } else {
            clampedTime = max(0, time)
        }
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        if !isPlaying {
            lastPausedTime = clampedTime
            AppLogger.player.info("Updated lastPausedTime to \(clampedTime) (paused)")
        }

        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard let self, completed else { return }
            Task { @MainActor in
                if !self.suppressTimeUpdates {
                    self.currentTime = clampedTime
                }
                self.lastEmittedTime = clampedTime
                self.updateNowPlayingTime()

                self.sessionManager.recordActivity()
            }
        }
    }

    private func currentGlobalTime() -> TimeInterval {
        var global: TimeInterval = 0
        for i in 0..<currentTrackIndex {
            if i < audioTracks.count {
                global += audioTracks[i].duration
            }
        }
        if let player = player {
            global += player.currentTime().seconds
        }
        return max(0, global)
    }

    private func resumeBySeeking(to globalTime: TimeInterval) {
        guard let player = player else { return }

        let target = max(0, globalTime)

        holdUI(at: target)

        let hasTrackDurations = !audioTracks.isEmpty && audioTracks.allSatisfy { $0.duration > 0 }
        if !hasTrackDurations {
            let cmTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                guard let self, completed else { return }
                Task { @MainActor in
                    player.play()
                    self.applyPlaybackRate()
                    self.isPlaying = true
                    self.lastPausedTime = nil
                    self.lastPauseSource = nil
                    #if os(iOS)
                    self.beginBackgroundTask()
                    #endif
                    self.pushNowPlaying()
                    AppLogger.player.info("Play (resumed via seek)")
                }
            }
            return
        }

        var accumulated: TimeInterval = 0
        for (index, track) in audioTracks.enumerated() {
            if target < accumulated + track.duration {
                let localTime = target - accumulated
                seekToTrack(index: index, localTime: localTime) { [weak self] completed in
                    guard let self, completed else { return }
                    Task { @MainActor in
                        player.play()
                        self.applyPlaybackRate()
                        self.isPlaying = true
                        self.lastPausedTime = nil
                        self.lastPauseSource = nil
                        #if os(iOS)
                        self.beginBackgroundTask()
                        #endif
                        self.pushNowPlaying()
                        AppLogger.player.info("Play (resumed via seek)")
                    }
                }
                return
            }
            accumulated += track.duration
        }

        player.play()
        applyPlaybackRate()
        isPlaying = true
        lastPausedTime = nil
        lastPauseSource = nil
    }

    func seekGlobal(to globalTime: TimeInterval) {
        guard !audioTracks.isEmpty else {
            AppLogger.player.info("seekGlobal: no tracks loaded")
            return
        }

        AppLogger.player.info("seekGlobal to \(globalTime), tracks: \(audioTracks.count), currentTrackIndex: \(currentTrackIndex)")

        if !isPlaying {
            lastPausedTime = globalTime
            AppLogger.player.info("Updated lastPausedTime to \(globalTime) (paused)")
        }

        let hasTrackDurations = audioTracks.allSatisfy { $0.duration > 0 }

        if !hasTrackDurations || audioTracks.count == 1 {
            AppLogger.player.info("seekGlobal: using direct seek (single track or no track durations)")
            seek(to: globalTime)
            currentTime = globalTime
            lastEmittedTime = globalTime
            return
        }

        var accumulated: TimeInterval = 0
        for (index, track) in audioTracks.enumerated() {
            if globalTime < accumulated + track.duration {
                let localTime = globalTime - accumulated
                AppLogger.player.info("seekGlobal: target track \(index), localTime \(localTime)")
                seekToTrack(index: index, localTime: localTime)
                return
            }
            accumulated += track.duration
        }

        AppLogger.player.info("seekGlobal: past end, seeking to last track")
        if let lastTrack = audioTracks.last {
            seekToTrack(index: audioTracks.count - 1, localTime: lastTrack.duration)
        }
    }

    func skipForward(seconds: TimeInterval = 15) {
        let effectiveSeconds = seconds == 15 ? preferredSkipForwardAmount() : seconds
        AppLogger.player.debug("skipForward: currentTime=\(currentTime), adding \(effectiveSeconds)s")
        let newTime = min(currentTime + effectiveSeconds, duration)
        AppLogger.player.debug("skipForward: seeking to \(newTime)")
        seekGlobal(to: newTime)
    }

    func skipBackward(seconds: TimeInterval = 15) {
        let effectiveSeconds = seconds == 15 ? preferredSkipBackwardAmount() : seconds
        AppLogger.player.debug("⏪ [AudioService] skipBackward: currentTime=\(currentTime), subtracting \(effectiveSeconds)s")
        let newTime = max(currentTime - effectiveSeconds, 0)
        AppLogger.player.debug("⏪ [AudioService] skipBackward: seeking to \(newTime)")
        seekGlobal(to: newTime)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = max(Double(AppConstants.Playback.minSpeed), min(rate, Double(AppConstants.Playback.maxSpeed)))
    }

    func setVolume(_ vol: Double) {
        volume = max(0, min(vol, 1))
    }

    func setBasicVoiceMode(_ mode: BasicVoiceMode) {
        basicVoiceMode = mode
        applyVoiceMode()
    }

    func setVoiceBoostEnabled(_ enabled: Bool) {
        AppLogger.player.info("Setting voice boost enabled: \(enabled)")
        voiceBoostEnabled = enabled
        updateEQState()
    }

    func setVoiceBoostPreset(_ preset: VoiceBoostPreset) {
        AppLogger.player.info("Setting voice boost preset: \(preset.displayName)")
        voiceBoostPreset = preset

        if voiceBoostEnabled && eqProcessor == nil {
            eqProcessor = EQTapProcessor()
            reattachEQTaps()
        }

        applyVoiceBoostPreset()
    }

    func setEQEnabled(_ enabled: Bool) {
        AppLogger.player.info("Setting EQ enabled: \(enabled)")
        eqEnabled = enabled
        updateEQState()
    }

    func setEQBands(_ bands: [Float]) {
        AppLogger.player.info("Setting EQ bands: \(bands.map { String(format: "%.1f", $0) })")
        eqBands = bands
        eqProcessor?.setBands(bands)
    }

    private(set) var pitchSemitones: Double = 0.0

    func setIndependentPitchSemitones(_ semitones: Double) {
        pitchSemitones = semitones
        AppLogger.player.info("Pitch semitones: \(semitones)")
        AppLogger.player.info("Note: Full pitch shifting requires AVAudioEngine migration")
    }

    private(set) var isMonoMixEnabled: Bool = false

    func setMonoMixEnabled(_ enabled: Bool) {
        isMonoMixEnabled = enabled
        AppLogger.player.info("Mono mix: \(enabled)")

        guard let currentItem = player?.currentItem else { return }

        Task { @MainActor in
            if enabled {
                let mix = AVMutableAudioMix()
                do {
                    let tracks = try await currentItem.asset.loadTracks(withMediaType: .audio)
                    if let track = tracks.first {
                        let params = AVMutableAudioMixInputParameters(track: track)
                        mix.inputParameters = [params]
                        currentItem.audioMix = mix
                    }
                } catch {
                    AppLogger.player.error("Failed to load audio tracks: \(error)")
                }
            } else {
                currentItem.audioMix = nil
            }
        }
    }

    private(set) var stereoBalance: Float = 0.0

    func setStereoBalance(_ balance: Float) {
        stereoBalance = max(-1.0, min(1.0, balance))
        AppLogger.player.info("Stereo balance: \(stereoBalance)")

        guard let currentItem = player?.currentItem else { return }

        Task { @MainActor in
            do {
                let tracks = try await currentItem.asset.loadTracks(withMediaType: .audio)
                guard let track = tracks.first else { return }
                let mix = AVMutableAudioMix()
                let params = AVMutableAudioMixInputParameters(track: track)
                let leftVolume = balance < 0 ? 1.0 : Float(1.0 - balance)
                params.setVolumeRamp(
                    fromStartVolume: leftVolume,
                    toEndVolume: leftVolume,
                    timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.1, preferredTimescale: 600))
                )
                mix.inputParameters = [params]
                currentItem.audioMix = mix
            } catch {
                AppLogger.player.error("Failed to load audio tracks: \(error)")
            }
        }
    }

    private(set) var noiseReductionLevel: Float = 0.0

    func setNoiseReductionLevel(_ level: Float) {
        noiseReductionLevel = max(0.0, min(1.0, level))
        AppLogger.player.info("Noise reduction: \(noiseReductionLevel)")
        AppLogger.player.info("Note: Noise reduction requires AVAudioEngine migration")
    }

    private(set) var isBinauralEnabled: Bool = false

    func setBinauralEnabled(_ enabled: Bool) {
        isBinauralEnabled = enabled
        AppLogger.player.info("Binaural: \(enabled)")
        AppLogger.player.info("Note: Binaural audio requires AVAudioEngine migration")
    }

    func setupNowPlaying(book: Book) {
        nowPlayingBook = book
        NowPlayingCoordinator.shared.setActive(self)
        pushNowPlaying()
    }

    func updateNowPlayingInfo(title: String? = nil, artist: String? = nil, artwork: UIImage? = nil) {
        guard !NowPlayingCoordinator.shared.isAnotherTargetActive(than: self) else { return }
        nowPlayingOverrideTitle = title ?? nowPlayingOverrideTitle
        nowPlayingOverrideArtist = artist ?? nowPlayingOverrideArtist
        nowPlayingOverrideArtwork = artwork ?? nowPlayingOverrideArtwork
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        guard !NowPlayingCoordinator.shared.isAnotherTargetActive(than: self) else { return }
        let title = nowPlayingOverrideTitle ?? nowPlayingBook?.title ?? "Audio"
        NowPlayingCoordinator.shared.updateNowPlaying(
            NowPlayingInfo(
                title: title,
                artist: nowPlayingOverrideArtist ?? nowPlayingBook?.author,
                duration: duration,
                elapsed: currentTime,
                rate: isPlaying ? playbackRate : 0,
                defaultRate: 1.0,
                artworkImage: nowPlayingOverrideArtwork,
                artworkURL: nowPlayingOverrideArtwork == nil ? nowPlayingBook?.coverURL : nil
            )
        )
    }

    func cleanup() {
        player?.pause()
        isPlaying = false

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }

        player?.removeAllItems()
        player = nil
        playerItems = []
        audioTracks = []

        stopSecurityScopedAccess()

        if !suppressTimeUpdates {
            currentTime = 0
        }
        duration = 0
        isReady = false
        pendingPlayAfterReady = false
        currentTrackIndex = 0
        trackCount = 0
        error = nil

        #if os(iOS)
        endBackgroundTask()
        #endif

        AppLogger.player.debug("Cleanup complete")
    }
}

private extension AudioService {
    func setupAudioSession() {
        #if os(iOS)
        if isAudioSessionConfigured && isPlaying { return }

        let session = AVAudioSession.sharedInstance()

        let mode = basicVoiceMode.audioSessionMode
        let options: AVAudioSession.CategoryOptions

        switch basicVoiceMode {
        case .strong:
            options = [.allowBluetoothA2DP]
        default:
            options = [.allowAirPlay, .allowBluetoothA2DP]
        }

        do {
            if #available(iOS 13.0, *) {
                let policy: AVAudioSession.RouteSharingPolicy = (mode == .spokenAudio) ? .longFormAudio : .default
                try session.setCategory(.playback, mode: mode, policy: policy, options: options)
            } else {
                try session.setCategory(.playback, mode: mode, options: options)
            }
            try session.setActive(true)
            isAudioSessionConfigured = true
            AppLogger.player.info("Audio session configured (mode: \(mode.rawValue))")
        } catch {
            AppLogger.player.error("Mode \(mode.rawValue) failed: \(error.localizedDescription)")
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
                isAudioSessionConfigured = true
                AppLogger.player.warning("Audio session configured (simple fallback)")
            } catch {
                AppLogger.player.error("Audio session error: \(error)")
                self.error = error
            }
        }
        #endif
    }

    func applyVoiceMode() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            let mode = basicVoiceMode.audioSessionMode
            if #available(iOS 13.0, *) {
                let policy: AVAudioSession.RouteSharingPolicy = (mode == .spokenAudio) ? .longFormAudio : .default
                try session.setCategory(.playback, mode: mode, policy: policy, options: [.allowAirPlay, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, mode: mode, options: [.allowAirPlay, .allowBluetoothA2DP])
            }
            AppLogger.player.info("[AudioService] Voice mode: \(basicVoiceMode.displayName)")
        } catch {
            AppLogger.player.error("Failed to set voice mode: \(error)")
        }
        #endif
    }
}

private extension AudioService {
    func setupNotifications() {
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
            .store(in: &cancellables)
        #endif
    }

    func handleRouteChange(_ notification: Notification) {
        #if os(iOS)
        guard let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
        }

        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        AppLogger.player.info("[AudioService] Route changed (\(reason.rawValue)): \(route)")

        if reason == .oldDeviceUnavailable {
            pause(source: .routeChange)
            AppLogger.player.info("Device removed - paused")
        }
        #endif
    }

    func handleInterruption(_ notification: Notification) {
        #if os(iOS)
        guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        guard !anotherTargetOwnsInterruptionResume else {
            AppLogger.player.info("[AudioService] Ignoring interruption; another playback target is active")
            return
        }

        switch type {
        case .began:
            pause(source: .interruption)
            AppLogger.player.info("Interrupted")
        case .ended:
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    play()
                    AppLogger.player.info("Resuming after interruption")
                }
            }
        @unknown default:
            break
        }
        #endif
    }

    var anotherTargetOwnsInterruptionResume: Bool {
        NowPlayingCoordinator.shared.isAnotherTargetActive(than: self)
    }
}

private extension AudioService {
    func preferredSkipForwardAmount() -> TimeInterval {
        max(1, LibraryDisplayPreferencesStore.shared.loadPreferences().skipForwardAmount)
    }

    func preferredSkipBackwardAmount() -> TimeInterval {
        max(1, LibraryDisplayPreferencesStore.shared.loadPreferences().skipBackwardAmount)
    }

}

extension AudioService: RemoteCommandTarget {
    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteToggle() { togglePlayPause() }
    func remoteNext() { skipForward() }
    func remotePrevious() { skipBackward() }
    func remoteSkipForward(by seconds: TimeInterval?) { skipForward(seconds: seconds ?? preferredSkipForwardAmount()) }
    func remoteSkipBackward(by seconds: TimeInterval?) { skipBackward(seconds: seconds ?? preferredSkipBackwardAmount()) }
    func remoteSeek(to positionTime: TimeInterval) { seekGlobal(to: positionTime) }
    var remoteSkipForwardInterval: TimeInterval { preferredSkipForwardAmount() }
    var remoteSkipBackwardInterval: TimeInterval { preferredSkipBackwardAmount() }
}

private extension AudioService {
    func setupTimeObserver() {
        guard let player = player else { return }

        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTimeUpdate(time)
            }
        }
    }

    func handleTimeUpdate(_ time: CMTime) {
        guard let player = player, player.rate > 0 else { return }

        var globalTime: TimeInterval = 0

        for i in 0..<currentTrackIndex {
            if i < audioTracks.count {
                globalTime += audioTracks[i].duration
            }
        }

        globalTime += time.seconds

        if !globalTime.isFinite || globalTime < 0 {
            return
        }

        if suppressTimeUpdates, let hold = uiHeldTime {
            let now = Date()
            if let expires = uiHoldExpiresAt, now <= expires {
                if abs(globalTime - hold) > 5.0 {
                    currentTime = hold
                    lastEmittedTime = hold
                    return
                }
                suppressTimeUpdates = false
                uiHeldTime = nil
                uiHoldExpiresAt = nil
            } else {
                suppressTimeUpdates = false
                uiHeldTime = nil
                uiHoldExpiresAt = nil
            }
        }

        if let until = ignoreLargeJumpsUntil, Date() <= until {
        } else {
            let delta = abs(globalTime - lastEmittedTime)
            if delta > 120 {
                return
            }
        }

        currentTime = globalTime
        lastEmittedTime = globalTime
    }

    func setupItemObservers() {
        guard let player = player else { return }

        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.handleCurrentItemChange()
            }
        }

        observeEndOfPlayback()

        if let firstItem = playerItems.first {
            itemStatusObserver = firstItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self = self else { return }

                if item.status == .failed {
                    AppLogger.player.error("Player item failed to load: \(item.error?.localizedDescription ?? "Unknown error")")
                    Task { @MainActor in
                        self.error =
                            item.error
                            ?? NSError(
                                domain: "AudioService",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to load audio"]
                            )
                        self.isReady = false
                        self.pendingPlayAfterReady = false
                    }
                } else if item.status == .readyToPlay {
                    AppLogger.player.info("Player item ready to play")
                    Task { @MainActor in
                        self.isReady = true
                        if self.pendingPlayAfterReady {
                            AppLogger.player.info("Starting deferred playback")
                            self.startPlaybackNow()
                        }
                    }
                }
            }
        }
    }

    func observeEndOfPlayback() {
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }
        guard let lastItem = playerItems.last, let finishedBookId = currentBookId else { return }

        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: lastItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentBookId == finishedBookId else { return }
                self.playbackDidFinishSubject.send(finishedBookId)
            }
        }
    }

    func handleCurrentItemChange() {
        guard let currentItem = player?.currentItem else { return }

        if let relativeIndex = playerItems.firstIndex(of: currentItem) {
            let offset = audioTracks.count - playerItems.count
            let absoluteIndex = offset + relativeIndex

            if absoluteIndex >= 0 && absoluteIndex < audioTracks.count {
                currentTrackIndex = absoluteIndex
                AppLogger.player.info("[AudioService] Now on track \(absoluteIndex + 1)/\(trackCount)")
            }
        }

        updateNowPlayingInfo()

        applyPendingStartTimeIfPossible()
    }

    func applyPendingStartTimeIfPossible() {
        guard let desired = pendingStartTime, desired > 0 else { return }
        guard let currentItem = player?.currentItem else { return }

        if currentItem.status != .readyToPlay {
            statusObserver?.invalidate()
            statusObserver = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                Task { @MainActor in
                    if item.status == .readyToPlay {
                        self.statusObserver?.invalidate()
                        self.statusObserver = nil
                        self.applyPendingStartTimeIfPossible()
                    }
                }
            }
            return
        }

        let hasTrackDurations = !audioTracks.isEmpty && audioTracks.allSatisfy { $0.duration > 0 }
        if hasTrackDurations {
            holdUI(at: desired)
            seekGlobal(to: desired)
        } else {
            holdUI(at: desired)
            seek(to: desired)
        }
        pendingStartTime = nil
    }

    private func holdUI(at time: TimeInterval) {
        let t = max(0, time)
        uiHeldTime = t
        suppressTimeUpdates = true
        uiHoldExpiresAt = Date().addingTimeInterval(2.0)
        ignoreLargeJumpsUntil = Date().addingTimeInterval(2.0)
        currentTime = t
        lastEmittedTime = t
    }

    func updateNowPlayingTime() {
        pushNowPlaying()
    }

    func setupDurationObserver(for item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            do {
                let assetDuration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(assetDuration)
                if seconds.isFinite && seconds > 0 {
                    self.duration = seconds
                    self.isReady = true
                    AppLogger.player.info("[AudioService] Duration loaded: \(seconds)s")
                    self.updateNowPlayingInfo()
                } else {
                    AppLogger.player.error("Invalid duration: \(seconds)")
                    self.isReady = false
                    self.error = NSError(
                        domain: "AudioService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid audio duration"]
                    )
                }
            } catch {
                AppLogger.player.error("Failed to load duration: \(error.localizedDescription)")
                self.isReady = false
                self.error = error
            }
        }
    }

    private func withTimeout<R: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> R) async throws -> R {
        try await withThrowingTaskGroup(of: R.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(
                    domain: "AudioService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Audio loading timed out after \(Int(seconds)) seconds"]
                )
            }

            if let result = try await group.next() {
                group.cancelAll()
                return result
            }
            group.cancelAll()
            throw NSError(
                domain: "AudioService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Audio loading failed unexpectedly"]
            )
        }
    }
}

private extension AudioService {
    func resolveTrackURL(_ track: AudioTrack) -> URL? {
        var url: URL?

        if let path = track.filePath {
            url = URL(fileURLWithPath: path)
        } else if let urlString = track.contentUrl, let parsedURL = URL(string: urlString) {
            url = parsedURL
        }

        guard let resolvedURL = url else { return nil }

        if resolvedURL.isFileURL {
            if resolvedURL.startAccessingSecurityScopedResource() {
                securityScopedURLs.append(resolvedURL)
                AppLogger.player.debug(
                    "Started security-scoped access for \(DiagnosticLogSanitizer.fileDescriptor(for: resolvedURL))"
                )
            }
        }

        return resolvedURL
    }

    func stopSecurityScopedAccess() {
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
            AppLogger.player.debug(
                "Stopped security-scoped access for \(DiagnosticLogSanitizer.fileDescriptor(for: url))"
            )
        }
        securityScopedURLs.removeAll()
    }

    func seekToTrack(index: Int, localTime: TimeInterval, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard index >= 0, index < audioTracks.count else {
            AppLogger.player.error("seekToTrack: invalid index \(index), tracks: \(audioTracks.count)")
            return
        }

        AppLogger.player.info("seekToTrack index=\(index), localTime=\(localTime), currentTrackIndex=\(currentTrackIndex)")

        if currentTrackIndex != index {
            AppLogger.player.info("Changing track from \(currentTrackIndex) to \(index)")

            let wasPlaying = isPlaying
            let currentRate = playbackRate

            if wasPlaying {
                player?.pause()
            }

            if let observer = timeObserver, let player = player {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }

            currentItemObserver?.invalidate()
            currentItemObserver = nil

            player?.removeAllItems()

            let remainingTracks = Array(audioTracks[index...])
            let newItems = remainingTracks.compactMap { track -> AVPlayerItem? in
                guard let url = resolveTrackURL(track) else { return nil }
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)

                if eqEnabled || voiceBoostEnabled, let processor = eqProcessor {
                    processor.attachTap(to: item)
                }
                return item
            }

            guard !newItems.isEmpty else {
                AppLogger.player.error("Failed to create new player items for track change")
                return
            }

            playerItems = newItems

            player = AVQueuePlayer(items: newItems)
            player?.actionAtItemEnd = .advance
            player?.automaticallyWaitsToMinimizeStalling = true
            applyPlaybackRate()
            applyVolume()

            setupTimeObserver()
            setupItemObservers()

            currentTrackIndex = index

            var globalTimeAtSeek: TimeInterval = 0
            for i in 0..<index {
                globalTimeAtSeek += audioTracks[i].duration
            }
            globalTimeAtSeek += localTime
            currentTime = globalTimeAtSeek
            lastEmittedTime = globalTimeAtSeek

            let cmTime = CMTime(seconds: localTime, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self = self else { return }
                Task { @MainActor in
                    AppLogger.player.info("Track change seek completed, resuming: \(wasPlaying)")
                    if wasPlaying {
                        self.player?.play()
                        self.player?.rate = Float(currentRate)
                        self.isPlaying = true
                    }
                    completion?(finished)
                }
            }
        } else {
            AppLogger.player.info("[AudioService] Same track, seeking to \(localTime)")

            var globalTimeAtSeek: TimeInterval = 0
            for i in 0..<currentTrackIndex {
                globalTimeAtSeek += audioTracks[i].duration
            }
            globalTimeAtSeek += localTime
            currentTime = globalTimeAtSeek
            lastEmittedTime = globalTimeAtSeek

            let cmTime = CMTime(seconds: localTime, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in
                    AppLogger.player.info("Seek completed: \(finished)")
                    completion?(finished)
                }
            }
        }
    }
}

private extension AudioService {
    func applyPlaybackRate() {
        guard let player = player else { return }
        player.rate = isPlaying ? Float(playbackRate) : 0.0
    }

    func applyVolume() {
        player?.volume = Float(volume)
    }

    func updateEQState() {
        let shouldEnableEQ = eqEnabled || voiceBoostEnabled

        if shouldEnableEQ {
            if eqProcessor == nil {
                eqProcessor = EQTapProcessor()
                AppLogger.player.info("EQ processor initialized")
            }
            applyVoiceBoostPreset()

            reattachEQTaps()
        } else {
            for item in playerItems {
                item.audioMix = nil
            }
            eqProcessor = nil
            AppLogger.player.info("EQ disabled")
        }
    }

    func reattachEQTaps() {
        guard let processor = eqProcessor else { return }

        for item in playerItems {
            processor.attachTap(to: item)
        }
        AppLogger.player.info("EQ taps reattached to \(playerItems.count) items")
    }

    func applyVoiceBoostPreset() {
        guard let processor = eqProcessor else { return }

        let bands = voiceBoostPreset.toEQBands()
        processor.setBands(bands)

        AppLogger.player.info("Applied preset: \(voiceBoostPreset.displayName)")
    }
}

#if os(iOS)
private extension AudioService {
    func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif

extension VoiceBoostPreset {
    func toEQBands() -> [Float] {
        switch self {
        case .neutral:
            return Array(repeating: 0, count: 10)

        case .voiceBoost:
            return [-3, -2, -1, 0, 0, 1, 4, 5, 3, 0]

        case .bright:
            return [-2, -1, 0, 0, 0, 2, 3, 4, 5, 3]

        case .warm:
            return [2, 3, 2, 1, 0, 0, 1, 0, -1, -2]
        }
    }
}
