package com.enve.app.data.reader

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.CoroutineScope
import com.enve.core.di.ApplicationScope
import com.enve.core.data.local.ProfileStorageLocations
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReaderSearchPreferences @Inject constructor(
    locations: ProfileStorageLocations,
    @ApplicationScope scope: CoroutineScope,
) {
    private val store = PreferenceDataStoreFactory.create(scope = scope) {
        File(locations.filesDirectory, "datastore/reader-search.preferences_pb")
    }
    private val wholeWordsKey = booleanPreferencesKey("whole_words")
    val wholeWords = store.data.map { it[wholeWordsKey] ?: true }

    suspend fun setWholeWords(value: Boolean) {
        store.edit { it[wholeWordsKey] = value }
    }
}
