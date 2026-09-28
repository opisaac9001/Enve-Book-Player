package com.enve.core.data.local

import android.content.Context
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
class PodcastFeedProgressStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val dataStore = context.enveDataStore
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun save(episodeKey: String, progress: PodcastFeedProgress) {
        dataStore.edit { preferences ->
            preferences[PROGRESS] = json.encodeToString(decode(preferences[PROGRESS]) + (episodeKey to progress))
        }
    }

    suspend fun all(): Map<String, PodcastFeedProgress> = decode(dataStore.data.first()[PROGRESS])

    private fun decode(raw: String?): Map<String, PodcastFeedProgress> =
        raw?.let { json.decodeFromString<Map<String, PodcastFeedProgress>>(it) }.orEmpty()

    private companion object {
        val PROGRESS = stringPreferencesKey("podcasts.feedEpisodeProgress")
    }
}
