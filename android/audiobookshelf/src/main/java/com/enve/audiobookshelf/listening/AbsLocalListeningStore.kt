package com.enve.audiobookshelf.listening

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.audiobookshelf.dto.AbsPlaybackDeviceInfo
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

private const val KEY_SESSIONS = "sessions"
private const val KEY_DEVICE_ID = "device_id"
private const val KEY_ACCOUNT_PREFIX = "account:"

@Singleton
class AbsLocalListeningStore(private val prefs: SharedPreferences) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        context.getSharedPreferences("abs_local_listening", Context.MODE_PRIVATE),
    )

    constructor(context: Context, locations: ProfileStorageLocations) : this(
        context.getSharedPreferences(
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "abs_local_listening"
            else "abs_local_listening_profile_${locations.profileId}",
            Context.MODE_PRIVATE,
        ),
    )

    private val serializer = ListSerializer(AbsLocalListeningSession.serializer())
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()

    val deviceInfo: AbsPlaybackDeviceInfo by lazy {
        val id = prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY_DEVICE_ID, it).apply()
        }
        AbsPlaybackDeviceInfo(
            deviceId = id,
            manufacturer = Build.MANUFACTURER.orEmpty(),
            model = Build.MODEL.orEmpty(),
            sdkVersion = Build.VERSION.SDK_INT,
        )
    }

    suspend fun record(entry: AbsListeningEntry) = mutex.withLock {
        save(AbsLocalListeningLedger.record(load(), entry, System.currentTimeMillis(), LocalDate.now()))
    }

    suspend fun enqueueHistory(session: AbsLocalListeningSession) = mutex.withLock {
        save(AbsCrossProviderHistory.enqueue(load(), session))
    }

    suspend fun removeCrossProviderHistory(sourceBookKey: String) = mutex.withLock {
        save(load().filterNot { it.sourceBookKey == sourceBookKey && it.needsUpload })
    }

    suspend fun pending(connectionId: String, accountId: String?): List<AbsLocalListeningSession> = mutex.withLock {
        AbsLocalListeningLedger.pendingFor(load(), connectionId, accountId)
    }

    fun rememberAccount(connectionId: String, accountId: String) {
        if (connectionId.isEmpty() || prefs.getString(KEY_ACCOUNT_PREFIX + connectionId, null) == accountId) return
        prefs.edit().putString(KEY_ACCOUNT_PREFIX + connectionId, accountId).apply()
    }

    fun rememberedAccount(connectionId: String): String? =
        connectionId.takeIf { it.isNotEmpty() }?.let { prefs.getString(KEY_ACCOUNT_PREFIX + it, null) }

    suspend fun markUploaded(uploaded: List<AbsLocalListeningSession>, rejectedIds: Set<String>) = mutex.withLock {
        save(AbsLocalListeningLedger.markUploaded(load(), uploaded, rejectedIds))
    }

    private fun load(): List<AbsLocalListeningSession> =
        prefs.getString(KEY_SESSIONS, null)?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() }.orEmpty()

    private fun save(sessions: List<AbsLocalListeningSession>) {
        check(prefs.edit().putString(KEY_SESSIONS, json.encodeToString(serializer, sessions)).commit())
    }
}
