package com.enve.silo.di

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.auth.PasswordLoginKey
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.TokenRefreshStrategyKey
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.silo.SiloProviderAdapter
import com.enve.silo.api.SiloApi
import com.enve.silo.auth.SiloPasswordLogin
import com.enve.silo.auth.SiloTokenRefreshStrategy
import com.enve.silo.sync.SiloSyncStrategy
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
abstract class SiloModule {
    @Binds
    @IntoSet
    abstract fun bindSiloAdapter(impl: SiloProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindSiloSyncStrategy(impl: SiloSyncStrategy): ProviderSyncStrategy

    @Binds
    @IntoMap
    @PasswordLoginKey(BookSource.SILO)
    abstract fun bindSiloPasswordLogin(impl: SiloPasswordLogin): PasswordLogin

    @Binds
    @IntoMap
    @TokenRefreshStrategyKey(BookSource.SILO)
    abstract fun bindSiloTokenRefreshStrategy(impl: SiloTokenRefreshStrategy): TokenRefreshStrategy

    companion object {
        @Provides
        @Singleton
        fun provideSiloApi(retrofit: Retrofit): SiloApi =
            retrofit.create(SiloApi::class.java)
    }
}
