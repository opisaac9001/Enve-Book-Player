package com.enve.app.data.grimmory

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.ReadingSessionRequest
import com.enve.core.data.remote.ConnectionScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

private const val PREFS_NAME = "grimmory_pending_sessions"
private const val KEY_PENDING = "pending"
private const val MAX_PENDING = 500

@Serializable
private data class PendingSession(val connectionId: String, val request: ReadingSessionRequest)

@Singleton
class GrimmoryReadingSessionUploader @Inject constructor(
    @ApplicationContext context: Context,
    private val api: GrimmoryApi,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore = com.enve.core.data.local.ProfileServerSyncStore(context, locations),
) {
    private val prefs = context.getSharedPreferences(if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) PREFS_NAME else "${PREFS_NAME}_profile_${locations.profileId}", Context.MODE_PRIVATE)
    private val serializer = ListSerializer(PendingSession.serializer())
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()

    suspend fun upload(request: ReadingSessionRequest): Result<Unit> {
        if (!serverSync.isEnabled) return Result.success(Unit)
        val connectionId = ConnectionScope.getConnectionId().orEmpty()
        mutex.withLock {
            val (mine, others) = load().partition { it.connectionId == connectionId }
            val stillPending = mine.filter { send(it.request) == Outcome.RETRY }
            save(others + stillPending)
        }
        return when (send(request)) {
            Outcome.SENT -> Result.success(Unit)
            Outcome.REJECTED -> Result.failure(IllegalStateException("Grimmory rejected the reading session"))
            Outcome.RETRY -> {
                mutex.withLock { save((load() + PendingSession(connectionId, request)).takeLast(MAX_PENDING)) }
                Result.failure(IllegalStateException("Grimmory unreachable; reading session queued"))
            }
        }
    }

    private enum class Outcome { SENT, REJECTED, RETRY }

    private suspend fun send(request: ReadingSessionRequest): Outcome {
        if (!serverSync.accepts(java.time.Instant.parse(request.startTime).toEpochMilli())) return Outcome.REJECTED
        return try {
            val response = api.createReadingSession(request)
            when {
                response.isSuccessful -> Outcome.SENT
                response.code() in 400..499 && response.code() != 401 && response.code() != 408 && response.code() != 429 -> Outcome.REJECTED
                else -> Outcome.RETRY
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            Outcome.RETRY
        }
    }

    private fun load(): List<PendingSession> =
        prefs.getString(KEY_PENDING, null)
            ?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() }
            .orEmpty()

    private fun save(sessions: List<PendingSession>) {
        prefs.edit().putString(KEY_PENDING, json.encodeToString(serializer, sessions)).apply()
    }
}
