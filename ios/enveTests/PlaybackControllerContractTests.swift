import Combine
import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized)
struct PlaybackControllerContractTests {
    @Test func playbackManagerAdapterProjectsAuthoritativeStateWithoutViewModelRefresh() {
        let manager = PlaybackManager.shared
        let originalBook = manager.currentBook
        let originalPlaying = manager.isPlaying
        let originalTime = manager.currentTime
        let originalDuration = manager.duration
        let originalSpeed = manager.playbackSpeed
        defer {
            manager.currentBook = originalBook
            manager.isPlaying = originalPlaying
            manager.currentTime = originalTime
            manager.duration = originalDuration
            manager.playbackSpeed = originalSpeed
        }

        let book = makeBook()
        manager.currentBook = book
        manager.isPlaying = true
        manager.currentTime = 123
        manager.duration = 900
        manager.playbackSpeed = 1.35

        let controller = PlaybackManagerController(manager: manager)

        #expect(controller.currentBook?.stableId == book.stableId)
        #expect(controller.isPlaying)
        #expect(controller.progress == 123)
        #expect(controller.duration == 900)
        #expect(controller.playbackSpeed == Double(Float(1.35)))
        #expect(controller.ownsProgressPersistence)
    }

    @Test func playbackManagerAdapterRoutesRateCommands() {
        let manager = PlaybackManager.shared
        let originalSpeed = manager.playbackSpeed
        defer { manager.playbackSpeed = originalSpeed }

        let controller = PlaybackManagerController(manager: manager)
        controller.setPlaybackRate(1.75)

        #expect(manager.playbackSpeed == 1.75)
        #expect(controller.snapshot.playbackSpeed == 1.75)
    }

    @Test func playbackManagerAdapterPublishesLoadingStateChanges() {
        let manager = PlaybackManager.shared
        let originalLoading = manager.isLoading
        defer { manager.isLoading = originalLoading }

        let controller = PlaybackManagerController(manager: manager)
        var states: [Bool] = []
        let subscription = controller.snapshots.sink { states.append($0.isLoading) }

        manager.isLoading = !originalLoading

        #expect(states.last == !originalLoading)
        withExtendedLifetime(subscription) {}
    }

    @Test func playbackManagerAdapterOwnsLoadedBookChapterUpdates() {
        let manager = PlaybackManager.shared
        let originalBook = manager.currentBook
        defer { manager.currentBook = originalBook }

        let book = makeBook()
        manager.currentBook = book
        let controller = PlaybackManagerController(manager: manager)
        let chapters = [
            Chapter(id: "chapter", start: 0, end: 900, title: "Chapter")
        ]

        controller.updateChapters(chapters, for: book)

        #expect(manager.currentBook?.chapters == chapters)
        #expect(controller.snapshot.currentBook?.chapters == chapters)
    }

    @Test func playbackManagerAdapterOwnsPreparationAndConflictState() {
        let manager = PlaybackManager.shared
        let originalLoading = manager.isLoading
        let originalError = manager.playbackError
        let originalConflict = manager.syncConflict
        defer {
            manager.isLoading = originalLoading
            manager.playbackError = originalError
            manager.syncConflict = originalConflict
        }

        let controller = PlaybackManagerController(manager: manager)
        controller.beginPreparation()
        #expect(controller.snapshot.isLoading)
        #expect(controller.snapshot.errorDescription == nil)

        controller.endPreparation(errorDescription: "fixture failure")
        #expect(!controller.snapshot.isLoading)
        #expect(controller.snapshot.errorDescription == "fixture failure")

        manager.syncConflict = (local: 10, server: 20, bookId: "book")
        #expect(controller.conflict == PlaybackProgressConflict(local: 10, server: 20, bookId: "book"))
        controller.dismissConflict()
        #expect(controller.conflict == nil)
    }

    @Test func playbackManagerAdapterRepublishesEngineCompletion() {
        let manager = PlaybackManager.shared
        let controller = PlaybackManagerController(manager: manager)
        let book = makeBook()
        var events: [PlaybackEvent] = []
        let subscription = controller.playbackEvents.sink { events.append($0) }

        manager.playbackCompletionSubject.send(book)

        #expect(events == [.completed(book)])
        withExtendedLifetime(subscription) {}
    }

    @Test func playbackManagerAdapterReportsFailureAgainstTheLoadedBook() {
        let manager = PlaybackManager.shared
        let originalBook = manager.currentBook
        let originalError = manager.playbackError
        defer {
            manager.currentBook = originalBook
            manager.playbackError = originalError
        }

        let book = makeBook()
        manager.currentBook = book
        manager.playbackError = nil

        let controller = PlaybackManagerController(manager: manager)
        var events: [PlaybackEvent] = []
        let subscription = controller.playbackEvents.sink { events.append($0) }

        manager.playbackError = "fixture failure"
        manager.playbackError = "fixture failure"

        #expect(events == [.failed(book)])
        withExtendedLifetime(subscription) {}
    }

    @Test func audioServiceAdapterProjectsRateAndVolumeThroughTheSameContract() {
        let audioService = AudioService.shared
        let originalRate = audioService.playbackRate
        let originalVolume = audioService.volume
        defer {
            audioService.setPlaybackRate(originalRate)
            audioService.setVolume(originalVolume)
        }

        let controller = AudioServicePlaybackController(audioPlayer: audioService)
        controller.setPlaybackRate(1.4)
        controller.setVolume(0.6)

        #expect(controller.playbackSpeed == 1.4)
        #expect(controller.snapshot.volume == 0.6)
        #expect(!controller.ownsProgressPersistence)
    }

    @Test func audioServiceAdapterOwnsLoadedBookChapterUpdates() {
        let controller = AudioServicePlaybackController(audioPlayer: .shared)
        let book = makeBook()
        let chapters = [
            Chapter(id: "chapter", start: 0, end: 900, title: "Chapter")
        ]
        controller.setupNowPlaying(book: book)

        controller.updateChapters(chapters, for: book)

        #expect(controller.snapshot.currentBook?.chapters == chapters)
    }

    @Test func audioServiceAdapterPublishesPreparationState() {
        let controller = AudioServicePlaybackController(audioPlayer: .shared)
        let book = makeBook()

        controller.beginPreparation()
        #expect(controller.snapshot.isLoading)
        #expect(controller.snapshot.errorDescription == nil)

        controller.setupNowPlaying(book: book)
        #expect(controller.snapshot.isLoading)
        #expect(controller.snapshot.errorDescription == nil)

        controller.endPreparation(errorDescription: "fixture failure")
        #expect(!controller.snapshot.isLoading)
        #expect(controller.snapshot.errorDescription == "fixture failure")
    }

    @Test func audioServiceAdapterRepublishesEndOfPlaybackForTheLoadedBook() {
        let audioService = AudioService.shared
        let controller = AudioServicePlaybackController(audioPlayer: audioService)
        let book = makeBook()
        controller.setupNowPlaying(book: book)
        var events: [PlaybackEvent] = []
        let subscription = controller.playbackEvents.sink { events.append($0) }

        audioService.playbackDidFinishSubject.send("a-different-book")
        #expect(events.isEmpty)

        audioService.playbackDidFinishSubject.send(book.id)

        #expect(events == [.completed(book)])
        withExtendedLifetime(subscription) {}
    }

    @Test func audioServiceAdapterReportsExplicitFailureOncePerAttempt() {
        let controller = AudioServicePlaybackController(audioPlayer: .shared)
        let book = makeBook()
        var events: [PlaybackEvent] = []
        let subscription = controller.playbackEvents.sink { events.append($0) }

        controller.beginPreparation()
        controller.endPreparation(errorDescription: nil)
        #expect(events.isEmpty)

        controller.setupNowPlaying(book: book)
        controller.beginPreparation()
        controller.reportPlaybackFailure(for: book)
        controller.reportPlaybackFailure(for: book)

        #expect(events == [.failed(book)])
        withExtendedLifetime(subscription) {}
    }

    @Test func activeCompositionReportsStateAndTerminalEventsFromOneEngine() {
        #expect(ActivePlayback.composition.controller === ActivePlayback.composition.eventPublisher)
        #expect(ActivePlayback.controller === ActivePlayback.composition.controller)
    }

    @Test func activeCompositionSelectsPlaybackManagerAdapters() {
        #expect(ActivePlayback.controller is PlaybackManagerController)
        #expect(ActivePlayback.composition.eventPublisher is PlaybackManagerController)
        #expect(ActivePlayback.composition.loader == nil)
        #expect(ActivePlayback.composition.bookStarter is AudiobookPlaybackCoordinator)
        #expect(ActivePlayback.composition.restorationPreparer == nil)
        #expect(ActivePlayback.composition.bookMetadataUpdater is PlaybackManagerController)
        #expect(ActivePlayback.composition.nowPlayingUpdater is PlaybackManagerController)
        #expect(ActivePlayback.composition.conflictResolver is PlaybackManagerController)
        #expect(ActivePlayback.composition.overlayController is PlaybackManagerController)
        #expect(ActivePlayback.composition.preparationReporter is PlaybackManagerController)
        #expect(ActivePlayback.composition.audioProcessing is PlaybackManagerAudioProcessingController)
        #expect(ActivePlayback.composition.monoMix == nil)
        #expect(ActivePlayback.composition.stereoBalance == nil)
    }

    @Test func playbackManagerAudioAdapterRoutesVoiceBoostToTheActiveProcessor() {
        let processor = AudioProcessor.shared
        let originalMode = processor.voiceBoostMode
        defer { processor.voiceBoostMode = originalMode }
        let controller = PlaybackManagerAudioProcessingController(processor: processor)

        controller.setVoiceBoostEnabled(false)
        #expect(processor.voiceBoostMode == .off)

        controller.setVoiceBoostPreset(.voiceBoost)
        #expect(processor.voiceBoostMode == .high)
    }

    private func makeBook() -> Book {
        Book(
            id: "playback-contract-book",
            title: "Playback Contract",
            duration: 900,
            providerId: UUID(),
            libraryId: "tests"
        )
    }
}
