package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ComicReadingDirectionOverrideStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    val defaultDirection = dataStore.data.map { it[defaultKey] ?: "LEFT_TO_RIGHT" }

    suspend fun saveDefaultDirection(direction: String) {
        dataStore.edit { it[defaultKey] = direction }
    }

    suspend fun direction(bookKey: String): String? = dataStore.data.first()[key(bookKey)]

    suspend fun save(bookKey: String, direction: String) {
        dataStore.edit { preferences -> preferences[key(bookKey)] = direction }
    }

    suspend fun clear(bookKey: String) {
        dataStore.edit { preferences -> preferences.remove(key(bookKey)) }
    }

    suspend fun providerDirection(bookKey: String): String? = dataStore.data.first()[providerKey(bookKey)]

    suspend fun saveProviderDirection(bookKey: String, direction: String?) {
        dataStore.edit { preferences ->
            if (direction == null) preferences.remove(providerKey(bookKey))
            else preferences[providerKey(bookKey)] = direction
        }
    }

    private val defaultKey = stringPreferencesKey("reader.comic.defaultDirection")

    private fun providerKey(bookKey: String) =
        stringPreferencesKey("reader.comic.providerDirection.$bookKey")

    private fun key(bookKey: String) =
        stringPreferencesKey("reader.comic.directionOverride.$bookKey")
}
