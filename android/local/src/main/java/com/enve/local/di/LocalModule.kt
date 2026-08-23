package com.enve.local.di

import com.enve.local.LocalProviderAdapter
import com.enve.local.auth.LocalPasswordLogin
import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.auth.PasswordLoginKey
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoMap
import dagger.multibindings.IntoSet

@Module
@InstallIn(SingletonComponent::class)
abstract class LocalModule {

    @Binds
    @IntoSet
    abstract fun bindLocalAdapter(impl: LocalProviderAdapter): ProviderAdapter

    @Binds
    @IntoMap
    @PasswordLoginKey(BookSource.LOCAL)
    abstract fun bindLocalPasswordLogin(impl: LocalPasswordLogin): PasswordLogin
}
