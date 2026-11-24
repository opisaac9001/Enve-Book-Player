package com.enve.core.data.remote

import com.enve.core.data.model.BookSource
import dagger.MapKey
import okhttp3.Credentials
import okhttp3.Request
import javax.inject.Inject

data class AuthHeaderContext(
    val original: Request,
    val builder: Request.Builder,
    val token: String?,
    val username: String,
)

enum class AuthCredentialScope {
    SERVER_PATH,
    ORIGIN,
}

interface AuthHeaderStrategy {
    val requiresToken: Boolean get() = true
    val credentialScope: AuthCredentialScope get() = AuthCredentialScope.SERVER_PATH

    fun apply(context: AuthHeaderContext): Request
}

@MapKey
annotation class AuthHeaderStrategyKey(val source: BookSource)

class BearerAuthHeaderStrategy @Inject constructor() : AuthHeaderStrategy {
    override fun apply(context: AuthHeaderContext): Request =
        context.builder
            .header("Authorization", "Bearer ${context.token.orEmpty()}")
            .build()
}

class BasicAuthHeaderStrategy @Inject constructor() : AuthHeaderStrategy {
    override val requiresToken: Boolean = false

    override fun apply(context: AuthHeaderContext): Request {
        if (context.original.header("Authorization") != null) {
            return context.builder.build()
        }
        if (context.username.isBlank() && context.token.isNullOrBlank()) {
            return context.builder.build()
        }
        return context.builder
            .header("Authorization", Credentials.basic(context.username, context.token.orEmpty()))
            .build()
    }
}

class XEmbyTokenAuthHeaderStrategy @Inject constructor() : AuthHeaderStrategy {
    override fun apply(context: AuthHeaderContext): Request =
        context.builder
            .header("X-Emby-Token", context.token.orEmpty())
            .build()
}
