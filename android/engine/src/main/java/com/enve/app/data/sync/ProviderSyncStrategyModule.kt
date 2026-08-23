package com.enve.app.data.sync

import com.enve.core.data.sync.ProviderSyncStrategy
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet

@Module
@InstallIn(SingletonComponent::class)
abstract class ProviderSyncStrategyModule {

    @Binds
    @IntoSet
    abstract fun bindGrimmoryEbook(impl: GrimmoryEbookSyncStrategy): ProviderSyncStrategy

    @Binds
    @IntoSet
    abstract fun bindGrimmoryAudiobook(impl: GrimmoryAudiobookSyncStrategy): ProviderSyncStrategy
}
