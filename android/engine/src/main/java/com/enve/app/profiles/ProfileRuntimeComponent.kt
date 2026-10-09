package com.enve.app.profiles

import dagger.BindsInstance
import dagger.Component
import javax.inject.Singleton

@Singleton
@Component(
    modules = [
        ProfileRuntimeModule::class,
        com.enve.app.di.AppModule::class,
        com.enve.app.di.AudiobookDownloadModule::class,
        com.enve.app.data.auth.AuthHeaderStrategyModule::class,
        com.enve.app.data.auth.PasswordLoginModule::class,
        com.enve.app.data.provider.ProviderAdapterModule::class,
        com.enve.app.data.sync.ProviderSyncStrategyModule::class,
        com.enve.app.data.history.HistorySessionModule::class,
        com.enve.app.data.metadata.MetadataNetworkModule::class,
        com.enve.app.hearth.FacadeModule::class,
        com.enve.app.readium.ReaderNarrationModule::class,
        com.enve.audiobookshelf.di.AudiobookshelfModule::class,
        com.enve.storyteller.di.StorytellerModule::class,
        com.enve.komga.di.KomgaModule::class,
        com.enve.local.di.LocalModule::class,
        com.enve.plex.di.PlexModule::class,
        com.enve.bookorbit.di.BookOrbitModule::class,
        com.enve.silo.di.SiloModule::class,
    ],
)
interface ProfileRuntimeComponent {
    fun serverSync(): com.enve.core.data.local.ProfileServerSyncStore
    fun resources(): ProfileResources
    fun library(): com.enve.engine.library.LibraryFacade
    fun savedBooks(): com.enve.engine.library.SavedBooksFacade
    fun playback(): com.enve.engine.playback.PlaybackFacade
    fun playerSession(): com.enve.engine.playback.PlayerSessionFacade
    fun preferencesFacade(): com.enve.engine.prefs.PreferencesFacade
    fun sources(): com.enve.engine.sources.SourcesFacade
    fun collections(): com.enve.engine.collections.CollectionsFacade
    fun annotations(): com.enve.engine.annotations.AnnotationsFacade
    fun batchMatching(): com.enve.engine.matching.BatchMatchingFacade
    fun duplicateMatching(): com.enve.engine.matching.DuplicateMatchingFacade
    fun discover(): com.enve.engine.discover.DiscoverFacade
    fun opdsCatalog(): com.enve.engine.opds.OpdsCatalogFacade
    fun podcasts(): com.enve.engine.podcasts.PodcastsFacade
    fun storyAlign(): com.enve.engine.storyalign.StoryAlignFacade
    fun bookOrbit(): com.enve.engine.bookorbit.BookOrbitFacade
    fun serverTools(): com.enve.engine.servertools.ServerToolsFacade
    fun storageLocations(): com.enve.core.data.local.ProfileStorageLocations
    fun database(): com.enve.app.data.local.ReaderDatabase
    fun vault(): com.enve.core.auth.CredentialVault
    fun preferences(): com.enve.core.data.local.PreferencesManager
    fun connections(): com.enve.core.data.local.ConnectionRegistry
    fun mtlsManager(): com.enve.app.auth.MtlsManager
    fun hearthPreferences(): com.enve.app.hearth.HearthPreferencesStore
    fun history(): com.enve.app.data.history.HistorySessionStore
    fun audioStorage(): com.enve.app.data.offline.OfflineAudioStorage
    fun comicStorage(): com.enve.app.data.offline.ComicOfflineStorage
    fun bookmarks(): com.enve.app.playback.PlayerBookmarkService
    fun lastOpenedBookStore(): com.enve.core.data.local.LastOpenedBookStore
    fun keepNextOfflineStore(): com.enve.core.data.local.KeepNextOfflineStore
    fun audiobookGroupingOverrideStore(): com.enve.core.data.local.AudiobookGroupingOverrideStore
    fun syncedItemAudioTimeStore(): com.enve.core.data.local.SyncedItemAudioTimeStore
    fun volumeLevelingStore(): com.enve.core.data.local.VolumeLevelingStore
    fun comicReadingDirectionOverrideStore(): com.enve.core.data.local.ComicReadingDirectionOverrideStore
    fun podcastFeedProgressStore(): com.enve.core.data.local.PodcastFeedProgressStore
    fun hearthDismissedShelfStore(): com.enve.core.data.local.HearthDismissedShelfStore
    fun podcastSubscriptionStore(): com.enve.app.data.podcasts.PodcastSubscriptionStore
    fun duplicateGroupStore(): com.enve.app.data.duplicates.DuplicateGroupStore
    fun absLocalListeningStore(): com.enve.audiobookshelf.listening.AbsLocalListeningStore
    fun httpClient(): okhttp3.OkHttpClient
    fun imageLoader(): coil.ImageLoader
    fun aggregator(): com.enve.app.data.repository.AggregatorRepository
    fun libraryCache(): com.enve.app.data.repository.LibraryCacheRepository
    fun syncCoordinator(): com.enve.app.data.sync.SyncCoordinator
    fun syncManager(): com.enve.app.data.repository.SyncManager
    fun downloads(): com.enve.app.data.offline.OfflineDownloadManager
    fun comicDownloads(): com.enve.app.data.offline.ComicOfflineService
    fun audioPlayback(): com.enve.app.playback.AudioPlaybackManager
    fun sessions(): com.enve.app.playback.PlayerSessionService
    fun playbackQueue(): com.enve.app.playback.PlaybackQueueCoordinator
    fun readAloud(): com.enve.app.readium.ReadAloudPlaybackCoordinator
    fun readAloudCheckpoints(): com.enve.app.readium.ReadAloudCheckpointRepository
    fun readium(): com.enve.app.readium.ReadiumManager

    fun audioEffectsManager(): com.enve.app.playback.AudioEffectsManager
    fun chapterStore(): com.enve.app.playback.PlaybackChapterStore
    fun autoBrowserHelper(): com.enve.app.playback.AutoMediaBrowserHelper
    fun castStreamResolver(): com.enve.app.playback.CastStreamResolver
    fun localCastServer(): com.enve.app.playback.LocalCastServer
    fun progressService(): com.enve.app.playback.PlayerProgressService
    @com.enve.core.di.RefreshClient fun unauthenticatedHttpClient(): okhttp3.OkHttpClient

    fun koReaderHubService(): com.enve.app.data.sync.KOReaderHubService
    fun bookLinks(): com.enve.app.data.links.BookLinkRepository
    fun bookCacheDao(): com.enve.core.data.local.BookCacheDao
    fun obsidianExportService(): com.enve.app.data.obsidian.ObsidianExportService
    fun annotationRepository(): com.enve.app.data.repository.AnnotationRepository
    fun grimmoryAppRepository(): com.enve.app.data.repository.GrimmoryAppRepository
    fun komgaRepository(): com.enve.komga.KomgaRepository
    fun audiobookshelfRepository(): com.enve.audiobookshelf.AudiobookshelfRepository
    fun opdsRepository(): com.enve.app.data.repository.OpdsRepository
    fun storytellerRepository(): com.enve.storyteller.StorytellerRepository
    fun bookOrbitRepository(): com.enve.bookorbit.BookOrbitRepository
    fun libraryListResolver(): com.enve.app.data.repository.LibraryListResolver
    fun libraryMetadataRefreshRepository(): com.enve.app.data.metadata.LibraryMetadataRefreshRepository
    fun grimmoryRepository(): com.enve.app.data.repository.GrimmoryRepository
    fun keepNextOfflineService(): com.enve.app.data.offline.KeepNextOfflineService
    fun playerChapterService(): com.enve.app.playback.PlayerChapterService
    fun embeddedChapterExtractor(): com.enve.app.playback.EmbeddedChapterExtractor
    fun playerSleepTimerService(): com.enve.app.playback.PlayerSleepTimerService
    fun tagIndexStore(): com.enve.app.data.repository.TagIndexStore
    fun bookOrbitHistorySessionSync(): com.enve.bookorbit.sync.BookOrbitHistorySessionSync
    fun einkManager(): com.enve.app.eink.EinkManager
    fun remoteRewindTracker(): com.enve.app.data.sync.RemoteRewindTracker
    fun vocabRepository(): com.enve.app.data.repository.VocabRepository
    fun customFontRepository(): com.enve.app.data.repository.CustomFontRepository
    fun definitionLookupService(): com.enve.app.data.vocab.DefinitionLookupService
    fun readerNarrationStore(): com.enve.app.readium.ReaderNarrationStore
    fun epubBridgeCheckpointStore(): com.enve.app.data.reader.EpubBridgeCheckpointStore
    fun ebookSearchService(): com.enve.app.data.reader.search.EbookSearchService
    fun readerSearchPreferences(): com.enve.app.data.reader.ReaderSearchPreferences
    fun installedDictionariesStore(): com.enve.app.data.vocab.InstalledDictionariesStore
    fun storytellerHubRepository(): com.enve.storyteller.StorytellerHubRepository
    fun hardcoverService(): com.enve.app.data.hardcover.HardcoverService
    fun recentlyPlayedSyncService(): com.enve.app.data.sync.RecentlyPlayedSyncService
    fun bookloreKoreaderSink(): com.enve.app.data.sync.BookloreKoreaderSink
    fun siloRepository(): com.enve.silo.SiloRepository
    fun ebookContextService(): com.enve.app.data.librarian.EbookContextService
    fun enveLibrarianService(): com.enve.app.data.librarian.EnveLibrarianService
    fun librarianEngineManager(): com.enve.app.data.librarian.LibrarianEngineManager
    fun librarianConversationStore(): com.enve.app.data.librarian.LibrarianConversationStore
    fun serverPageStreamingService(): com.enve.app.data.reader.ServerPageStreamingService
    fun libraryCacheDao(): com.enve.core.data.local.LibraryCacheDao
    fun einkFacade(): com.enve.engine.eink.EinkFacade
    fun sleepDataFacade(): com.enve.engine.sleep.SleepDataFacade
    fun jellyfinRepository(): com.enve.app.data.repository.JellyfinRepository
    fun plexPinAuthService(): com.enve.plex.auth.PlexPinAuthService
    fun plexPinAuthFlow(): com.enve.plex.auth.PlexPinAuthFlow
    fun jellyfinQuickConnectFlow(): com.enve.app.data.jellyfin.JellyfinQuickConnectFlow
    fun grimmoryOidcFlow(): com.enve.app.data.grimmory.auth.GrimmoryOidcFlow
    fun absOidcFlow(): com.enve.audiobookshelf.auth.AbsOidcFlow
    fun komgaOAuthFlow(): com.enve.komga.auth.KomgaOAuthFlow
    fun bookOrbitOidcFlow(): com.enve.bookorbit.auth.BookOrbitOidcFlow
    fun passwordLogins(): Map<com.enve.core.data.model.BookSource, @JvmSuppressWildcards com.enve.core.data.auth.PasswordLogin>

    fun epdRefreshManager(): com.enve.app.eink.EpdRefreshManager
    fun playbackOpenProgressResolver(): com.enve.app.playback.PlaybackOpenProgressResolver

    fun progressConflictPassageService(): com.enve.app.data.sync.ProgressConflictPassageService

    fun pendingProgressReplay(): com.enve.app.data.sync.PendingProgressReplay

    fun storyAlignJobScheduler(): com.enve.app.storyalign.StoryAlignJobScheduler
    fun storyAlignJobRepository(): com.enve.app.storyalign.StoryAlignJobRepository
    fun storyAlignGenerator(): com.enve.app.storyalign.StoryAlignGenerator

    @Component.Factory
    interface Factory {
        fun create(@BindsInstance resources: ProfileResources): ProfileRuntimeComponent
    }
}
