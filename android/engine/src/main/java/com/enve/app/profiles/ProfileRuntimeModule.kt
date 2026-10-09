package com.enve.app.profiles

import android.content.Context
import com.enve.core.di.ApplicationScope
import dagger.Module
import dagger.Provides
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.migration.DisableInstallInCheck
import kotlinx.coroutines.CoroutineScope
import javax.inject.Singleton

@Module
@DisableInstallInCheck
object ProfileRuntimeModule {
    @Provides
    @ApplicationContext
    fun context(resources: ProfileResources): Context = resources.context

    @Provides
    @ApplicationScope
    fun scope(resources: ProfileResources): CoroutineScope = resources.scope

    @Provides
    @Singleton
    fun storageLocations(resources: ProfileResources): com.enve.core.data.local.ProfileStorageLocations =
        resources.locations

    @Provides
    @Singleton
    fun database(resources: ProfileResources): com.enve.app.data.local.ReaderDatabase =
        resources.database

    @Provides
    @Singleton
    fun vault(resources: ProfileResources): com.enve.core.auth.CredentialVault =
        resources.vault

    @Provides
    @Singleton
    fun preferences(resources: ProfileResources): com.enve.core.data.local.PreferencesManager =
        resources.preferences

    @Provides
    @Singleton
    fun connections(resources: ProfileResources): com.enve.core.data.local.ConnectionRegistry =
        resources.connections

    @Provides
    @Singleton
    fun mtlsManager(resources: ProfileResources): com.enve.app.auth.MtlsManager =
        resources.mtlsManager

    @Provides
    @Singleton
    fun hearthPreferences(resources: ProfileResources): com.enve.app.hearth.HearthPreferencesStore =
        com.enve.app.hearth.HearthPreferencesStore(resources.profilePreferences.hearth)

    @Provides
    @Singleton
    fun history(resources: ProfileResources): com.enve.app.data.history.HistorySessionStore =
        com.enve.app.data.history.HistorySessionStore(resources.locations)

    @Provides
    @Singleton
    fun audioStorage(resources: ProfileResources): com.enve.app.data.offline.OfflineAudioStorage =
        com.enve.app.data.offline.OfflineAudioStorage(resources.locations)

    @Provides
    @Singleton
    fun comicStorage(resources: ProfileResources): com.enve.app.data.offline.ComicOfflineStorage =
        com.enve.app.data.offline.ComicOfflineStorage(resources.locations)

    @Provides
    @Singleton
    fun bookmarks(resources: ProfileResources): com.enve.app.playback.PlayerBookmarkService =
        com.enve.app.playback.PlayerBookmarkService(resources.locations)

    @Provides
    @Singleton
    fun lastOpenedBookStore(resources: ProfileResources): com.enve.core.data.local.LastOpenedBookStore =
        com.enve.core.data.local.LastOpenedBookStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun keepNextOfflineStore(resources: ProfileResources): com.enve.core.data.local.KeepNextOfflineStore =
        com.enve.core.data.local.KeepNextOfflineStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun audiobookGroupingOverrideStore(resources: ProfileResources): com.enve.core.data.local.AudiobookGroupingOverrideStore =
        com.enve.core.data.local.AudiobookGroupingOverrideStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun syncedItemAudioTimeStore(resources: ProfileResources): com.enve.core.data.local.SyncedItemAudioTimeStore =
        com.enve.core.data.local.SyncedItemAudioTimeStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun volumeLevelingStore(resources: ProfileResources): com.enve.core.data.local.VolumeLevelingStore =
        com.enve.core.data.local.VolumeLevelingStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun comicReadingDirectionOverrideStore(resources: ProfileResources): com.enve.core.data.local.ComicReadingDirectionOverrideStore =
        com.enve.core.data.local.ComicReadingDirectionOverrideStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun podcastFeedProgressStore(resources: ProfileResources): com.enve.core.data.local.PodcastFeedProgressStore =
        com.enve.core.data.local.PodcastFeedProgressStore(resources.profilePreferences.enve)

    @Provides
    @Singleton
    fun hearthDismissedShelfStore(resources: ProfileResources): com.enve.core.data.local.HearthDismissedShelfStore =
        com.enve.core.data.local.HearthDismissedShelfStore(resources.context, resources.locations)

    @Provides
    @Singleton
    fun podcastSubscriptionStore(resources: ProfileResources): com.enve.app.data.podcasts.PodcastSubscriptionStore =
        com.enve.app.data.podcasts.PodcastSubscriptionStore(resources.context, resources.locations)

    @Provides
    @Singleton
    fun duplicateGroupStore(resources: ProfileResources): com.enve.app.data.duplicates.DuplicateGroupStore =
        com.enve.app.data.duplicates.DuplicateGroupStore(resources.context, resources.locations)

    @Provides
    @Singleton
    fun absLocalListeningStore(resources: ProfileResources): com.enve.audiobookshelf.listening.AbsLocalListeningStore =
        com.enve.audiobookshelf.listening.AbsLocalListeningStore(resources.context, resources.locations)

    @Provides
    @Singleton
    fun storyAlignOutputs(resources: ProfileResources): com.enve.app.storyalign.StoryAlignOutputStore =
        com.enve.app.storyalign.StoryAlignOutputStore(java.io.File(resources.locations.filesDirectory, "storyalign/output"))

}
