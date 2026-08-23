package com.enve.app.data.auth

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.auth.PasswordLoginKey
import com.enve.app.data.emby.EmbyPasswordLogin
import com.enve.app.data.grimmory.auth.GrimmoryPasswordLogin
import com.enve.app.data.jellyfin.JellyfinPasswordLogin
import com.enve.app.data.kavita.KavitaPasswordLogin
import com.enve.core.data.model.BookSource
import com.enve.app.data.opds.OpdsPasswordLogin
import com.enve.app.data.opds.SmbPasswordLogin
import com.enve.app.data.opds.WebDavPasswordLogin
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoMap

@Module
@InstallIn(SingletonComponent::class)
abstract class PasswordLoginModule {

    @Binds @IntoMap @PasswordLoginKey(BookSource.GRIMMORY)
    abstract fun bindGrimmory(impl: GrimmoryPasswordLogin): PasswordLogin

    @Binds @IntoMap @PasswordLoginKey(BookSource.JELLYFIN)
    abstract fun bindJellyfin(impl: JellyfinPasswordLogin): PasswordLogin

    @Binds @IntoMap @PasswordLoginKey(BookSource.EMBY)
    abstract fun bindEmby(impl: EmbyPasswordLogin): PasswordLogin

    @Binds @IntoMap @PasswordLoginKey(BookSource.KAVITA)
    abstract fun bindKavita(impl: KavitaPasswordLogin): PasswordLogin

    @Binds @IntoMap @PasswordLoginKey(BookSource.OPDS)
    abstract fun bindOpds(impl: OpdsPasswordLogin): PasswordLogin

    @Binds @IntoMap @PasswordLoginKey(BookSource.WEBDAV)
    abstract fun bindWebDav(impl: WebDavPasswordLogin): PasswordLogin

    @Binds @IntoMap @PasswordLoginKey(BookSource.SMB)
    abstract fun bindSmb(impl: SmbPasswordLogin): PasswordLogin
}
