package com.enve.app.data.hardcover

import android.content.Context
import android.content.SharedPreferences
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

private const val KEY_ENABLED = "enabled"
private const val MATCH_PREFIX = "match."
private const val UNLINKED_PREFIX = "unlinked."

@Serializable
data class HardcoverBookMatch(
    val localKey: String,
    val localTitle: String,
    val localAuthor: String?,
    val hardcoverBookId: Int,
    val hardcoverTitle: String,
    val automatic: Boolean,
    val editionId: Int? = null,
)

fun hardcoverLocalKey(source: BookSource, connectionId: String?, bookId: String): String =
    "${source.name}:${connectionId.orEmpty()}:$bookId"

@Singleton
class HardcoverSyncStore internal constructor(private val prefs: SharedPreferences) {
    @Inject
    constructor(@ApplicationContext context: Context, locations: ProfileStorageLocations) : this(
        context.getSharedPreferences(
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "hardcover_sync" else "hardcover_sync_${locations.profileId}",
            Context.MODE_PRIVATE,
        ),
    )

    private val json = Json { ignoreUnknownKeys = true }

    private val mutableEnabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, false))
    val enabled: StateFlow<Boolean> = mutableEnabled.asStateFlow()

    private val mutableMatches = MutableStateFlow(
        prefs.all.filterKeys { it.startsWith(MATCH_PREFIX) }.values.mapNotNull { value ->
            (value as? String)?.let { runCatching { json.decodeFromString(HardcoverBookMatch.serializer(), it) }.getOrNull() }
        }.associateBy { it.localKey },
    )
    val matches: StateFlow<Map<String, HardcoverBookMatch>> = mutableMatches.asStateFlow()

    fun setEnabled(value: Boolean) {
        prefs.edit().putBoolean(KEY_ENABLED, value).apply()
        mutableEnabled.value = value
    }

    fun match(localKey: String): HardcoverBookMatch? = mutableMatches.value[localKey]

    fun isUnlinked(localKey: String): Boolean = prefs.getBoolean(UNLINKED_PREFIX + localKey, false)

    fun saveMatch(match: HardcoverBookMatch) {
        prefs.edit()
            .putString(MATCH_PREFIX + match.localKey, json.encodeToString(HardcoverBookMatch.serializer(), match))
            .remove(UNLINKED_PREFIX + match.localKey)
            .apply()
        mutableMatches.update { it + (match.localKey to match) }
    }

    fun unlink(localKey: String) {
        prefs.edit()
            .remove(MATCH_PREFIX + localKey)
            .putBoolean(UNLINKED_PREFIX + localKey, true)
            .apply()
        mutableMatches.update { it - localKey }
    }
}
