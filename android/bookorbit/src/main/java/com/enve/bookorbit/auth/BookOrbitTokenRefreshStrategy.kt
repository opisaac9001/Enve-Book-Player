// AGENT-LOCKED
package com.enve.bookorbit.auth

import com.enve.bookorbit.dto.BookOrbitLoginRequest
import com.enve.bookorbit.dto.BookOrbitLoginResponse
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
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
            .header("Cookie", "refresh_token=$refreshToken")
            .applyConnectionAuthHeaders(context.connection)
            .build()
        refreshClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val auth = json.decodeFromString<BookOrbitLoginResponse>(response.body?.string() ?: return null)
            val nextRefresh = BookOrbitAuthCookies.refreshToken(response.headers) ?: refreshToken
            storeTokens(context.connectionId, auth.accessToken, nextRefresh)
            auth.accessToken
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
            storeTokens(context.connectionId, auth.accessToken, BookOrbitAuthCookies.refreshToken(response.headers))
            auth.accessToken
        }
    } catch (_: Exception) {
        null
    }

    private fun storeTokens(connectionId: String?, accessToken: String, refreshToken: String?) {
        runBlocking {
            prefs.saveAuth(accessToken, refreshToken)
            connectionId?.let { id ->
                vault.put(CredentialVault.accessTokenKey(id), accessToken)
                if (!refreshToken.isNullOrBlank()) {
                    vault.put(CredentialVault.refreshTokenKey(id), refreshToken)
                }
            }
        }
    }
}
