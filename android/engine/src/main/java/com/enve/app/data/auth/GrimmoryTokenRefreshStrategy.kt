// AGENT-LOCKED
package com.enve.app.data.auth

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.auth.applyConnectionAuthHeaders
import com.enve.core.data.remote.dto.AuthResponse
import com.enve.core.data.remote.dto.LoginRequest
import com.enve.core.data.remote.dto.RefreshRequest
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject

class GrimmoryTokenRefreshStrategy @Inject constructor(
    private val preferencesManager: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    @RefreshClient private val refreshClientProvider: javax.inject.Provider<OkHttpClient>,
) : TokenRefreshStrategy {

    private val refreshClient get() = refreshClientProvider.get()
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private sealed interface AuthAttempt {
        data class Success(val accessToken: String) : AuthAttempt
        data object Rejected : AuthAttempt
        data object Unavailable : AuthAttempt
    }

    override fun refresh(context: TokenRefreshContext): String? {
        val refreshToken = context.refreshToken
        var credentialsRejected = false
        if (!refreshToken.isNullOrBlank()) {
            when (val attempt = refreshWithToken(context, refreshToken)) {
                is AuthAttempt.Success -> return attempt.accessToken
                AuthAttempt.Rejected -> credentialsRejected = true
                AuthAttempt.Unavailable -> Unit
            }
        }

        val username = context.username
        val password = context.password
        if (!username.isNullOrBlank() && !password.isNullOrBlank()) {
            when (val attempt = reLogin(context, username, password)) {
                is AuthAttempt.Success -> return attempt.accessToken
                AuthAttempt.Rejected -> credentialsRejected = true
                AuthAttempt.Unavailable -> return null
            }
        }

        if (credentialsRejected || (refreshToken.isNullOrBlank() && password.isNullOrBlank())) {
            markNeedsReauth(context)
        }
        return null
    }

    private fun refreshWithToken(context: TokenRefreshContext, refreshToken: String): AuthAttempt {
        return try {
            val requestBody = json.encodeToString(RefreshRequest.serializer(), RefreshRequest(refreshToken))
            val request = Request.Builder()
                .url("${context.serverUrl.trimEnd('/')}/api/v1/auth/refresh")
                .post(requestBody.toRequestBody("application/json".toMediaType()))
                .header("Accept", "application/json")
                .applyConnectionAuthHeaders(context.connection)
                .build()
            val response = refreshClient.newCall(request).execute()
            if (!response.isSuccessful) {
                val attempt = if (response.code in 400..499) AuthAttempt.Rejected else AuthAttempt.Unavailable
                response.close()
                return attempt
            }
            val responseBody = response.body?.string() ?: return AuthAttempt.Unavailable
            val auth = json.decodeFromString<AuthResponse>(responseBody)
            storeTokens(context.connectionId, auth.accessToken, auth.refreshToken)
            AuthAttempt.Success(auth.accessToken)
        } catch (_: Exception) {
            AuthAttempt.Unavailable
        }
    }

    private fun reLogin(context: TokenRefreshContext, username: String, password: String): AuthAttempt {
        return try {
            val requestBody = json.encodeToString(LoginRequest.serializer(), LoginRequest(username, password))
            val request = Request.Builder()
                .url("${context.serverUrl.trimEnd('/')}/api/v1/auth/login")
                .post(requestBody.toRequestBody("application/json".toMediaType()))
                .header("Accept", "application/json")
                .applyConnectionAuthHeaders(context.connection)
                .build()
            val response = refreshClient.newCall(request).execute()
            if (!response.isSuccessful) {
                val attempt = if (response.code in 400..499) AuthAttempt.Rejected else AuthAttempt.Unavailable
                response.close()
                return attempt
            }
            val responseBody = response.body?.string() ?: return AuthAttempt.Unavailable
            val auth = json.decodeFromString<AuthResponse>(responseBody)
            storeTokens(context.connectionId, auth.accessToken, auth.refreshToken)
            AuthAttempt.Success(auth.accessToken)
        } catch (_: Exception) {
            AuthAttempt.Unavailable
        }
    }

    private fun markNeedsReauth(context: TokenRefreshContext) {
        val connection = context.connection ?: return
        if (!connection.needsReauth) {
            runBlocking { connectionRegistry.upsert(connection.copy(needsReauth = true)) }
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
