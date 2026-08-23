package com.enve.bookorbit.di

import com.enve.bookorbit.BookOrbitProviderAdapter
import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.auth.BookOrbitPasswordLogin
import com.enve.bookorbit.auth.BookOrbitTokenRefreshStrategy
import com.enve.bookorbit.sync.BookOrbitSyncStrategy
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
abstract class BookOrbitModule {
    @Binds
    @IntoSet
    abstract fun bindBookOrbitAdapter(impl: BookOrbitProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindBookOrbitSyncStrategy(impl: BookOrbitSyncStrategy): ProviderSyncStrategy

    @Binds
    @IntoMap
    @PasswordLoginKey(BookSource.BOOKORBIT)
    abstract fun bindBookOrbitPasswordLogin(impl: BookOrbitPasswordLogin): PasswordLogin

    @Binds
    @IntoMap
    @TokenRefreshStrategyKey(BookSource.BOOKORBIT)
    abstract fun bindBookOrbitTokenRefreshStrategy(impl: BookOrbitTokenRefreshStrategy): TokenRefreshStrategy

    companion object {
        @Provides
        @Singleton
        fun provideBookOrbitApi(retrofit: Retrofit): BookOrbitApi =
            retrofit.create(BookOrbitApi::class.java)
    }
}
