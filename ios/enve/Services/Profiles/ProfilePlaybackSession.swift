import Foundation

@MainActor
final class ProfilePlaybackSession {
    private unowned let profileSession: ProfileSession
    let manager: PlaybackManager
    let controller: PlaybackManagerController
    let audioProcessing: PlaybackManagerAudioProcessingController
    let composition: PlaybackComposition
    let linker: EbookAudiobookLinker
    let linkedProgress: LinkedBookProgressCoordinator
    let workProgress: WorkProgressSync
    let storytellerPositions: StorytellerPositionSyncService
    #if os(iOS)
    let mediaOverlay: MediaOverlayPlaybackService
    #endif
    let readAloud: AlignedReadAloudSessionCoordinator
    let readerOpen: ReaderOpenCoordinator
    let chapterService: PlayerChapterService
    let starter: AudiobookPlaybackCoordinator
    #if os(iOS)
    private final class ReaderReference {
        weak var model: ClassicReaderModel?
        init(_ model: ClassicReaderModel) { self.model = model }
    }
    private var readers: [ReaderReference] = []

    func registerReader(_ model: ClassicReaderModel) {
        readers.removeAll { $0.model == nil }
        readers.append(ReaderReference(model))
    }

    #endif
    private var didCreateAutoSleep = false
    lazy var autoSleep: AutoSleepService = {
        didCreateAutoSleep = true
        return AutoSleepService(playback: composition.controller, preferences: profileSession.preferences,
            player: { [unowned self] in self.player })
    }()

    private var didCreatePlayer = false
    private var didCreateEngine = false

    lazy var player: PlayerViewModel = {
        didCreatePlayer = true
        let abs = profileSession.absService
        let sessions = PlayerSessionService(audiobookshelfService: abs, providerConnections: profileSession.providerConnections,
            serverSyncEnabled: { [unowned profileSession] in profileSession.serverSyncEnabled })
        let progress = PlayerProgressService(storageService: profileSession.storageService,
            audiobookshelfService: abs, providerConnections: profileSession.providerConnections, profileSession: profileSession)
        let streams = PlayerStreamURLResolver(audiobookshelfService: abs,
            providerConnections: profileSession.providerConnections, sessionService: sessions,
            progressService: progress, profileSession: profileSession)
        return PlayerViewModel(playbackComposition: composition, storageService: profileSession.storageService,
            providerConnections: profileSession.providerConnections, bookQuerying: profileSession.bookStore,
            readerArtifacts: profileSession.bookStore, libraryCache: profileSession.appState,
            streamResolver: streams, progressService: progress, sessionService: sessions,
            chapterService: chapterService, profileSession: profileSession)
    }()

    lazy var engine: PlaybackEngine = {
        didCreateEngine = true
        return PlaybackEngine(appState: profileSession.appState,
        playbackController: composition.controller, playbackEvents: composition.eventPublisher,
        readerOpen: readerOpen, linkedProgress: linkedProgress, readAloudPlayback: readAloud,
        queueStore: profileSession.playbackQueue, playbackStarter: composition.bookStarter,
        profileSession: profileSession)
    }()

    init(profileSession: ProfileSession) {
        self.profileSession = profileSession
        let manager = PlaybackManager(profileSession: profileSession)
        self.manager = manager
        let controller = PlaybackManagerController(manager: manager)
        self.controller = controller
        let audioProcessing = PlaybackManagerAudioProcessingController(processor: manager.audioProcessor)
        self.audioProcessing = audioProcessing
        let starter = AudiobookPlaybackCoordinator(appState: profileSession.appState, playback: manager, profileSession: profileSession)
        self.starter = starter
        let composition = PlaybackComposition(controller: controller, eventPublisher: controller,
            loader: nil, bookStarter: starter, restorationPreparer: nil, bookMetadataUpdater: controller,
            nowPlayingUpdater: controller, conflictResolver: controller, overlayController: controller,
            preparationReporter: controller, audioProcessing: audioProcessing,
            monoMix: nil, stereoBalance: nil)
        self.composition = composition
        linker = profileSession.ebookLinker
        linkedProgress = LinkedBookProgressCoordinator(profileSession: profileSession)
        workProgress = WorkProgressSync(profileSession: profileSession)
        storytellerPositions = StorytellerPositionSyncService(ledger: StorytellerPositionLedger(defaults: profileSession.defaults),
            providerResolver: profileSession.providerConnections, libraryCache: profileSession.appState.libraryCache,
            serverSyncEnabled: { [unowned profileSession] in profileSession.serverSyncEnabled })
        #if os(iOS)
        mediaOverlay = MediaOverlayPlaybackService(profileSession: profileSession, playbackComposition: composition,
            bookSession: profileSession.appState, libraryCache: profileSession.appState.libraryCache,
            presentation: profileSession.appState.presentation, providerResolver: profileSession.providerConnections,
            bookRepository: profileSession.bookStore)
        #endif
        readAloud = AlignedReadAloudSessionCoordinator(profileSession: profileSession, preparationReporter: composition.preparationReporter)
        readerOpen = ReaderOpenCoordinator(appState: profileSession.appState, downloads: profileSession.downloads,
            linkedProgress: linkedProgress, profileSession: profileSession)
        chapterService = PlayerChapterService(currentBook: { [unowned profileSession] in profileSession.appState.currentBook },
            updateCurrentBook: { [unowned profileSession] in profileSession.appState.currentBook = $0 },
            bookLookup: { [unowned profileSession] in await profileSession.bookStore.book(byAnyId: $0) },
            playbackBookUpdater: { composition.bookMetadataUpdater.updateChapters($1, for: $0) },
            serverBookLookup: { [unowned profileSession] in await profileSession.engine.library.refreshDetails(for: $0) },
            readerArtifacts: profileSession.readerArtifacts, metadataStorage: profileSession.metadataStorage)
    }

    func retire() async {
        if didCreateAutoSleep { autoSleep.retire() }
        #if os(iOS)
        for reader in readers { await reader.model?.retire() }
        readers.removeAll()
        #endif
        await readerOpen.retire()
        await readAloud.retire()
        #if os(iOS)
        await mediaOverlay.retire()
        #endif
        await starter.retire()
        if didCreatePlayer { await player.retire() }
        if didCreateEngine { await engine.retire() }
        await manager.retire()
    }
}
