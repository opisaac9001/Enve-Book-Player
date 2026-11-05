package com.enve.core.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.edit
import com.enve.core.reader.PdfReadingLayout
import kotlinx.coroutines.flow.first

class PdfReadingPreferencesStore(private val dataStore: DataStore<Preferences>) {
    suspend fun layout(bookKey: String): PdfReadingLayout {
        val preferences = dataStore.data.first()
        return PdfReadingLayout(
            twoPageView = preferences[twoPageViewKey(bookKey)] ?: false,
            showCoverSeparately = preferences[showCoverSeparatelyKey(bookKey)] ?: false,
            pageAdjust = preferences[pageAdjustKey(bookKey)] ?: "Fit",
        )
    }

    suspend fun save(bookKey: String, layout: PdfReadingLayout) {
        dataStore.edit { preferences ->
            preferences[twoPageViewKey(bookKey)] = layout.twoPageView
            preferences[showCoverSeparatelyKey(bookKey)] = layout.showCoverSeparately
            preferences[pageAdjustKey(bookKey)] = layout.pageAdjust
        }
    }

    suspend fun clear(bookKey: String) {
        dataStore.edit { preferences ->
            preferences.remove(twoPageViewKey(bookKey))
            preferences.remove(showCoverSeparatelyKey(bookKey))
            preferences.remove(pageAdjustKey(bookKey))
        }
    }

    private fun twoPageViewKey(bookKey: String) =
        booleanPreferencesKey("reader.pdf.twoPageView.$bookKey")

    private fun showCoverSeparatelyKey(bookKey: String) =
        booleanPreferencesKey("reader.pdf.showCoverSeparately.$bookKey")

    private fun pageAdjustKey(bookKey: String) =
        stringPreferencesKey("reader.pdf.pageAdjust.$bookKey")
}
