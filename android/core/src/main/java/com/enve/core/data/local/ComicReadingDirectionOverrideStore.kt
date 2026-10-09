package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ComicReadingDirectionOverrideStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    suspend fun direction(bookKey: String, providerDirection: suspend () -> String? = { null }): String? {
        val preferences = dataStore.data.first()
        return preferences[key(bookKey)] ?: providerDirection() ?: preferences[defaultDirectionKey]
    }

    suspend fun save(bookKey: String, direction: String) {
        dataStore.edit { preferences ->
            preferences[key(bookKey)] = direction
            preferences[defaultDirectionKey] = direction
        }
    }

    private val defaultDirectionKey = stringPreferencesKey("reader.comic.defaultDirectionOverride")

    private fun key(bookKey: String) =
        stringPreferencesKey("reader.comic.directionOverride.$bookKey")
}
