import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioServicePlaybackController: ObservableObject,
    PlaybackControlling,
    PlaybackEventPublishing,
    PlaybackFailureReporting,
    PlaybackLoading,
    PlaybackBookMetadataUpdating,
    PlaybackNowPlayingUpdating,
    PlaybackPreparationReporting,
    PlaybackAudioProcessingControlling,
    PlaybackMonoMixControlling,
    PlaybackStereoBalanceControlling
{
    static let shared = AudioServicePlaybackController()

    private let audioPlayer: AudioService
    private let eventSignal = PassthroughSubject<PlaybackEvent, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var isPreparing = false
    private var preparationError: String?
    private var reportedFailureBookID: String?

    let ownsProgressPersistence = false

    @Published private(set) var snapshot: PlaybackSnapshot

    var snapshots: AnyPublisher<PlaybackSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }

    var playbackEvents: AnyPublisher<PlaybackEvent, Never> {
        eventSignal.eraseToAnyPublisher()
    }

    var isReady: Bool { audioPlayer.isReady }
    var eqBands: [Float] { audioPlayer.eqBands }

    init(audioPlayer: AudioService = .shared) {
        self.audioPlayer = audioPlayer
        self.snapshot = Self.makeSnapshot(audioPlayer: audioPlayer, currentBook: nil)
        setupObservers()
    }

    private func setupObservers() {
        Publishers.MergeMany([
            audioPlayer.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            audioPlayer.$currentTime.map { _ in () }.eraseToAnyPublisher(),
            audioPlayer.$duration.map { _ in () }.eraseToAnyPublisher(),
            audioPlayer.$playbackRate.map { _ in () }.eraseToAnyPublisher(),
            audioPlayer.$volume.map { _ in () }.eraseToAnyPublisher(),
            audioPlayer.$isReady.map { _ in () }.eraseToAnyPublisher(),
            audioPlayer.$error.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.publishSnapshot() }
        .store(in: &cancellables)

        audioPlayer.playbackDidFinishSubject
            .sink { [weak self] finishedBookId in
                guard let self, let book = self.snapshot.currentBook, book.id == finishedBookId else { return }
                self.eventSignal.send(.completed(book))
            }
            .store(in: &cancellables)

        audioPlayer.$error
            .sink { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.reportedFailureBookID = nil
                } else if let book = self.snapshot.currentBook {
                    self.reportPlaybackFailure(for: book)
                }
            }
            .store(in: &cancellables)
    }

    func reportPlaybackFailure(for book: Book) {
        guard reportedFailureBookID != book.uniqueId else { return }
        reportedFailureBookID = book.uniqueId
        eventSignal.send(.failed(book))
    }

    func load(url: URL, book: Book, startingAt: TimeInterval) {
        snapshot = Self.makeSnapshot(
            audioPlayer: audioPlayer,
            currentBook: book,
            isPreparing: isPreparing,
            preparationError: preparationError
        )
        audioPlayer.load(url: url, bookId: book.id, startingAt: startingAt)
    }

    func loadTracks(_ tracks: [AudioTrack], book: Book, startingAt: TimeInterval) {
        snapshot = Self.makeSnapshot(
            audioPlayer: audioPlayer,
            currentBook: book,
            isPreparing: isPreparing,
            preparationError: preparationError
        )
        audioPlayer.loadTracks(tracks, bookId: book.id, startingAt: startingAt)
    }

    func play() {
        audioPlayer.play()
    }

    func togglePlay() {
        audioPlayer.togglePlay()
    }

    func pause() {
        audioPlayer.pause()
    }

    func stop() {
        audioPlayer.pause()
    }

    func seek(to time: TimeInterval) {
        audioPlayer.seek(to: time)
    }

    func skipForward(seconds: TimeInterval) {
        audioPlayer.skipForward(seconds: seconds)
    }

    func skipBackward(seconds: TimeInterval) {
        audioPlayer.skipBackward(seconds: seconds)
    }

    func setPlaybackRate(_ rate: Double) {
        audioPlayer.setPlaybackRate(rate)
        publishSnapshot()
    }

    func setVolume(_ volume: Double) {
        audioPlayer.setVolume(volume)
        publishSnapshot()
    }

    func fadeOutAndPause(duration: TimeInterval, steps: Int) async {
        let safeSteps = max(1, steps)
        let originalVolume = audioPlayer.volume
        let stepDelay = duration / Double(safeSteps)
        for step in stride(from: safeSteps, through: 1, by: -1) {
            audioPlayer.setVolume(originalVolume * Double(step) / Double(safeSteps))
            try? await Task.sleep(for: .seconds(stepDelay))
        }
        audioPlayer.pause()
        audioPlayer.setVolume(originalVolume)
    }

    func apply(_ preferences: UserPreferences) {
        setBasicVoiceMode(preferences.basicVoiceMode)
        setMonoMixEnabled(preferences.monoMixEnabled)
        audioPlayer.setIndependentPitchSemitones(preferences.independentPitchSemitones)
        setStereoBalance(preferences.stereoBalance)
        audioPlayer.setNoiseReductionLevel(preferences.noiseReductionLevel)
        audioPlayer.setBinauralEnabled(preferences.binauralEnabled)
        setEQBands(preferences.eqBands)
        setVoiceBoostPreset(preferences.voiceBoostPreset)
        setVoiceBoostEnabled(preferences.voiceBoostEnabled)
        setEQEnabled(preferences.eqEnabled)
    }

    func setBasicVoiceMode(_ mode: BasicVoiceMode) {
        audioPlayer.setBasicVoiceMode(mode)
    }

    func setVoiceBoostEnabled(_ enabled: Bool) {
        audioPlayer.setVoiceBoostEnabled(enabled)
    }

    func setVoiceBoostPreset(_ preset: VoiceBoostPreset) {
        audioPlayer.setVoiceBoostPreset(preset)
    }

    func setEQEnabled(_ enabled: Bool) {
        audioPlayer.setEQEnabled(enabled)
    }

    func setMonoMixEnabled(_ enabled: Bool) {
        audioPlayer.setMonoMixEnabled(enabled)
    }

    func setIndependentPitchSemitones(_ semitones: Float) {
        audioPlayer.setIndependentPitchSemitones(Double(semitones))
    }

    func setStereoBalance(_ balance: Float) {
        audioPlayer.setStereoBalance(balance)
    }

    func setNoiseReductionLevel(_ level: Float) {
        audioPlayer.setNoiseReductionLevel(level)
    }

    func setBinauralEnabled(_ enabled: Bool) {
        audioPlayer.setBinauralEnabled(enabled)
    }

    func setEQBands(_ bands: [Float]) {
        audioPlayer.setEQBands(bands)
    }

    func setupNowPlaying(book: Book) {
        snapshot = Self.makeSnapshot(
            audioPlayer: audioPlayer,
            currentBook: book,
            isPreparing: isPreparing,
            preparationError: preparationError
        )
        audioPlayer.setupNowPlaying(book: book)
    }

    func updateNowPlayingInfo() {
        audioPlayer.updateNowPlayingInfo()
    }

    func refreshNowPlayingInfo() {
        audioPlayer.updateNowPlayingInfo()
    }

    func beginPreparation() {
        isPreparing = true
        preparationError = nil
        reportedFailureBookID = nil
        publishSnapshot()
    }

    func endPreparation(errorDescription: String?) {
        isPreparing = false
        preparationError = errorDescription
        publishSnapshot()
    }

    func updateChapters(_ chapters: [Chapter], for book: Book) {
        guard var currentBook = snapshot.currentBook,
            Self.isSameBook(currentBook, book)
        else {
            return
        }
        currentBook.chapters = chapters
        snapshot = Self.makeSnapshot(audioPlayer: audioPlayer, currentBook: currentBook)
    }

    private func publishSnapshot() {
        snapshot = Self.makeSnapshot(
            audioPlayer: audioPlayer,
            currentBook: snapshot.currentBook,
            isPreparing: isPreparing,
            preparationError: preparationError
        )
    }

    private static func makeSnapshot(
        audioPlayer: AudioService,
        currentBook: Book?,
        isPreparing: Bool = false,
        preparationError: String? = nil
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            currentBook: currentBook,
            isPlaying: audioPlayer.isPlaying,
            position: audioPlayer.currentTime,
            duration: audioPlayer.duration,
            playbackSpeed: audioPlayer.playbackRate,
            volume: audioPlayer.volume,
            isLoaded: audioPlayer.isReady,
            isLoading: isPreparing || (!audioPlayer.isReady && audioPlayer.currentBookId != nil),
            isOverlayPlaybackActive: false,
            errorDescription: preparationError ?? audioPlayer.error?.localizedDescription
        )
    }

    private static func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }
}
