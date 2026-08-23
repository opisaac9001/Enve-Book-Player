package com.enve.core.data.local

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ComicReadingDirectionOverrideStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val dataStore = context.enveDataStore

    suspend fun direction(bookKey: String): String? =
        dataStore.data.first()[key(bookKey)]

    suspend fun save(bookKey: String, direction: String) {
        dataStore.edit { preferences -> preferences[key(bookKey)] = direction }
    }

    private fun key(bookKey: String) =
        stringPreferencesKey("reader.comic.directionOverride.$bookKey")
}
