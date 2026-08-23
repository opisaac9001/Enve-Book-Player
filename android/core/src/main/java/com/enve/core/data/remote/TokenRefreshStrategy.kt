package com.enve.core.data.remote

import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import dagger.MapKey

data class TokenRefreshContext(
    val source: BookSource,
    val serverUrl: String,
    val connectionId: String?,
    val connection: ProviderConnection?,
    val refreshToken: String?,
    val username: String?,
    val password: String?,
)

interface TokenRefreshStrategy {
    fun refresh(context: TokenRefreshContext): String?
}

@MapKey
annotation class TokenRefreshStrategyKey(val source: BookSource)
