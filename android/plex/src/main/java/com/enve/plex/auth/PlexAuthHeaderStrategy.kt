// AGENT-LOCKED
package com.enve.plex.auth

import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.AuthHeaderStrategy
import javax.inject.Inject

class PlexAuthHeaderStrategy @Inject constructor(
    private val preferencesManager: PreferencesManager,
) : AuthHeaderStrategy {

    override fun apply(context: AuthHeaderContext): okhttp3.Request {
        val token = context.token.orEmpty()
        val clientId = preferencesManager.getOrCreatePlexClientIdentifierSync()
        val url = context.original.url.newBuilder()
            .addQueryParameter("X-Plex-Token", token)
            .build()

        return context.builder
            .url(url)
            .header("X-Plex-Token", token)
            .header("X-Plex-Product", "Enve")
            .header("X-Plex-Client-Identifier", clientId)
            .header("X-Plex-Device", "Android")
            .header("X-Plex-Platform", "Android")
            .header("X-Plex-Platform-Version", android.os.Build.VERSION.RELEASE)
            .header("X-Plex-Version", "1.0")
            .header("Accept", "application/json")
            .build()
    }
}
