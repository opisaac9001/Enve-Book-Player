import AVFoundation
import Combine
import Foundation
import Logging

@MainActor
final class PlaybackManagerController: PlaybackControlling, PlaybackEventPublishing, PlaybackFailureReporting,
    PlaybackBookMetadataUpdating, PlaybackNowPlayingUpdating, PlaybackConflictResolving,
    PlaybackOverlayControlling, PlaybackPreparationReporting
{
    static var shared: PlaybackManagerController { ProfileSession.owner.playback.controller }

    private let manager: PlaybackManager
    #if os(iOS) && canImport(GoogleCast)
    private let cast: CastPlaybackService?
    #endif
    private let changeSignal = PassthroughSubject<Void, Never>()
    private let eventSignal = PassthroughSubject<PlaybackEvent, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var reportedFailureBookID: String?

    let ownsProgressPersistence = true

    #if os(iOS) && canImport(GoogleCast)
    private var remote: CastPlaybackService? { cast?.ownsPlayback == true ? cast : nil }
    #endif

    var snapshot: PlaybackSnapshot {
        #if os(iOS) && canImport(GoogleCast)
        if let remote = cast?.snapshot { return remote }
        if !manager.hasActivePlayer, manager.currentBook == nil, let ended = cast?.endedSnapshot { return ended }
        #endif
        return PlaybackSnapshot(
            currentBook: manager.currentBook,
            isPlaying: manager.isPlaying,
            position: manager.currentTime,
            duration: manager.duration,
            playbackSpeed: Double(manager.playbackSpeed),
            volume: Double(manager.outputVolume()),
            isLoaded: manager.hasActivePlayer,
            isLoading: manager.isLoading,
            isOverlayPlaybackActive: manager.isOverlayPlaybackActive,
            errorDescription: manager.playbackError
        )
    }

    var livePosition: TimeInterval? {
        #if os(iOS) && canImport(GoogleCast)
        if let remote { return remote.livePosition }
        #endif
        return manager.livePosition
    }

    var snapshots: AnyPublisher<PlaybackSnapshot, Never> {
        changeSignal
            .map { [weak self] in self?.snapshot ?? .idle }
            .prepend(snapshot)
            .eraseToAnyPublisher()
    }

    var playbackEvents: AnyPublisher<PlaybackEvent, Never> {
        eventSignal.eraseToAnyPublisher()
    }

    var conflict: PlaybackProgressConflict? {
        manager.syncConflict.map {
            PlaybackProgressConflict(local: $0.local, server: $0.server, bookId: $0.bookId)
        }
    }

    var conflicts: AnyPublisher<PlaybackProgressConflict?, Never> {
        manager.syncConflictSubject
            .map { conflict in
                conflict.map {
                    PlaybackProgressConflict(local: $0.local, server: $0.server, bookId: $0.bookId)
                }
            }
            .eraseToAnyPublisher()
    }

    #if os(iOS) && canImport(GoogleCast)
    init(manager: PlaybackManager = .shared, cast: CastPlaybackService? = nil) {
        self.manager = manager
        self.cast = cast
        observeManager()
        cast?.onStateChange = { [weak self] in self?.changeSignal.send(()) }
        cast?.onEvent = { [weak self] in self?.eventSignal.send($0) }
    }
    #else
    init(manager: PlaybackManager = .shared) {
        self.manager = manager
        observeManager()
    }
    #endif

    private func observeManager() {
        manager.stateDidChangeSubject
        .sink { [weak self] in
            guard let self else { return }
            if self.manager.playbackError == nil {
                self.reportedFailureBookID = nil
            }
            self.changeSignal.send(())
        }
        .store(in: &cancellables)

        manager.playbackCompletionSubject
            .sink { [weak self] book in self?.eventSignal.send(.completed(book)) }
            .store(in: &cancellables)

        manager.playbackErrorSubject
            .sink { [weak self] _ in
                guard let self, let book = self.manager.currentBook else { return }
                self.reportPlaybackFailure(for: book)
            }
            .store(in: &cancellables)
    }

    func reportPlaybackFailure(for book: Book) {
        guard reportedFailureBookID != book.uniqueId else { return }
        reportedFailureBookID = book.uniqueId
        eventSignal.send(.failed(book))
    }

    func play() {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.play()
            return
        }
        if manager.currentBook == nil, cast?.resumeEndedPlaybackLocally() == true { return }
        #endif
        manager.play()
    }

    func pause() {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.pause()
            return
        }
        #endif
        manager.pause()
    }

    func stop() {
        #if os(iOS) && canImport(GoogleCast)
        if let cast, cast.ownsPlayback || cast.endedSnapshot != nil { cast.stop() }
        #endif
        manager.stop()
    }

    func togglePlay() {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.togglePlay()
            return
        }
        #endif
        manager.isPlaying ? manager.pause() : play()
    }

    func seek(to time: TimeInterval) {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.seek(to: time)
            return
        }
        #endif
        manager.seek(to: time)
    }

    func skipForward(seconds: TimeInterval) {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.skip(by: seconds)
            return
        }
        #endif
        manager.skipForward(seconds: seconds)
    }

    func skipBackward(seconds: TimeInterval) {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.skip(by: -seconds)
            return
        }
        #endif
        manager.skipBackward(seconds: seconds)
    }

    func setPlaybackRate(_ rate: Double) {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.setPlaybackRate(rate)
            return
        }
        #endif
        manager.setPlaybackSpeed(Float(rate))
    }

    func setVolume(_ volume: Double) {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.setVolume(volume)
            changeSignal.send(())
            return
        }
        #endif
        manager.setOutputVolume(Float(volume))
        changeSignal.send(())
    }

    func fadeOutAndPause(duration: TimeInterval, steps: Int) async {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.pause()
            return
        }
        #endif
        await manager.fadeOutAndPause(duration: duration, steps: steps)
    }

    func updateChapters(_ chapters: [Chapter], for book: Book) {
        #if os(iOS) && canImport(GoogleCast)
        cast?.updateChapters(chapters, for: book)
        #endif
        guard var currentBook = manager.currentBook,
            Self.isSameBook(currentBook, book)
        else {
            return
        }
        currentBook.chapters = chapters
        manager.currentBook = currentBook
        changeSignal.send(())
    }

    func refreshNowPlayingInfo() {
        #if os(iOS) && canImport(GoogleCast)
        if let remote {
            remote.refreshNowPlayingInfo()
            return
        }
        #endif
        manager.refreshNowPlayingInfo()
    }

    func resolveConflict(useServer: Bool) {
        manager.resolveConflict(useServer: useServer)
    }

    func dismissConflict() {
        manager.syncConflict = nil
    }

    func playOverlayTracks(
        _ tracks: [AudioTrackInfo],
        book: Book,
        totalDuration: TimeInterval,
        resumeTime: TimeInterval
    ) async throws -> String {
        #if os(iOS) && canImport(GoogleCast)
        if remote != nil { throw CastPlaybackError.readAloudUnsupported }
        #endif
        return try await manager.playOverlayTracks(
            tracks,
            book: book,
            totalDuration: totalDuration,
            resumeTime: resumeTime
        )
    }

    func stopOverlaySession(ifMatching sessionId: String) {
        manager.stopOverlaySession(ifMatching: sessionId)
    }

    func beginPreparation() {
        manager.isLoading = true
        manager.playbackError = nil
    }

    func endPreparation(errorDescription: String?) {
        manager.isLoading = false
        manager.playbackError = errorDescription
    }

    private static func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }
}

@MainActor
final class PlaybackManagerAudioProcessingController: PlaybackAudioProcessingControlling {
    static var shared: PlaybackManagerAudioProcessingController { ProfileSession.owner.playback.audioProcessing }

    private let processor: AudioProcessor

    var eqBands: [Float] {
        processor.bands.map(\.gain)
    }

    init(processor: AudioProcessor = .shared) {
        self.processor = processor
    }

    func apply(_ preferences: UserPreferences) {
        setBasicVoiceMode(preferences.basicVoiceMode)
        setVoiceBoostPreset(preferences.voiceBoostPreset)
        setVoiceBoostEnabled(preferences.voiceBoostEnabled)
        setEQBands(preferences.eqBands)
        setEQEnabled(preferences.eqEnabled)
    }

    func setBasicVoiceMode(_ mode: BasicVoiceMode) {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setMode(mode.audioSessionMode)
        } catch {
            AppLogger.player.error("Failed to set playback voice mode: \(error)")
        }
        #endif
    }

    func setVoiceBoostEnabled(_ enabled: Bool) {
        if enabled {
            if processor.voiceBoostMode == .off {
                processor.voiceBoostMode = .medium
            }
        } else {
            processor.voiceBoostMode = .off
        }
    }

    func setVoiceBoostPreset(_ preset: VoiceBoostPreset) {
        processor.voiceBoostMode = switch preset {
        case .neutral: .off
        case .warm: .low
        case .bright: .medium
        case .voiceBoost: .high
        }
    }

    func setEQEnabled(_ enabled: Bool) {
        if enabled {
            processor.applyPreset(id: processor.currentEQPresetID)
        } else {
            processor.updateBands(EqualizerPreset.flat.bands)
        }
    }

    func setEQBands(_ bands: [Float]) {
        guard !bands.isEmpty else { return }
        let sourceIndices = bands.count >= 10 ? [0, 2, 4, 6, 9] : Array(0..<min(bands.count, 5))
        var normalized = EqualizerPreset.flat.bands
        for (targetIndex, sourceIndex) in sourceIndices.enumerated() where targetIndex < normalized.count {
            normalized[targetIndex].gain = min(max(bands[sourceIndex], -12), 12)
        }
        processor.currentEQPresetID = "custom"
        processor.updateBands(normalized)
    }
}
