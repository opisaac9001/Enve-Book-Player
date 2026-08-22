import Foundation

@MainActor
@Observable
final class EnveEngine {
    static let shared = EnveEngine()

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
        StoryAlignEngine.shared
    }
    #endif

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
        podcasts: PodcastsEngine = PodcastsEngine()
    ) {
        self.library = library
        self.downloads = downloads
        self.playback = playback
        self.readerOpen = .shared
        self.sync = sync
        self.sources = sources
        self.maintenance = maintenance
        self.journal = journal
        self.matches = matches
        self.vocabulary = vocabulary
        self.podcasts = podcasts
        self.keepNextOffline = KeepNextOfflineService(downloads: downloads)
        self.podcastAutoQueue = PodcastAutoQueueService(queue: playback.queue.store)
    }
}
