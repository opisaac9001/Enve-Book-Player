// AGENT-LOCKED
package com.enve.app.data.jellyfin

import com.enve.app.data.repository.JellyfinRepository
import kotlinx.coroutines.delay
import javax.inject.Inject
import javax.inject.Singleton

data class JellyfinQcSession(
    val code: String,
    val secret: String,
)

data class JellyfinQcAuth(
    val accessToken: String,
    val username: String,
)

@Singleton
class JellyfinQuickConnectFlow @Inject constructor(
    private val jellyfinRepository: JellyfinRepository,
) {

    suspend fun isEnabled(serverUrl: String): Boolean? =
        jellyfinRepository.isQuickConnectEnabled(serverUrl).getOrNull()

    suspend fun initiate(serverUrl: String): Result<JellyfinQcSession> =
        jellyfinRepository.initiateQuickConnect(serverUrl).mapCatching { result ->
            if (result.Code.isBlank() || result.Secret.isBlank()) {
                error("Jellyfin returned an empty Quick Connect response.")
            }
            JellyfinQcSession(code = result.Code, secret = result.Secret)
        }

    suspend fun pollUntilApproved(serverUrl: String, secret: String): Result<Unit> {
        repeat(POLL_ATTEMPTS) {
            delay(POLL_INTERVAL_MS)
            val pollResult = jellyfinRepository.pollQuickConnect(serverUrl, secret)
            val polled = pollResult.getOrNull()
                ?: return Result.failure(pollResult.exceptionOrNull() ?: IllegalStateException("Quick Connect poll failed"))
            if (polled.Authenticated) return Result.success(Unit)
        }
        return Result.failure(IllegalStateException("Quick Connect timed out. Please try again."))
    }

    suspend fun authenticate(serverUrl: String, secret: String): Result<JellyfinQcAuth> =
        jellyfinRepository.authenticateWithQuickConnect(serverUrl, secret).mapCatching { auth ->
            val token = auth.AccessToken
            if (token.isBlank()) {
                error("Jellyfin authentication returned an empty access token.")
            }
            JellyfinQcAuth(accessToken = token, username = auth.User?.Name.orEmpty())
        }

    private companion object {
        const val POLL_INTERVAL_MS = 5_000L
        const val POLL_ATTEMPTS = 60
    }
}
