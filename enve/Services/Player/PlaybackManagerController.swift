import AVFoundation
import Combine
import Foundation
import Logging

@MainActor
final class PlaybackManagerController: PlaybackControlling, PlaybackEventPublishing, PlaybackFailureReporting,
    PlaybackBookMetadataUpdating, PlaybackNowPlayingUpdating, PlaybackConflictResolving,
    PlaybackOverlayControlling, PlaybackPreparationReporting
{
    static let shared = PlaybackManagerController()

    private let manager: PlaybackManager
    private let changeSignal = PassthroughSubject<Void, Never>()
    private let eventSignal = PassthroughSubject<PlaybackEvent, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var reportedFailureBookID: String?

    let ownsProgressPersistence = true

    var snapshot: PlaybackSnapshot {
        PlaybackSnapshot(
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

    init(manager: PlaybackManager = .shared) {
        self.manager = manager

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
        manager.play()
    }

    func pause() {
        manager.pause()
    }

    func stop() {
        manager.stop()
    }

    func togglePlay() {
        manager.isPlaying ? manager.pause() : manager.play()
    }

    func seek(to time: TimeInterval) {
        manager.seek(to: time)
    }

    func skipForward(seconds: TimeInterval) {
        manager.skipForward(seconds: seconds)
    }

    func skipBackward(seconds: TimeInterval) {
        manager.skipBackward(seconds: seconds)
    }

    func setPlaybackRate(_ rate: Double) {
        manager.setPlaybackSpeed(Float(rate))
    }

    func setVolume(_ volume: Double) {
        manager.setOutputVolume(Float(volume))
        changeSignal.send(())
    }

    func fadeOutAndPause(duration: TimeInterval, steps: Int) async {
        await manager.fadeOutAndPause(duration: duration, steps: steps)
    }

    func updateChapters(_ chapters: [Chapter], for book: Book) {
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
        try await manager.playOverlayTracks(
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
    static let shared = PlaybackManagerAudioProcessingController()

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
