package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import android.net.Uri
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringSetPreferencesKey
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudiobookGroupingOverrideStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    suspend fun forceStandalone(source: BookSource, sourceId: String, fileId: String) {
        dataStore.edit { preferences ->
            preferences[OVERRIDES] = preferences[OVERRIDES].orEmpty() + entry(source, sourceId, fileId)
        }
    }

    suspend fun forcedStandaloneIds(source: BookSource, sourceId: String): Set<String> {
        val prefix = prefix(source, sourceId)
        return dataStore.data.first()[OVERRIDES].orEmpty()
            .filter { it.startsWith(prefix) }
            .mapTo(mutableSetOf()) { Uri.decode(it.removePrefix(prefix)) }
    }

    suspend fun removeForcedStandalone(source: BookSource, sourceId: String, fileId: String) {
        dataStore.edit { preferences ->
            preferences[OVERRIDES] = preferences[OVERRIDES].orEmpty() - entry(source, sourceId, fileId)
        }
    }

    private fun entry(source: BookSource, sourceId: String, fileId: String): String =
        "${prefix(source, sourceId)}${Uri.encode(fileId)}"

    private fun prefix(source: BookSource, sourceId: String): String =
        "${source.name}|${Uri.encode(sourceId)}|"

    private companion object {
        val OVERRIDES = stringSetPreferencesKey("library.audiobook.groupingOverrides")
    }
}
