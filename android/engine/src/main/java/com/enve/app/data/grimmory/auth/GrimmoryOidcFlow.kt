// AGENT-LOCKED
package com.enve.app.data.grimmory.auth

import android.net.Uri
import com.enve.core.auth.AbsOidcPkce
import com.enve.app.data.remote.dto.OidcStateDto
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.core.auth.OAuthRedirectUris
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

internal fun OidcStateDto.requiredGrimmoryOidcState(): String =
    state?.takeIf { it.isNotBlank() }
        ?: error("Grimmory OIDC state response was missing state.")

sealed class GrimmoryOidcStart {
    data class Ready(val authUrl: String, val normalizedServerUrl: String) : GrimmoryOidcStart()
    data class Failed(val message: String) : GrimmoryOidcStart()
}

sealed class GrimmoryOidcCallback {
    data class Success(val serverUrl: String, val username: String?) : GrimmoryOidcCallback()
    data object NoPending : GrimmoryOidcCallback()
    data class Failed(val message: String) : GrimmoryOidcCallback()
}

// PKCE state held in this @Singleton so it survives VM recreation across the browser hop.
@Singleton
class GrimmoryOidcFlow @Inject constructor(
    private val repository: GrimmoryRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) {
    private data class Pending(
        val serverUrl: String,
        val verifier: String,
        val state: String,
        val nonce: String,
        val redirectUri: String,
        val headers: Map<String, String>,
    )

    @Volatile private var pending: Pending? = null

    suspend fun start(normalizedServerUrl: String, headers: Map<String, String>): GrimmoryOidcStart {
        val verifier = AbsOidcPkce.generateVerifier()
        val challenge = AbsOidcPkce.challenge(verifier)

        val stateResult = repository.getOidcState(normalizedServerUrl, headers).getOrElse { error ->
            pending = null
            return GrimmoryOidcStart.Failed(error.message ?: "Failed to start Grimmory OIDC login")
        }
        val stateToken = runCatching { stateResult.requiredGrimmoryOidcState() }.getOrElse { error ->
            pending = null
            return GrimmoryOidcStart.Failed(error.message ?: "Failed to start Grimmory OIDC login")
        }
        val nonce = AbsOidcPkce.generateState() + AbsOidcPkce.generateState()
        val redirectUri = OAuthRedirectUris.GRIMMORY

        return repository.buildGrimmoryOidcAuthorizationUrl(
            serverUrl = normalizedServerUrl,
            redirectUri = redirectUri,
            codeChallenge = challenge,
            state = stateToken,
            nonce = nonce,
            headers = headers,
        ).fold(
            onSuccess = { authUrl ->
                pending = Pending(
                    serverUrl = normalizedServerUrl,
                    verifier = verifier,
                    state = stateToken,
                    nonce = nonce,
                    redirectUri = redirectUri,
                    headers = headers,
                )
                GrimmoryOidcStart.Ready(authUrl, normalizedServerUrl)
            },
            onFailure = { e -> GrimmoryOidcStart.Failed(e.message ?: "Failed to start Grimmory OIDC login") },
        )
    }

    suspend fun completeCallback(uri: Uri): GrimmoryOidcCallback {
        val authError = uri.getQueryParameter("error")
        if (!authError.isNullOrBlank()) {
            pending = null
            return GrimmoryOidcCallback.Failed("Grimmory OIDC error: $authError")
        }

        val code = uri.getQueryParameter("code")
        val returnedState = uri.getQueryParameter("state")
        val p = pending ?: return GrimmoryOidcCallback.NoPending

        if (code.isNullOrBlank() || returnedState.isNullOrBlank()) {
            pending = null
            return GrimmoryOidcCallback.Failed("Grimmory OIDC response was missing code or state.")
        }
        if (returnedState != p.state) {
            pending = null
            return GrimmoryOidcCallback.Failed("Grimmory OIDC state mismatch (possible CSRF). Try again.")
        }

        return repository.oidcCallback(
            serverUrl = p.serverUrl,
            code = code,
            state = returnedState,
            codeVerifier = p.verifier,
            redirectUri = p.redirectUri,
            nonce = p.nonce,
            headers = p.headers,
        ).fold(
            onSuccess = { username ->
                pending = null
                GrimmoryOidcCallback.Success(serverUrl = p.serverUrl, username = username)
            },
            onFailure = { e ->
                pending = null
                GrimmoryOidcCallback.Failed(e.message ?: "Grimmory OIDC token exchange failed")
            },
        )
    }

    // Call after the connection has been upserted, so tokens land under the right connectionId.
    suspend fun persistTokensForConnection(connectionId: String) {
        val accessToken = prefs.accessToken.first()
        val refreshToken = prefs.refreshToken.first()
        if (!accessToken.isNullOrBlank()) {
            vault.put(CredentialVault.accessTokenKey(connectionId), accessToken)
        }
        if (!refreshToken.isNullOrBlank()) {
            vault.put(CredentialVault.refreshTokenKey(connectionId), refreshToken)
        }
    }

    fun cancel() {
        pending = null
    }

    fun hasPendingFlow(): Boolean = pending != null
}
