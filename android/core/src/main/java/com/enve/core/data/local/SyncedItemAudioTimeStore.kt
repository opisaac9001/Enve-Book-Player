package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncedItemAudioTimeStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    suspend fun lastSyncedTime(bookId: String): Double? =
        dataStore.data.first()[key(bookId)]

    suspend fun record(bookId: String, currentTime: Double) {
        dataStore.edit { preferences -> preferences[key(bookId)] = currentTime }
    }

    private fun key(bookId: String) =
        doublePreferencesKey("sync.itemAudio.lastSyncedTime.$bookId")
}
