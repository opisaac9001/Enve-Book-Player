package com.enve.app.data.auth

import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.AuthHeaderStrategy
import com.enve.core.data.remote.AuthHeaderStrategyKey
import com.enve.core.data.remote.BasicAuthHeaderStrategy
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.TokenRefreshStrategyKey
import com.enve.core.data.remote.XEmbyTokenAuthHeaderStrategy
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoMap

@Module
@InstallIn(SingletonComponent::class)
abstract class AuthHeaderStrategyModule {

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.JELLYFIN)
    abstract fun bindJellyfinAuthHeaderStrategy(impl: XEmbyTokenAuthHeaderStrategy): AuthHeaderStrategy

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.EMBY)
    abstract fun bindEmbyAuthHeaderStrategy(impl: XEmbyTokenAuthHeaderStrategy): AuthHeaderStrategy

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.OPDS)
    abstract fun bindOpdsAuthHeaderStrategy(impl: BasicAuthHeaderStrategy): AuthHeaderStrategy

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.WEBDAV)
    abstract fun bindWebDavAuthHeaderStrategy(impl: BasicAuthHeaderStrategy): AuthHeaderStrategy

    @Binds
    @IntoMap
    @AuthHeaderStrategyKey(BookSource.SMB)
    abstract fun bindSmbAuthHeaderStrategy(impl: BasicAuthHeaderStrategy): AuthHeaderStrategy

    @Binds
    @IntoMap
    @TokenRefreshStrategyKey(BookSource.GRIMMORY)
    abstract fun bindGrimmoryTokenRefreshStrategy(impl: GrimmoryTokenRefreshStrategy): TokenRefreshStrategy
}
