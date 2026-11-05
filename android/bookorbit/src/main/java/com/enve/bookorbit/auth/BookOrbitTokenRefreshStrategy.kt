// AGENT-LOCKED
package com.enve.bookorbit.auth

import com.enve.bookorbit.dto.BookOrbitLoginRequest
import com.enve.bookorbit.dto.BookOrbitLoginResponse
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.auth.applyConnectionAuthHeaders
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject

class BookOrbitTokenRefreshStrategy @Inject constructor(
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    @RefreshClient private val refreshClientProvider: javax.inject.Provider<OkHttpClient>,
) : TokenRefreshStrategy {
    private val refreshClient get() = refreshClientProvider.get()
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }

    override fun refresh(context: TokenRefreshContext): String? {
        val refreshToken = context.refreshToken
        if (!refreshToken.isNullOrBlank()) {
            refreshWithCookie(context, refreshToken)?.let { return it }
        }

        if (context.connection?.authMode == ConnectionAuthMode.SSO) return null
        val username = context.username
        val password = context.password
        if (!username.isNullOrBlank() && !password.isNullOrBlank()) {
            reLogin(context, username, password)?.let { return it }
        }
        return null
    }

    private fun refreshWithCookie(context: TokenRefreshContext, refreshToken: String): String? = try {
        val request = Request.Builder()
            .url("${context.serverUrl.trimEnd('/')}/api/v1/auth/refresh")
            .post("".toRequestBody(null))
            .header("Accept", "application/json")
            .applyConnectionAuthHeaders(context.connection)
            .header("Cookie", (context.connection?.customHeaders?.entries
                ?.firstOrNull { it.key.equals("Cookie", ignoreCase = true) }?.value
                ?.split(';').orEmpty()
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.substringBefore('=').equals("refresh_token", ignoreCase = true) }
                + "refresh_token=$refreshToken").joinToString("; "))
            .build()
        refreshClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val auth = json.decodeFromString<BookOrbitLoginResponse>(response.body?.string() ?: return null)
            val nextRefresh = BookOrbitAuthCookies.refreshToken(response.headers) ?: refreshToken
            val accessToken = auth.accessToken.takeIf { it.isNotBlank() } ?: return null
            storeTokens(context.connectionId, accessToken, nextRefresh)
            accessToken
        }
    } catch (_: Exception) {
        null
    }

    private fun reLogin(context: TokenRefreshContext, username: String, password: String): String? = try {
        val body = json.encodeToString(BookOrbitLoginRequest(username, password))
        val request = Request.Builder()
            .url("${context.serverUrl.trimEnd('/')}/api/v1/auth/login")
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .applyConnectionAuthHeaders(context.connection)
            .build()
        refreshClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val auth = json.decodeFromString<BookOrbitLoginResponse>(response.body?.string() ?: return null)
            val accessToken = auth.accessToken.takeIf { it.isNotBlank() } ?: return null
            storeTokens(context.connectionId, accessToken, BookOrbitAuthCookies.refreshToken(response.headers))
            accessToken
        }
    } catch (_: Exception) {
        null
    }

    private fun storeTokens(connectionId: String?, accessToken: String, refreshToken: String?) {
        runBlocking {
            if (connectionId == null) {
                prefs.saveAuth(accessToken, refreshToken)
            }
            connectionId?.let { id ->
                vault.put(CredentialVault.accessTokenKey(id), accessToken)
                if (!refreshToken.isNullOrBlank()) {
                    vault.put(CredentialVault.refreshTokenKey(id), refreshToken)
                }
            }
        }
    }
}
