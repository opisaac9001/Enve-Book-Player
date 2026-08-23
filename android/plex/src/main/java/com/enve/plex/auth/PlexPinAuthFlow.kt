// AGENT-LOCKED
package com.enve.plex.auth

import com.enve.core.data.local.PreferencesManager
import kotlinx.coroutines.delay
import javax.inject.Inject
import javax.inject.Singleton

data class PlexPinSession(
    val pinId: Long,
    val pinCode: String,
    val browserAuthUrl: String,
    val clientId: String,
)

data class PlexAuthSuccess(
    val serverUrl: String,
    val accessToken: String,
    /** Every reachable server the user has access to. Populated when the
     *  caller wants to register each as its own connection. */
    val allServers: List<PlexResolvedServer> = emptyList(),
    /** Raw user token from plex.tv (vs. a server-scoped accessToken). Needed
     *  for /api/v2/home/users enumeration. */
    val userToken: String = accessToken,
)

// Polling cadence (1s × 300 = 5min) matches Plex's native client guidance.
@Singleton
class PlexPinAuthFlow @Inject constructor(
    private val plexPinAuth: PlexPinAuthService,
    private val prefs: PreferencesManager,
) {
    suspend fun createSession(appName: String): Result<PlexPinSession> {
        val clientId = prefs.getOrCreatePlexClientIdentifier()
        return plexPinAuth.createPlexPin(clientId, appName).map { (pinId, pinCode) ->
            PlexPinSession(
                pinId = pinId,
                pinCode = pinCode,
                browserAuthUrl = buildAuthUrl(clientId, pinCode, appName),
                clientId = clientId,
            )
        }
    }

    // On success also resolves every reachable Plex server. The "primary"
    // returned serverUrl/accessToken is the best (local > secure > relay) so
    // callers that only register one connection still get the right default;
    // callers that want every server are wired through [allServers].
    suspend fun pollUntilAuthorized(session: PlexPinSession, appName: String): Result<PlexAuthSuccess> {
        repeat(POLL_ATTEMPTS) {
            delay(POLL_INTERVAL_MS)
            val token = plexPinAuth.checkPlexPin(session.pinId, session.pinCode, session.clientId)
                .getOrNull()
            if (!token.isNullOrBlank()) {
                val all = plexPinAuth
                    .resolveAllPlexServers(token, session.clientId, appName)
                    .getOrDefault(emptyList())
                val primary = all.firstOrNull()
                return Result.success(
                    PlexAuthSuccess(
                        serverUrl = primary?.url ?: "https://plex.tv",
                        accessToken = primary?.accessToken ?: token,
                        allServers = all,
                        userToken = token,
                    )
                )
            }
        }
        return Result.failure(IllegalStateException("Plex login timed out. Please try again."))
    }

    private fun buildAuthUrl(clientId: String, pinCode: String, appName: String): String =
        "https://app.plex.tv/auth#?" +
            "clientID=$clientId" +
            "&code=$pinCode" +
            "&context%5Bdevice%5D%5Bproduct%5D=${appName.replace(" ", "%20")}"

    private companion object {
        const val POLL_INTERVAL_MS = 1_000L
        const val POLL_ATTEMPTS = 300
    }
}
