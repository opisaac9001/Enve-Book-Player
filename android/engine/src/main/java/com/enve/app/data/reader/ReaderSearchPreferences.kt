package com.enve.app.data.reader

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStoreFile
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReaderSearchPreferences @Inject constructor(@ApplicationContext context: Context) {
    private val store = PreferenceDataStoreFactory.create {
        context.preferencesDataStoreFile("reader-search")
    }
    private val wholeWordsKey = booleanPreferencesKey("whole_words")
    val wholeWords = store.data.map { it[wholeWordsKey] ?: true }

    suspend fun setWholeWords(value: Boolean) {
        store.edit { it[wholeWordsKey] = value }
    }
}
