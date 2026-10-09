import Foundation

@MainActor
@Observable
final class EnveEngine {
    static var shared: EnveEngine { ProfileSession.owner.engine }

    private unowned let profileSession: ProfileSession?
    let library: LibraryEngine
    let downloads: DownloadsEngine
    let playback: PlaybackEngine
    let readerOpen: ReaderOpenCoordinator
    let sync: SyncEngine
    let sources: SourcesEngine
    let maintenance: MaintenanceEngine
    let journal: JournalEngine
    let matches: MatchesEngine
    let vocabulary: VocabularyEngine
    let podcasts: PodcastsEngine
    let keepNextOffline: KeepNextOfflineService
    let podcastAutoQueue: PodcastAutoQueueService

    #if !os(tvOS)
    @available(iOS 26.0, *)
    var storyAlign: StoryAlignEngine {
        StoryAlignEngine(
            appState: profileSession?.appState ?? .shared,
            catalog: profileSession?.catalog ?? .shared,
            service: (profileSession?.isOwner ?? true) ? (profileSession?.storyAlignService ?? .shared) : nil,
            isAvailable: profileSession?.isOwner ?? true,
            profileSession: profileSession
        )
    }
    #endif

    convenience init(profileSession: ProfileSession) {
        let session = profileSession
        self.init(
            library: LibraryEngine(profileSession: session, appState: session.appState, catalog: session.catalog, progressStore: session.progress, recovery: session.recovery),
            downloads: DownloadsEngine(profileSession: session, service: session.downloads, appState: session.appState),
            playback: session.playback.engine,
            sync: SyncEngine(appState: session.appState, coordinator: session.sync),
            sources: SourcesEngine(profileSession: session, appState: session.appState, catalog: session.catalog),
            maintenance: MaintenanceEngine(profileSession: session, appState: session.appState, recovery: session.recovery),
            journal: JournalEngine(profileSession: session, appState: session.appState),
            matches: MatchesEngine(profileSession: session, appState: session.appState, recovery: session.recovery),
            vocabulary: VocabularyEngine(appState: session.appState),
            podcasts: PodcastsEngine(profileSession: session, appState: session.appState, subscriptionStore: session.podcastSubscriptions),
            readerOpen: session.playback.readerOpen, profileSession: session
        )
    }

    func retire() async {
        await keepNextOffline.retire()
        podcastAutoQueue.retire()
    }

    private init(
        library: LibraryEngine = LibraryEngine(),
        downloads: DownloadsEngine = DownloadsEngine(),
        playback: PlaybackEngine = PlaybackEngine(),
        sync: SyncEngine = SyncEngine(),
        sources: SourcesEngine = SourcesEngine(),
        maintenance: MaintenanceEngine = MaintenanceEngine(),
        journal: JournalEngine = JournalEngine(),
        matches: MatchesEngine = MatchesEngine(),
        vocabulary: VocabularyEngine = VocabularyEngine(),
        podcasts: PodcastsEngine = PodcastsEngine(),
        readerOpen: ReaderOpenCoordinator = .shared,
        profileSession: ProfileSession? = nil
    ) {
        self.profileSession = profileSession
        self.library = library
        self.downloads = downloads
        self.playback = playback
        self.readerOpen = readerOpen
        self.sync = sync
        self.sources = sources
        self.maintenance = maintenance
        self.journal = journal
        self.matches = matches
        self.vocabulary = vocabulary
        self.podcasts = podcasts
        self.keepNextOffline = KeepNextOfflineService(profileSession: profileSession, downloads: downloads, appState: profileSession?.appState ?? .shared, playback: profileSession?.playback.composition.controller ?? ActivePlayback.controller)
        self.podcastAutoQueue = PodcastAutoQueueService(profileSession: profileSession, queue: playback.queue.store)
    }
}
