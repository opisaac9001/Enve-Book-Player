// AGENT-LOCKED
package com.enve.komga.auth

import com.enve.komga.KomgaRepository
import javax.inject.Inject
import javax.inject.Singleton

sealed class KomgaOAuthCompletion {
    data class Success(val username: String) : KomgaOAuthCompletion()
    data class Failed(val message: String) : KomgaOAuthCompletion()
}

// Komga uses form-based SSO with a session cookie, not a token — WebView captures SESSION, we verify it server-side.
@Singleton
class KomgaOAuthFlow @Inject constructor(
    private val komgaRepository: KomgaRepository,
) {
    fun authorizationUrl(serverUrl: String, provider: String): String =
        komgaRepository.oauth2AuthorizationUrl(serverUrl, provider)

    suspend fun verifySession(serverUrl: String, cookieHeader: String): KomgaOAuthCompletion {
        if (cookieHeader.isBlank()) {
            return KomgaOAuthCompletion.Failed("Komga SSO returned no session cookie. Try again.")
        }
        return komgaRepository.verifyOauthSession(serverUrl, cookieHeader).fold(
            onSuccess = { resolvedUsername -> KomgaOAuthCompletion.Success(resolvedUsername) },
            onFailure = { e -> KomgaOAuthCompletion.Failed(e.message ?: "Komga SSO verification failed") },
        )
    }
}
