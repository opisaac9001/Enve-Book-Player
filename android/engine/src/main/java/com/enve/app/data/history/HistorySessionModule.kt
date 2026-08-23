package com.enve.app.data.history

import com.enve.core.data.history.HistorySessionRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
abstract class HistorySessionModule {
    @Binds
    abstract fun bindHistorySessionRepository(implementation: HistorySessionStore): HistorySessionRepository
}
