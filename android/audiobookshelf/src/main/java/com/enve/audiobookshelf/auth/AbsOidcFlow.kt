// AGENT-LOCKED
package com.enve.audiobookshelf.auth

import android.net.Uri
import com.enve.core.auth.AbsOidcPkce
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.audiobookshelf.AudiobookshelfRepository
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

sealed class AbsOidcStart {
    data class Ready(val idpAuthUrl: String) : AbsOidcStart()
    data class Failed(val message: String) : AbsOidcStart()
}

sealed class AbsOidcCallback {
    data class Success(val serverUrl: String, val username: String) : AbsOidcCallback()
    data object NoPending : AbsOidcCallback()
    data class Failed(val message: String) : AbsOidcCallback()
}

// PKCE state is held in this @Singleton so it survives VM recreation across the browser hop.
@Singleton
class AbsOidcFlow @Inject constructor(
    private val absRepository: AudiobookshelfRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) {
    private data class Pending(
        val serverUrl: String,
        val verifier: String,
        val state: String,
        val cookieHeader: String?,
    )

    @Volatile private var pending: Pending? = null

    suspend fun start(normalizedServerUrl: String): AbsOidcStart {
        val verifier = AbsOidcPkce.generateVerifier()
        val challenge = AbsOidcPkce.challenge(verifier)
        val stateToken = AbsOidcPkce.generateState()

        return absRepository.oauthPreflight(normalizedServerUrl, challenge, stateToken).fold(
            onSuccess = { result ->
                pending = Pending(
                    serverUrl = normalizedServerUrl,
                    verifier = verifier,
                    state = stateToken,
                    cookieHeader = result.cookieHeader,
                )
                AbsOidcStart.Ready(result.authUrl)
            },
            onFailure = { e -> AbsOidcStart.Failed(e.message ?: "Audiobookshelf SSO preflight failed") },
        )
    }

    suspend fun completeCallback(uri: Uri, currentUsername: String?): AbsOidcCallback {
        val authError = uri.getQueryParameter("error")
        if (!authError.isNullOrBlank()) {
            pending = null
            return AbsOidcCallback.Failed("Audiobookshelf SSO error: $authError")
        }

        val code = uri.getQueryParameter("code")
        val returnedState = uri.getQueryParameter("state")
        val p = pending ?: return AbsOidcCallback.NoPending

        if (code.isNullOrBlank() || returnedState.isNullOrBlank()) {
            pending = null
            return AbsOidcCallback.Failed("Audiobookshelf SSO response was missing code or state.")
        }
        if (returnedState != p.state) {
            pending = null
            return AbsOidcCallback.Failed("Audiobookshelf SSO state mismatch (possible CSRF). Try again.")
        }

        return absRepository.oauthExchangeCode(
            serverUrl = p.serverUrl,
            code = code,
            state = returnedState,
            verifier = p.verifier,
            username = currentUsername?.takeIf { it.isNotBlank() },
            cookieHeader = p.cookieHeader,
        ).fold(
            onSuccess = { effectiveUsername ->
                pending = null
                AbsOidcCallback.Success(serverUrl = p.serverUrl, username = effectiveUsername)
            },
            onFailure = { e ->
                pending = null
                AbsOidcCallback.Failed(e.message ?: "Audiobookshelf SSO token exchange failed")
            },
        )
    }

    suspend fun persistTokensForConnection(connectionId: String, username: String) {
        val accessToken = prefs.accessToken.first()
        val refreshToken = prefs.refreshToken.first()
        if (!accessToken.isNullOrBlank()) {
            vault.put(CredentialVault.accessTokenKey(connectionId), accessToken)
        }
        if (!refreshToken.isNullOrBlank()) {
            vault.put(CredentialVault.refreshTokenKey(connectionId), refreshToken)
        }
        if (username.isNotBlank()) {
            vault.put(CredentialVault.usernameKey(connectionId), username)
        }
    }

    fun cancel() {
        pending = null
    }

    fun hasPendingFlow(): Boolean = pending != null
}
