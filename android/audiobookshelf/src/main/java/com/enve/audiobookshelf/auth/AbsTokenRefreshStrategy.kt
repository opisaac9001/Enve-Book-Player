// AGENT-LOCKED
package com.enve.audiobookshelf.auth

import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.auth.applyConnectionAuthHeaders
import com.enve.core.data.remote.dto.AbsLoginRequest
import com.enve.core.data.remote.dto.AbsLoginResponse
import com.enve.core.data.remote.auth.hasCloudflareAccess
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject

class AbsTokenRefreshStrategy @Inject constructor(
    private val preferencesManager: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    @RefreshClient private val refreshClientProvider: javax.inject.Provider<OkHttpClient>,
) : TokenRefreshStrategy {

    private val refreshClient get() = refreshClientProvider.get()
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    override fun refresh(context: TokenRefreshContext): String? {
        val refreshToken = context.refreshToken
        if (!refreshToken.isNullOrBlank()) {
            refreshWithToken(context, refreshToken)?.let { return it }
        }

        val username = context.username
        val password = context.password
        if (!username.isNullOrBlank() && !password.isNullOrBlank()) {
            reLogin(context, username, password)?.let { return it }
        }

        val connection = context.connection
        if (connection != null && connection.hasCloudflareAccess() && !connection.needsReauth) {
            runBlocking { connectionRegistry.upsert(connection.copy(needsReauth = true)) }
        }
        return null
    }

    private fun refreshWithToken(context: TokenRefreshContext, refreshToken: String): String? {
        return try {
            val request = Request.Builder()
                .url("${context.serverUrl.trimEnd('/')}/auth/refresh")
                .post("".toRequestBody(null))
                .header("Accept", "application/json")
                .header("x-return-tokens", "true")
                .header("x-refresh-token", refreshToken)
                .applyConnectionAuthHeaders(context.connection)
                .build()
            val response = refreshClient.newCall(request).execute()
            if (!response.isSuccessful) {
                response.close()
                return null
            }
            val auth = json.decodeFromString<AbsLoginResponse>(response.body?.string() ?: return null)
            val accessToken = auth.user?.accessToken ?: auth.user?.token ?: auth.accessToken ?: return null
            val nextRefresh = auth.user?.refreshToken ?: auth.refreshToken
            storeTokens(context.connectionId, accessToken, nextRefresh ?: refreshToken)
            accessToken
        } catch (_: Exception) {
            null
        }
    }

    private fun reLogin(context: TokenRefreshContext, username: String, password: String): String? {
        return try {
            val body = json.encodeToString(AbsLoginRequest.serializer(), AbsLoginRequest(username, password))
            val request = Request.Builder()
                .url("${context.serverUrl.trimEnd('/')}/login")
                .post(body.toRequestBody("application/json".toMediaType()))
                .header("Content-Type", "application/json")
                .header("x-return-tokens", "true")
                .applyConnectionAuthHeaders(context.connection)
                .build()
            val response = refreshClient.newCall(request).execute()
            if (!response.isSuccessful) {
                response.close()
                return null
            }
            val auth = json.decodeFromString<AbsLoginResponse>(response.body?.string() ?: return null)
            val accessToken = auth.user?.accessToken ?: auth.user?.token ?: auth.accessToken ?: return null
            val nextRefresh = auth.user?.refreshToken ?: auth.refreshToken
            storeTokens(context.connectionId, accessToken, nextRefresh)
            accessToken
        } catch (_: Exception) {
            null
        }
    }

    private fun storeTokens(connectionId: String?, accessToken: String, refreshToken: String?) {
        runBlocking {
            preferencesManager.saveAuth(accessToken, refreshToken)
            connectionId?.let { id ->
                vault.put(CredentialVault.accessTokenKey(id), accessToken)
                if (!refreshToken.isNullOrBlank()) {
                    vault.put(CredentialVault.refreshTokenKey(id), refreshToken)
                }
            }
        }
    }
}
