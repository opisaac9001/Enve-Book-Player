package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
data class PodcastFeedProgress(
    val positionSec: Long,
    val durationSec: Long,
    val isFinished: Boolean,
    val updatedAtMs: Long,
)

@Singleton
class PodcastFeedProgressStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun save(episodeKey: String, progress: PodcastFeedProgress) {
        dataStore.edit { preferences ->
            preferences[PROGRESS] = json.encodeToString(decode(preferences[PROGRESS]) + (episodeKey to progress))
        }
    }

    suspend fun all(): Map<String, PodcastFeedProgress> = decode(dataStore.data.first()[PROGRESS])

    suspend fun saveImported(
        expected: Map<String, PodcastFeedProgress>,
        updates: Map<String, PodcastFeedProgress>,
    ): Int {
        var applied = 0
        dataStore.edit { preferences ->
            val current = decode(preferences[PROGRESS]).toMutableMap()
            for ((key, progress) in updates) {
                if (current[key] == expected[key]) {
                    current[key] = progress
                    applied++
                }
            }
            if (applied > 0) preferences[PROGRESS] = json.encodeToString(current)
        }
        return applied
    }

    private fun decode(raw: String?): Map<String, PodcastFeedProgress> =
        raw?.let { json.decodeFromString<Map<String, PodcastFeedProgress>>(it) }.orEmpty()

    private companion object {
        val PROGRESS = stringPreferencesKey("podcasts.feedEpisodeProgress")
    }
}
