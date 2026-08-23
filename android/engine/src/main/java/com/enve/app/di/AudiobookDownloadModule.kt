package com.enve.app.di

import com.enve.core.data.model.BookSource
import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.AudiobookTrackResolverKey
import com.enve.app.data.offline.resolvers.AudiobookshelfTrackResolver
import com.enve.app.data.offline.resolvers.BookOrbitTrackResolver
import com.enve.app.data.offline.resolvers.GrimmoryTrackResolver
import com.enve.app.data.offline.resolvers.PlexTrackResolver
import com.enve.app.data.offline.resolvers.StorytellerTrackResolver
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoMap

@Module
@InstallIn(SingletonComponent::class)
abstract class AudiobookDownloadModule {

    @Binds
    @IntoMap
    @AudiobookTrackResolverKey(BookSource.GRIMMORY)
    abstract fun bindGrimmoryResolver(impl: GrimmoryTrackResolver): AudiobookTrackResolver

    @Binds
    @IntoMap
    @AudiobookTrackResolverKey(BookSource.AUDIOBOOKSHELF)
    abstract fun bindAudiobookshelfResolver(impl: AudiobookshelfTrackResolver): AudiobookTrackResolver

    @Binds
    @IntoMap
    @AudiobookTrackResolverKey(BookSource.STORYTELLER)
    abstract fun bindStorytellerResolver(impl: StorytellerTrackResolver): AudiobookTrackResolver

    @Binds
    @IntoMap
    @AudiobookTrackResolverKey(BookSource.PLEX)
    abstract fun bindPlexResolver(impl: PlexTrackResolver): AudiobookTrackResolver

    @Binds
    @IntoMap
    @AudiobookTrackResolverKey(BookSource.BOOKORBIT)
    abstract fun bindBookOrbitResolver(impl: BookOrbitTrackResolver): AudiobookTrackResolver
}
