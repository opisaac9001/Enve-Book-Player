package com.enve.plex.di

import com.enve.plex.PlexProviderAdapter
import com.enve.plex.api.PlexApi
import com.enve.plex.auth.PlexAuthHeaderStrategy
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.AuthHeaderStrategy
import com.enve.core.data.remote.AuthHeaderStrategyKey
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
abstract class PlexModule {

    @Binds
    @IntoSet
    abstract fun bindPlexAdapter(impl: PlexProviderAdapter): ProviderAdapter

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.PLEX)
    abstract fun bindPlexAuthHeaderStrategy(impl: PlexAuthHeaderStrategy): AuthHeaderStrategy

    companion object {
        @Provides
        @Singleton
        fun providePlexApi(retrofit: Retrofit): PlexApi =
            retrofit.create(PlexApi::class.java)
    }
}
