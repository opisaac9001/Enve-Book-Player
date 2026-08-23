package com.enve.app.data.provider

import com.enve.core.data.provider.ProviderAdapter
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet

@Module
@InstallIn(SingletonComponent::class)
abstract class ProviderAdapterModule {

    @Binds
    @IntoSet
    abstract fun bindGrimmory(impl: GrimmoryProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindJellyfin(impl: JellyfinProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindEmby(impl: EmbyProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindKavita(impl: KavitaProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindWebDav(impl: WebDavProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindOpds(impl: OpdsProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindPremiumize(impl: PremiumizeProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindRealDebrid(impl: RealDebridProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindTorBox(impl: TorBoxProviderAdapter): ProviderAdapter

    @Binds
    @IntoSet
    abstract fun bindSmb(impl: SmbProviderAdapter): ProviderAdapter

}
