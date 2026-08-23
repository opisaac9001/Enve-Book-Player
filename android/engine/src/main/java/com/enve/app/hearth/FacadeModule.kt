package com.enve.app.hearth

import com.enve.app.sleep.HealthConnectSleepDataFacade
import com.enve.engine.eink.EinkFacade
import com.enve.engine.annotations.AnnotationsFacade
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlayerSessionFacade
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.servertools.ServerToolsFacade
import com.enve.engine.sleep.SleepDataFacade
import com.enve.engine.sources.SourcesFacade
import com.enve.engine.storyalign.StoryAlignFacade
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class FacadeModule {
    @Binds @Singleton
    abstract fun bindPlaybackFacade(impl: PlaybackFacadeImpl): PlaybackFacade

    @Binds @Singleton
    abstract fun bindPreferencesFacade(impl: PreferencesFacadeImpl): PreferencesFacade

    @Binds @Singleton
    abstract fun bindEinkFacade(impl: EinkFacadeImpl): EinkFacade

    @Binds @Singleton
    abstract fun bindLibraryFacade(impl: LibraryFacadeImpl): LibraryFacade

    @Binds @Singleton
    abstract fun bindPlayerSessionFacade(impl: PlayerSessionFacadeImpl): PlayerSessionFacade

    @Binds @Singleton
    abstract fun bindSourcesFacade(impl: SourcesFacadeImpl): SourcesFacade

    @Binds @Singleton
    abstract fun bindAnnotationsFacade(impl: AnnotationsFacadeImpl): AnnotationsFacade

    @Binds @Singleton
    abstract fun bindStoryAlignFacade(impl: StoryAlignFacadeImpl): StoryAlignFacade

    @Binds @Singleton
    abstract fun bindBookOrbitFacade(impl: BookOrbitFacadeImpl): BookOrbitFacade

    @Binds @Singleton
    abstract fun bindServerToolsFacade(impl: ServerToolsFacadeImpl): ServerToolsFacade

    @Binds @Singleton
    abstract fun bindSleepDataFacade(impl: HealthConnectSleepDataFacade): SleepDataFacade
}
