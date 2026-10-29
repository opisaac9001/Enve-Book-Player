package com.enve.app.data.jellyfin

import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.AuthHeaderStrategy
import okhttp3.Request
import javax.inject.Inject

class JellyfinAuthHeaderStrategy @Inject constructor() : AuthHeaderStrategy {
    override fun apply(context: AuthHeaderContext): Request =
        context.builder
            .url(context.original.url.newBuilder()
                .removeAllQueryParameters("api_key")
                .removeAllQueryParameters("ApiKey")
                .build())
            .removeHeader("X-Emby-Token")
            .removeHeader("X-Emby-Authorization")
            .header("Authorization", "MediaBrowser Token=\"${context.token.orEmpty()}\"")
            .build()
}
