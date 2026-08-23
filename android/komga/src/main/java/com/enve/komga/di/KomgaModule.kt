package com.enve.komga.di

import com.enve.komga.KomgaProviderAdapter
import com.enve.komga.api.KomgaApi
import com.enve.komga.auth.KomgaPasswordLogin
import com.enve.core.data.remote.AuthHeaderStrategy
import com.enve.core.data.remote.AuthHeaderStrategyKey
import com.enve.core.data.remote.BasicAuthHeaderStrategy
import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.auth.PasswordLoginKey
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
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
abstract class KomgaModule {

    @Binds
    @IntoSet
    abstract fun bindKomgaAdapter(impl: KomgaProviderAdapter): ProviderAdapter

    @Binds
    @IntoMap
    @PasswordLoginKey(BookSource.KOMGA)
    abstract fun bindKomgaPasswordLogin(impl: KomgaPasswordLogin): PasswordLogin

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.KOMGA)
    abstract fun bindKomgaAuthHeaderStrategy(impl: BasicAuthHeaderStrategy): AuthHeaderStrategy

    companion object {
        @Provides
        @Singleton
        fun provideKomgaApi(retrofit: Retrofit): KomgaApi =
            retrofit.create(KomgaApi::class.java)
    }
}
