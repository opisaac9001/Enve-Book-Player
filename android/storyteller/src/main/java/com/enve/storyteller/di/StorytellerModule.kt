package com.enve.storyteller.di

import com.enve.storyteller.StorytellerProviderAdapter
import com.enve.storyteller.api.StorytellerApi
import com.enve.storyteller.auth.StorytellerAuthHeaderStrategy
import com.enve.storyteller.sync.StorytellerSyncStrategy
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.AuthHeaderStrategy
import com.enve.core.data.remote.AuthHeaderStrategyKey
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
abstract class StorytellerModule {

    @Binds
    @IntoSet
    abstract fun bindStorytellerAdapter(impl: StorytellerProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindStorytellerSyncStrategy(impl: StorytellerSyncStrategy): ProviderSyncStrategy

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.STORYTELLER)
    abstract fun bindStorytellerAuthHeaderStrategy(impl: StorytellerAuthHeaderStrategy): AuthHeaderStrategy

    companion object {
        @Provides
        @Singleton
        fun provideStorytellerApi(retrofit: Retrofit): StorytellerApi =
            retrofit.create(StorytellerApi::class.java)
    }
}
