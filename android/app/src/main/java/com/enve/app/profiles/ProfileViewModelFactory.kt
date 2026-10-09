package com.enve.app.profiles

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.CreationExtras

class ProfileViewModelFactory(private val component: com.enve.app.profiles.ProfileRuntimeComponent) : ViewModelProvider.Factory {
    private val jobs = mutableSetOf<Job>()
    private var retired = false

    suspend fun retire() {
        retired = true
        val captured = jobs.toList()
        captured.forEach { it.cancel() }
        captured.forEach { it.cancelAndJoin() }
        jobs.clear()
    }

    override fun <T : ViewModel> create(modelClass: Class<T>): T = create(modelClass, CreationExtras.Empty)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
        check(!retired)
        val model = when (modelClass) {
        com.enve.app.viewmodel.KOReaderHubViewModel::class.java -> com.enve.app.viewmodel.KOReaderHubViewModel(
            component.koReaderHubService(),
            component.bookCacheDao(),
            component.preferences(),
        )
        com.enve.app.viewmodel.StorageHubViewModel::class.java -> com.enve.app.viewmodel.StorageHubViewModel(
            component.storageLocations(),
            component.downloads(),
            component.comicDownloads(),
        )
        com.enve.app.viewmodel.ObsidianSyncViewModel::class.java -> com.enve.app.viewmodel.ObsidianSyncViewModel(
            component.preferences(),
            component.obsidianExportService(),
            component.annotationRepository(),
        )
        com.enve.app.viewmodel.ServerToolsViewModel::class.java -> com.enve.app.viewmodel.ServerToolsViewModel(
            component.serverTools(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.viewmodel.LibraryViewModel::class.java -> com.enve.app.viewmodel.LibraryViewModel(
            component.grimmoryAppRepository(),
            component.komgaRepository(),
            component.audiobookshelfRepository(),
            component.opdsRepository(),
            component.storytellerRepository(),
            component.bookOrbitRepository(),
            component.libraryListResolver(),
            component.aggregator(),
            component.libraryCache(),
            component.libraryMetadataRefreshRepository(),
            component.preferences(),
            component.connections(),
            component.downloads(),
            component.comicDownloads(),
        )
        com.enve.app.viewmodel.PlayerViewModel::class.java -> com.enve.app.viewmodel.PlayerViewModel(
            component.grimmoryRepository(),
            component.aggregator(),
            component.downloads(),
            component.keepNextOfflineService(),
            component.bookCacheDao(),
            component.audioPlayback(),
            component.preferences(),
            component.volumeLevelingStore(),
            component.audioEffectsManager(),
            component.playerChapterService(),
            component.embeddedChapterExtractor(),
            component.bookmarks(),
            component.progressService(),
            component.sessions(),
            component.playerSleepTimerService(),
            component.playbackOpenProgressResolver(),
            component.annotationRepository(),
            component.chapterStore(),
            component.audiobookshelfRepository(),
        )
        com.enve.app.viewmodel.AnnotationsViewModel::class.java -> com.enve.app.viewmodel.AnnotationsViewModel(
            component.annotationRepository(),
            component.bookCacheDao(),
            component.tagIndexStore(),
        )
        com.enve.app.viewmodel.ReaderViewModel::class.java -> com.enve.app.viewmodel.ReaderViewModel(
            component.resources().context,
            component.preferences(),
            component.grimmoryRepository(),
            component.bookOrbitHistorySessionSync(),
            component.aggregator(),
            component.syncManager(),
            component.einkManager(),
            component.annotationRepository(),
            component.koReaderHubService(),
            component.remoteRewindTracker(),
            component.vocabRepository(),
            component.tagIndexStore(),
            component.customFontRepository(),
            component.definitionLookupService(),
            component.audioPlayback(),
            component.readAloud(),
            component.readAloudCheckpoints(),
            component.readerNarrationStore(),
            component.epubBridgeCheckpointStore(),
            component.history(),
            component.ebookSearchService(),
            component.readerSearchPreferences(),
            component.resources().scope,
            component.database(),
        )
        com.enve.app.viewmodel.DictionariesSettingsViewModel::class.java -> com.enve.app.viewmodel.DictionariesSettingsViewModel(
            component.installedDictionariesStore(),
        )
        com.enve.app.viewmodel.CustomFontsViewModel::class.java -> com.enve.app.viewmodel.CustomFontsViewModel(
            component.customFontRepository(),
            component.preferences(),
        )
        com.enve.app.viewmodel.StorytellerHubViewModel::class.java -> com.enve.app.viewmodel.StorytellerHubViewModel(
            component.connections(),
            component.storytellerHubRepository(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.viewmodel.HardcoverHubViewModel::class.java -> com.enve.app.viewmodel.HardcoverHubViewModel(
            component.hardcoverService(),
        )
        com.enve.app.viewmodel.TipJarViewModel::class.java -> com.enve.app.viewmodel.TipJarViewModel(
            component.resources().context,
        )
        com.enve.app.viewmodel.ThemeViewModel::class.java -> com.enve.app.viewmodel.ThemeViewModel(
            component.preferences(),
            component.einkManager(),
        )
        com.enve.app.viewmodel.DownloadsHubViewModel::class.java -> com.enve.app.viewmodel.DownloadsHubViewModel(
            component.grimmoryRepository(),
            component.downloads(),
            component.comicDownloads(),
            component.bookCacheDao(),
            component.preferences(),
            component.keepNextOfflineStore(),
        )
        com.enve.app.viewmodel.SyncCenterViewModel::class.java -> com.enve.app.viewmodel.SyncCenterViewModel(
            component.preferences(),
            component.connections(),
            component.recentlyPlayedSyncService(),
            component.grimmoryRepository(),
            component.bookloreKoreaderSink(),
            component.database().pendingProgressPushDao(),
        )
        com.enve.app.viewmodel.StatsViewModel::class.java -> com.enve.app.viewmodel.StatsViewModel(
            component.grimmoryRepository(),
            component.preferences(),
            component.history(),
        )
        com.enve.app.viewmodel.ServerManagementViewModel::class.java -> com.enve.app.viewmodel.ServerManagementViewModel(
            component.connections(),
            component.libraryCache(),
            component.aggregator(),
            component.preferences(),
            component.vault(),
            component.mtlsManager(),
            component.serverTools(),
        )
        com.enve.app.viewmodel.SiloAdminViewModel::class.java -> com.enve.app.viewmodel.SiloAdminViewModel(
            component.connections(),
            component.siloRepository(),
        )
        com.enve.app.viewmodel.EnveLibrarianViewModel::class.java -> com.enve.app.viewmodel.EnveLibrarianViewModel(
            component.ebookContextService(),
            component.enveLibrarianService(),
            component.librarianEngineManager(),
            component.librarianConversationStore(),
            component.aggregator(),
            component.bookCacheDao(),
        )
        com.enve.app.viewmodel.VocabViewModel::class.java -> com.enve.app.viewmodel.VocabViewModel(
            component.vocabRepository(),
            component.preferences(),
        )
        com.enve.app.viewmodel.ComicReaderViewModel::class.java -> com.enve.app.viewmodel.ComicReaderViewModel(
            component.resources().context,
            component.preferences(),
            component.grimmoryRepository(),
            component.aggregator(),
            component.annotationRepository(),
            component.komgaRepository(),
            component.comicDownloads(),
            component.bookCacheDao(),
            component.serverPageStreamingService(),
            component.comicReadingDirectionOverrideStore(),
            component.storageLocations(),
            component.database(),
        )
        com.enve.app.viewmodel.MetadataHubViewModel::class.java -> com.enve.app.viewmodel.MetadataHubViewModel(
            component.libraryCache(),
            component.bookCacheDao(),
            component.libraryCacheDao(),
            component.connections(),
        )
        com.enve.app.viewmodel.komga.KomgaReadListsViewModel::class.java -> com.enve.app.viewmodel.komga.KomgaReadListsViewModel(
            component.komgaRepository(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.viewmodel.komga.KomgaServerViewModel::class.java -> com.enve.app.viewmodel.komga.KomgaServerViewModel(
            component.komgaRepository(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.viewmodel.komga.KomgaLibrariesViewModel::class.java -> com.enve.app.viewmodel.komga.KomgaLibrariesViewModel(
            component.komgaRepository(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.viewmodel.komga.KomgaCollectionsViewModel::class.java -> com.enve.app.viewmodel.komga.KomgaCollectionsViewModel(
            component.komgaRepository(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.viewmodel.komga.KomgaUsersViewModel::class.java -> com.enve.app.viewmodel.komga.KomgaUsersViewModel(
            component.komgaRepository(),
            extras.createSavedStateHandle(),
        )
        com.enve.app.wear.WearProvisioningViewModel::class.java -> com.enve.app.wear.WearProvisioningViewModel(
            component.resources().context,
            com.enve.app.wear.WearLinkSessionClient(component.unauthenticatedHttpClient()),
        )
        com.enve.hearth.journal.HearthInsightsViewModel::class.java -> com.enve.hearth.journal.HearthInsightsViewModel(
            component.library(),
        )
        com.enve.hearth.journal.HearthJournalViewModel::class.java -> com.enve.hearth.journal.HearthJournalViewModel(
            component.library(),
            component.serverTools(),
        )
        com.enve.hearth.matching.MatchingViewModel::class.java -> com.enve.hearth.matching.MatchingViewModel(
            component.library(),
            component.batchMatching(),
            component.duplicateMatching(),
        )
        com.enve.hearth.settings.HearthSettingsViewModel::class.java -> com.enve.hearth.settings.HearthSettingsViewModel(
            component.preferencesFacade(),
            component.einkFacade(),
            component.sources(),
            component.library(),
        )
        com.enve.hearth.home.DiscoverViewModel::class.java -> com.enve.hearth.home.DiscoverViewModel(
            component.discover(),
        )
        com.enve.hearth.home.HearthHomeViewModel::class.java -> com.enve.hearth.home.HearthHomeViewModel(
            component.library(),
            component.lastOpenedBookStore(),
            component.preferences(),
            component.preferencesFacade(),
            component.hearthDismissedShelfStore(),
            component.resources().context,
        )
        com.enve.hearth.opds.HearthOpdsCatalogViewModel::class.java -> com.enve.hearth.opds.HearthOpdsCatalogViewModel(
            component.opdsCatalog(),
            component.library(),
        )
        com.enve.hearth.shell.HearthShellViewModel::class.java -> com.enve.hearth.shell.HearthShellViewModel(
            component.playback(),
            component.preferencesFacade(),
            component.playerSession(),
            component.einkFacade(),
            component.library(),
            component.lastOpenedBookStore(),
        )
        com.enve.hearth.library.HearthLibraryViewModel::class.java -> com.enve.hearth.library.HearthLibraryViewModel(
            component.library(),
            component.savedBooks(),
            component.playback(),
            component.preferencesFacade(),
            component.connections(),
        )
        com.enve.hearth.podcasts.PodcastsViewModel::class.java -> com.enve.hearth.podcasts.PodcastsViewModel(
            component.podcasts(),
            component.library(),
        )
        com.enve.hearth.podcasts.PodcastEpisodeViewModel::class.java -> com.enve.hearth.podcasts.PodcastEpisodeViewModel(
            component.library(),
        )
        com.enve.hearth.podcasts.PodcastShowViewModel::class.java -> com.enve.hearth.podcasts.PodcastShowViewModel(
            component.podcasts(),
            component.playback(),
        )
        com.enve.hearth.detail.HearthDetailViewModel::class.java -> com.enve.hearth.detail.HearthDetailViewModel(
            component.library(),
            component.savedBooks(),
            component.annotations(),
            component.bookOrbit(),
            component.serverTools(),
        )
        com.enve.hearth.bookorbit.BookOrbitHighlightsViewModel::class.java -> com.enve.hearth.bookorbit.BookOrbitHighlightsViewModel(
            component.bookOrbit(),
        )
        com.enve.hearth.bookorbit.BookOrbitAchievementsViewModel::class.java -> com.enve.hearth.bookorbit.BookOrbitAchievementsViewModel(
            component.bookOrbit(),
        )
        com.enve.hearth.bookorbit.BookOrbitInsightsViewModel::class.java -> com.enve.hearth.bookorbit.BookOrbitInsightsViewModel(
            component.bookOrbit(),
        )
        com.enve.hearth.collections.CollectionsViewModel::class.java -> com.enve.hearth.collections.CollectionsViewModel(
            component.collections(),
            component.library(),
            component.savedBooks(),
        )
        com.enve.hearth.storyalign.HearthStoryAlignViewModel::class.java -> com.enve.hearth.storyalign.HearthStoryAlignViewModel(
            component.storyAlign(),
            component.library(),
        )
        com.enve.hearth.player.HearthPlayerViewModel::class.java -> com.enve.hearth.player.HearthPlayerViewModel(
            component.playback(),
            component.playerSession(),
            component.preferencesFacade(),
            component.sleepDataFacade(),
            component.library(),
        )
        com.enve.app.ui.auth.AuthViewModel::class.java -> com.enve.app.ui.auth.AuthViewModel(
            component.grimmoryRepository(),
            component.storytellerRepository(),
            component.preferences(),
            component.connections(),
            component.vault(),
            component.mtlsManager(),
            component.libraryCache(),
            component.aggregator(),
            component.audiobookshelfRepository(),
            component.komgaRepository(),
            component.siloRepository(),
            component.jellyfinRepository(),
            component.plexPinAuthService(),
            component.plexPinAuthFlow(),
            component.jellyfinQuickConnectFlow(),
            component.grimmoryOidcFlow(),
            component.absOidcFlow(),
            component.komgaOAuthFlow(),
            component.bookOrbitOidcFlow(),
            component.passwordLogins(),
        )
        else -> throw IllegalArgumentException("Unsupported profile ViewModel: ${modelClass.name}")
        } as T
        model.viewModelScope.coroutineContext[Job]?.let { jobs += it }
        return model
    }
}
