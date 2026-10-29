package com.enve.core.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import com.enve.core.reader.PdfReadingLayout
import kotlinx.coroutines.flow.first

class PdfReadingPreferencesStore(private val dataStore: DataStore<Preferences>) {
    suspend fun layout(bookKey: String): PdfReadingLayout {
        val preferences = dataStore.data.first()
        return PdfReadingLayout(
            twoPageView = preferences[twoPageViewKey(bookKey)] ?: false,
            showCoverSeparately = preferences[showCoverSeparatelyKey(bookKey)] ?: false,
        )
    }

    suspend fun save(bookKey: String, layout: PdfReadingLayout) {
        dataStore.edit { preferences ->
            preferences[twoPageViewKey(bookKey)] = layout.twoPageView
            preferences[showCoverSeparatelyKey(bookKey)] = layout.showCoverSeparately
        }
    }

    suspend fun clear(bookKey: String) {
        dataStore.edit { preferences ->
            preferences.remove(twoPageViewKey(bookKey))
            preferences.remove(showCoverSeparatelyKey(bookKey))
        }
    }

    private fun twoPageViewKey(bookKey: String) =
        booleanPreferencesKey("reader.pdf.twoPageView.$bookKey")

    private fun showCoverSeparatelyKey(bookKey: String) =
        booleanPreferencesKey("reader.pdf.showCoverSeparately.$bookKey")
}
