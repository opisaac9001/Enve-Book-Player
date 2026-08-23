package com.enve.audiobookshelf.di

import com.enve.audiobookshelf.AudiobookshelfProviderAdapter
import com.enve.audiobookshelf.AudiobookshelfProgressSyncStrategy
import com.enve.audiobookshelf.api.AudiobookshelfApi
import com.enve.audiobookshelf.auth.AbsPasswordLogin
import com.enve.audiobookshelf.auth.AbsTokenRefreshStrategy
import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.auth.PasswordLoginKey
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.TokenRefreshStrategyKey
import com.enve.core.data.sync.ProviderSyncStrategy
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoMap
import dagger.multibindings.IntoSet
import retrofit2.Retrofit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class AudiobookshelfModule {

    @Binds
    @IntoSet
    abstract fun bindAudiobookshelfAdapter(impl: AudiobookshelfProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindAudiobookshelfProgressSync(impl: AudiobookshelfProgressSyncStrategy): ProviderSyncStrategy

    @Binds
    @IntoMap
    @PasswordLoginKey(BookSource.AUDIOBOOKSHELF)
    abstract fun bindAudiobookshelfPasswordLogin(impl: AbsPasswordLogin): PasswordLogin

    @Binds
    @IntoMap
    @TokenRefreshStrategyKey(BookSource.AUDIOBOOKSHELF)
    abstract fun bindAudiobookshelfTokenRefreshStrategy(impl: AbsTokenRefreshStrategy): TokenRefreshStrategy

    companion object {
        @Provides
        @Singleton
        fun provideAudiobookshelfApi(retrofit: Retrofit): AudiobookshelfApi =
            retrofit.create(AudiobookshelfApi::class.java)
    }
}
