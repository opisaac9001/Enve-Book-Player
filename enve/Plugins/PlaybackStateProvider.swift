import Combine
import Foundation

struct PlaybackSnapshot {
    let currentBook: Book?
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let playbackSpeed: Double
    let volume: Double
    let isLoaded: Bool
    let isLoading: Bool
    let isOverlayPlaybackActive: Bool
    let errorDescription: String?

    static let idle = PlaybackSnapshot(
        currentBook: nil,
        isPlaying: false,
        position: 0,
        duration: 0,
        playbackSpeed: 1,
        volume: 1,
        isLoaded: false,
        isLoading: false,
        isOverlayPlaybackActive: false,
        errorDescription: nil
    )
}

@MainActor
protocol PlaybackStateProvider: AnyObject {
    var snapshot: PlaybackSnapshot { get }
}

extension PlaybackStateProvider {
    var currentBook: Book? { snapshot.currentBook }
    var isPlaying: Bool { snapshot.isPlaying }
    var progress: TimeInterval { snapshot.position }
    var duration: TimeInterval { snapshot.duration }
    var playbackSpeed: Double { snapshot.playbackSpeed }
}

@MainActor
protocol PlaybackControlling: PlaybackStateProvider {
    var snapshots: AnyPublisher<PlaybackSnapshot, Never> { get }
    var ownsProgressPersistence: Bool { get }

    func play()
    func pause()
    func stop()
    func togglePlay()
    func seek(to time: TimeInterval)
    func skipForward(seconds: TimeInterval)
    func skipBackward(seconds: TimeInterval)
    func setPlaybackRate(_ rate: Double)
    func setVolume(_ volume: Double)
    func fadeOutAndPause(duration: TimeInterval, steps: Int) async
}

enum PlaybackEvent: Equatable, Sendable {
    case completed(Book)
    case failed(Book)
}

@MainActor
protocol PlaybackEventPublishing: AnyObject {
    var playbackEvents: AnyPublisher<PlaybackEvent, Never> { get }
}

@MainActor
protocol PlaybackFailureReporting: AnyObject {
    func reportPlaybackFailure(for book: Book)
}

@MainActor
protocol PlaybackLoading: AnyObject {
    func load(url: URL, book: Book, startingAt: TimeInterval)
    func loadTracks(_ tracks: [AudioTrack], book: Book, startingAt: TimeInterval)
    func setupNowPlaying(book: Book)
    func updateNowPlayingInfo()
}

@MainActor
protocol PlaybackBookMetadataUpdating: AnyObject {
    func updateChapters(_ chapters: [Chapter], for book: Book)
}

@MainActor
protocol PlaybackNowPlayingUpdating: AnyObject {
    func refreshNowPlayingInfo()
}

struct PlaybackProgressConflict: Equatable {
    let local: TimeInterval
    let server: TimeInterval
    let bookId: String
}

@MainActor
protocol PlaybackConflictResolving: AnyObject {
    var conflict: PlaybackProgressConflict? { get }
    var conflicts: AnyPublisher<PlaybackProgressConflict?, Never> { get }

    func resolveConflict(useServer: Bool)
    func dismissConflict()
}

@MainActor
protocol PlaybackOverlayControlling: AnyObject {
    func playOverlayTracks(
        _ tracks: [AudioTrackInfo],
        book: Book,
        totalDuration: TimeInterval,
        resumeTime: TimeInterval
    ) async throws -> String
    func stopOverlaySession(ifMatching sessionId: String)
}

@MainActor
protocol PlaybackPreparationReporting: AnyObject {
    func beginPreparation()
    func endPreparation(errorDescription: String?)
}

@MainActor
protocol RestoredPlaybackPreparing: AnyObject {
    func prewarmRestoredBook(_ book: Book, resumeAt: TimeInterval?)
}

@MainActor
protocol PlaybackAudioProcessingControlling: AnyObject {
    var eqBands: [Float] { get }

    func apply(_ preferences: UserPreferences)
    func setBasicVoiceMode(_ mode: BasicVoiceMode)
    func setVoiceBoostEnabled(_ enabled: Bool)
    func setVoiceBoostPreset(_ preset: VoiceBoostPreset)
    func setEQEnabled(_ enabled: Bool)
    func setEQBands(_ bands: [Float])
}

@MainActor
protocol PlaybackMonoMixControlling: AnyObject {
    func setMonoMixEnabled(_ enabled: Bool)
}

@MainActor
protocol PlaybackStereoBalanceControlling: AnyObject {
    func setStereoBalance(_ balance: Float)
}

@MainActor
struct PlaybackComposition {
    let controller: any PlaybackControlling
    let eventPublisher: any PlaybackEventPublishing
    let loader: (any PlaybackLoading)?
    let bookStarter: any BookPlaybackStarting
    let restorationPreparer: (any RestoredPlaybackPreparing)?
    let bookMetadataUpdater: any PlaybackBookMetadataUpdating
    let nowPlayingUpdater: any PlaybackNowPlayingUpdating
    let conflictResolver: (any PlaybackConflictResolving)?
    let overlayController: (any PlaybackOverlayControlling)?
    let preparationReporter: any PlaybackPreparationReporting
    let audioProcessing: any PlaybackAudioProcessingControlling
    let monoMix: (any PlaybackMonoMixControlling)?
    let stereoBalance: (any PlaybackStereoBalanceControlling)?
}

@MainActor
enum ActivePlayback {
    static let composition: PlaybackComposition = {
        #if os(tvOS)
        let controller = AudioServicePlaybackController.shared
        controller.apply(LibraryDisplayPreferencesStore.shared.loadPreferences())
        let bookStarter = TVBookPlaybackCoordinator(
            controller: controller,
            loader: controller,
            preparationReporter: controller,
            failureReporter: controller,
            providerConnections: AppState.shared.providerConnections,
            bookQuerying: AppState.shared.bookStore,
            libraryCache: AppState.shared
        )
        return PlaybackComposition(
            controller: controller,
            eventPublisher: controller,
            loader: controller,
            bookStarter: bookStarter,
            restorationPreparer: bookStarter,
            bookMetadataUpdater: controller,
            nowPlayingUpdater: controller,
            conflictResolver: bookStarter,
            overlayController: nil,
            preparationReporter: controller,
            audioProcessing: controller,
            monoMix: controller,
            stereoBalance: controller
        )
        #else
        return PlaybackComposition(
            controller: PlaybackManagerController.shared,
            eventPublisher: PlaybackManagerController.shared,
            loader: nil,
            bookStarter: AudiobookPlaybackCoordinator.shared,
            restorationPreparer: nil,
            bookMetadataUpdater: PlaybackManagerController.shared,
            nowPlayingUpdater: PlaybackManagerController.shared,
            conflictResolver: PlaybackManagerController.shared,
            overlayController: PlaybackManagerController.shared,
            preparationReporter: PlaybackManagerController.shared,
            audioProcessing: PlaybackManagerAudioProcessingController.shared,
            monoMix: nil,
            stereoBalance: nil
        )
        #endif
    }()

    static var controller: any PlaybackControlling { composition.controller }
}
