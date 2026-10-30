// AGENT-LOCKED
package com.enve.app.data.mediabrowser

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.JellyfinAuthRequest
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MediaBrowserPasswordAuthenticator @Inject constructor(
    private val api: GrimmoryApi,
    private val prefs: PreferencesManager,
) {
    suspend fun login(source: BookSource, serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        val authHeader = buildAuthHeader()
        val request = JellyfinAuthRequest(username = username, password = password)
        val url = "${serverUrl.trimEnd('/')}/Users/AuthenticateByName"
        val response = when (source) {
            BookSource.JELLYFIN -> api.jellyfinLogin(url, authHeader, request)
            BookSource.EMBY -> api.embyLogin(url, authHeader, request)
            else -> error("${source.displayName} does not use MediaBrowser login")
        }
        if (!response.isSuccessful) {
            if (response.code() == 401) error("Invalid username or password")
            error("${source.displayName} login failed: HTTP ${response.code()}")
        }
        val token = response.body()?.accessToken?.takeIf { it.isNotBlank() }
            ?: error("${source.displayName} did not return an access token")
        prefs.saveAuth(token, null)
    }

    private suspend fun buildAuthHeader(): String {
        val deviceName = (android.os.Build.MODEL ?: "Android Device").replace("\"", "").take(64)
        val deviceId = prefs.getOrCreatePlexClientIdentifier()
        return "MediaBrowser Client=\"Enve\", Device=\"$deviceName\", DeviceId=\"$deviceId\", Version=\"1.0\""
    }
}
